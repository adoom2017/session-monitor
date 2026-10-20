import Darwin
import Foundation

public enum SpoolQueue {
  public static let limit = 5 * 1024 * 1024
  static func acquire(_ directory: URL) throws -> Int32 {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let fd = open(
      directory.appendingPathComponent("spool.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open spool.lock", errno) }
    let deadline = DispatchTime.now().uptimeNanoseconds + 50_000_000
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK else {
        let code = errno
        close(fd)
        throw MonitorError.system("flock spool", code)
      }
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        close(fd)
        throw MonitorError.timeout("spool lock")
      }
      usleep(500)
    }
    return fd
  }
  static func release(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
  }

  public static func append(_ envelope: HookEnvelope, directory: URL) throws {
    let lock = try acquire(directory)
    defer { release(lock) }
    let path = directory.appendingPathComponent("spool.jsonl").path
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open spool", errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw MonitorError.system("stat spool", errno) }
    let data = try JSONEncoder().encode(envelope) + Data([10])
    guard info.st_size + Int64(data.count) <= limit else {
      throw MonitorError.invalid("spool 5MB limit reached; event was not queued")
    }
    try writeAll(fd, data: data)
  }

  static func writeAll(_ fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        guard n > 0 else { throw MonitorError.system("write spool", errno) }
        offset += n
      }
    }
  }
}

public actor SpoolReplayer {
  let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func replay(consume: @Sendable (HookEnvelope) async throws -> Void) async throws {
    let lock = try SpoolQueue.acquire(directory)
    defer { SpoolQueue.release(lock) }
    let path = directory.appendingPathComponent("spool.jsonl").path
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open replay spool", errno) }
    defer { close(fd) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    guard let data = try handle.read(upToCount: SpoolQueue.limit + 1) else { return }
    guard data.count <= SpoolQueue.limit else { throw MonitorError.invalid("oversized spool") }
    var processed = 0
    func commit() throws {
      guard lseek(fd, 0, SEEK_SET) == 0 else { throw MonitorError.system("seek spool", errno) }
      try SpoolQueue.writeAll(fd, data: Data(data.dropFirst(processed)))
      guard ftruncate(fd, off_t(data.count - processed)) == 0 else {
        throw MonitorError.system("truncate spool", errno)
      }
    }
    do {
      while processed < data.count {
        guard let newline = data[processed...].firstIndex(of: 10) else {
          throw MonitorError.invalid("spool has an incomplete final record")
        }
        let envelope = try JSONDecoder().decode(HookEnvelope.self, from: data[processed..<newline])
        try await consume(envelope)
        processed = newline + 1
      }
    } catch {
      do { try commit() }  // Preserve the failing record and remainder, remove only applied records.
      catch let commitError {
        throw MonitorError.invalid(
          "replay failed: \(error.localizedDescription); commit failed: \(commitError.localizedDescription)"
        )
      }
      throw error
    }
    try commit()
  }
}
