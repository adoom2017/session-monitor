import Darwin
import Foundation

private func withUnixAddress<T>(
  _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
    throw MonitorError.invalid("Unix socket path too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return try withUnsafePointer(to: &address) { pointer in
    try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

public enum SocketClient {
  public static func send(_ data: Data, to path: String, timeoutMS: Int32 = 50) throws {
    guard data.count <= 1_048_576, !data.contains(10) else {
      throw MonitorError.invalid("socket message size/framing")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MonitorError.system("socket", errno) }
    defer { close(fd) }
    var one: Int32 = 1
    guard
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        == 0
    else { throw MonitorError.system("SO_NOSIGPIPE", errno) }
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw MonitorError.system("fcntl", errno) }
    let connected = try withUnixAddress(path) { connect(fd, $0, $1) }
    if connected != 0 {
      guard errno == EINPROGRESS else { throw MonitorError.system("connect \(path)", errno) }
      try writable(fd, timeoutMS: timeoutMS)
      var code: Int32 = 0
      var length = socklen_t(MemoryLayout.size(ofValue: code))
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else {
        throw MonitorError.system("SO_ERROR", errno)
      }
      guard code == 0 else { throw MonitorError.system("connect", code) }
    }
    let packet = data + Data([10])
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMS) * 1_000_000
    try packet.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let remaining = Int64(deadline) - Int64(DispatchTime.now().uptimeNanoseconds)
        guard remaining > 0 else { throw MonitorError.timeout("socket write") }
        try writable(fd, timeoutMS: Int32(max(1, remaining / 1_000_000)))
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        guard n > 0 else { throw MonitorError.system("socket write", errno) }
        offset += n
      }
    }
  }

  private static func writable(_ fd: Int32, timeoutMS: Int32) throws {
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let n = poll(&descriptor, 1, timeoutMS)
    guard n != 0 else { throw MonitorError.timeout("socket connect/write") }
    guard n > 0 else { throw MonitorError.system("poll", errno) }
    guard descriptor.revents & Int16(POLLNVAL | POLLHUP) == 0 else {
      throw MonitorError.system("socket disconnected", ECONNRESET)
    }
  }
}

public final class SocketServer: @unchecked Sendable {
  private let state = NSLock()
  private var fd: Int32 = -1
  private var lockFD: Int32 = -1
  private let queue = DispatchQueue(label: "session-monitor.socket", qos: .utility)
  public let directory: URL
  public var path: String { directory.appendingPathComponent("sm.sock").path }
  public init(directory: URL) { self.directory = directory }

  public func start(receive: @escaping @Sendable (Result<Data, MonitorError>) -> Void) throws {
    state.lock()
    defer { state.unlock() }
    guard fd == -1 else { throw MonitorError.invalid("socket server already started") }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let lockFile = directory.appendingPathComponent("app.lock").path
    let lock = Darwin.open(lockFile, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw MonitorError.system("open app.lock", errno) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(lock)
      throw MonitorError.system("another SessionMonitor owns app.lock", code)
    }
    var prepared = false
    defer {
      if !prepared {
        flock(lock, LOCK_UN)
        close(lock)
      }
    }
    var info = stat()
    if lstat(path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK else {
        throw MonitorError.invalid("refusing to remove non-socket sm.sock")
      }
      guard unlink(path) == 0 else { throw MonitorError.system("unlink stale socket", errno) }
    } else if errno != ENOENT {
      throw MonitorError.system("lstat socket", errno)
    }
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw MonitorError.system("socket", errno) }
    var bound = false
    defer {
      if !prepared {
        close(listener)
        if bound { unlink(path) }
      }
    }
    guard try withUnixAddress(path, { bind(listener, $0, $1) }) == 0 else {
      throw MonitorError.system("bind", errno)
    }
    bound = true
    guard chmod(path, 0o600) == 0 else { throw MonitorError.system("chmod socket", errno) }
    guard listen(listener, 64) == 0 else { throw MonitorError.system("listen", errno) }
    guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
      throw MonitorError.system("nonblocking listener", errno)
    }
    fd = listener
    lockFD = lock
    prepared = true
    queue.async { [self] in
      defer {
        state.lock()
        close(listener)
        unlink(path)
        flock(lock, LOCK_UN)
        close(lock)
        fd = -1
        lockFD = -1
        state.unlock()
      }
      while true {
        state.lock()
        let stopping = fd == -2
        state.unlock()
        if stopping { break }
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready == 0 { continue }
        if ready < 0 {
          if errno == EINTR { continue }
          receive(.failure(.system("poll listener", errno)))
          break
        }
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EAGAIN || errno == EINTR { continue }
          receive(.failure(.system("accept", errno)))
          break
        }
        do { receive(.success(try Self.read(client))) } catch let error as MonitorError {
          receive(.failure(error))
        } catch { receive(.failure(.invalid("socket read: \(error.localizedDescription)"))) }
        close(client)
      }
    }
  }

  public func stop() {
    state.lock()
    defer { state.unlock() }
    if fd >= 0 { fd = -2 }
  }

  private static func read(_ fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
    while true {
      let remaining = Int64(deadline) - Int64(DispatchTime.now().uptimeNanoseconds)
      guard remaining > 0 else { throw MonitorError.timeout("socket read") }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(max(1, remaining / 1_000_000)))
      guard ready != 0 else { throw MonitorError.timeout("socket read") }
      guard ready > 0 else { throw MonitorError.system("poll socket read", errno) }
      let n = Darwin.read(fd, &buffer, buffer.count)
      guard n >= 0 else { throw MonitorError.system("read socket", errno) }
      if n == 0 { break }
      let chunk = buffer.prefix(n)
      if let newline = chunk.firstIndex(of: 10) {
        data.append(contentsOf: chunk[..<newline])
        guard data.count <= 1_048_576 else {
          throw MonitorError.invalid("socket message exceeds 1MB")
        }
        break
      }
      data.append(contentsOf: chunk)
      guard data.count <= 1_048_576 else {
        throw MonitorError.invalid("socket message exceeds 1MB")
      }
    }
    guard !data.isEmpty else { throw MonitorError.invalid("empty socket message") }
    return data
  }
}
