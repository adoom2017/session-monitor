import Darwin
import Foundation

public struct ProcessIdentity: Sendable {
  public let pid: Int32
  public let parent: Int32
  public let executable: String
  public let tty: String?
  public var matchedByName = false

  public var startTime: Date?

  init(_ process: kinfo_proc) {
    pid = process.kp_proc.p_pid
    parent = process.kp_eproc.e_ppid
    executable = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    let device = process.kp_eproc.e_tdev
    if device != dev_t(bitPattern: UInt32.max), let value = devname(device, S_IFCHR) {
      tty = "/dev/" + String(cString: value)
    } else {
      tty = nil
    }
    let start = process.kp_proc.p_un.__p_starttime
    startTime = Date(
      timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
  }

  public static func read(_ pid: Int32) throws -> ProcessIdentity {
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0 else {
      throw MonitorError.system("sysctl process", errno)
    }
    guard size > 0 else { throw MonitorError.invalid("ancestor disappeared") }
    return ProcessIdentity(process)
  }

  /// All processes of the current user.
  public static func listAll() throws -> [ProcessIdentity] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
      throw MonitorError.system("sysctl process list size", errno)
    }
    var processes = [kinfo_proc](
      repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = processes.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else {
      throw MonitorError.system("sysctl process list", errno)
    }
    return processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
      .filter { $0.kp_proc.p_pid > 0 }.map(ProcessIdentity.init)
  }

  /// argv of a same-user process (KERN_PROCARGS2); nil if it exited or is not readable.
  public static func arguments(pid: Int32) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    // Layout: argc, executable path, NUL padding, then argc NUL-terminated arguments.
    var index = 4
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < argc, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments
  }



  public static func findAgent(kind: AgentKind, home: URL, startPID: Int32 = getppid()) throws
    -> ProcessIdentity?
  {
    var pid = startPID
    var namedClaude: ProcessIdentity?
    for _ in 0..<6 {
      guard pid > 1 else { break }
      let process = try read(pid)
      switch kind {
      case .claude:
        if FileManager.default.fileExists(
          atPath: home.appendingPathComponent(".claude/sessions/\(pid).json").path)
        {
          return process
        }
        if namedClaude == nil, process.executable == "claude" {
          var named = process
          named.matchedByName = true
          namedClaude = named
        }
      case .codex:
        if process.executable.contains("codex") { return process }
      }
      pid = process.parent
    }
    return namedClaude
  }

  /// Current working directory of a same-user process, from the kernel (no lsof, no permissions).
  public static func cwd(pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return path.isEmpty ? nil : path
  }

  /// Directory of the foreground process on `tty` (e.g. claude, or the idle shell). Terminals'
  /// own path reports can be stale without shell integration; the kernel's view is not.
  public static func foregroundCwd(tty: String) -> String? {
    var device = stat()
    guard stat(tty, &device) == 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(device.st_rdev))]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var processes = [kinfo_proc](
      repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
    size = processes.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
    let live = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
    let foreground = live.filter { $0.kp_eproc.e_pgid == $0.kp_eproc.e_tpgid && $0.kp_proc.p_pid > 0 }
    for process in foreground + live where process.kp_proc.p_pid > 0 {
      if let path = cwd(pid: process.kp_proc.p_pid) { return path }
    }
    return nil
  }
}
