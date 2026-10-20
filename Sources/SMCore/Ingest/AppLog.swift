import Foundation

public final class AppLog: @unchecked Sendable {
  private let lock = NSLock()
  public let directory: URL
  private let limit: UInt64
  public init(directory: URL, limit: UInt64 = 1_048_576) throws {
    self.directory = directory
    self.limit = limit
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  public func write(_ message: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let path = directory.appendingPathComponent("app.log")
    let old = directory.appendingPathComponent("app.log.1")
    if FileManager.default.fileExists(atPath: path.path) {
      guard
        let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber
      else { throw MonitorError.invalid("app.log file size attribute") }
      if size.uint64Value >= limit {
        if FileManager.default.fileExists(atPath: old.path) {
          try FileManager.default.removeItem(at: old)
        }
        try FileManager.default.moveItem(at: path, to: old)
      }
    }
    let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open app.log", errno) }
    defer { Darwin.close(fd) }
    let line = Data(
      (ISO8601DateFormatter().string(from: Date()) + " " + singleLine(message, limit: 400) + "\n")
        .utf8)
    let count = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard count == line.count else { throw MonitorError.system("write app.log", errno) }
  }
}
