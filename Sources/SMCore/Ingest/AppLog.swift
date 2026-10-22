import Foundation

/// app.log (+ app.log.1 after a size rotation). Entries older than `retention` are dropped at
/// launch and then at most hourly, so the files hold only the last few days.
public final class AppLog: @unchecked Sendable {
  private let lock = NSLock()
  public let directory: URL
  private let limit: UInt64
  private let retention: TimeInterval
  private var lastPrune: Date?
  public static let defaultRetention: TimeInterval = 3 * 24 * 3600
  public init(
    directory: URL, limit: UInt64 = 1_048_576, retention: TimeInterval = AppLog.defaultRetention
  ) throws {
    self.directory = directory
    self.limit = limit
    self.retention = retention
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  public func write(_ message: String, now: Date = Date()) throws {
    lock.lock()
    defer { lock.unlock() }
    if lastPrune.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
      lastPrune = now
      try prune(before: now.addingTimeInterval(-retention))
    }
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
      (ISO8601DateFormatter().string(from: now) + " " + singleLine(message, limit: 400) + "\n")
        .utf8)
    let count = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard count == line.count else { throw MonitorError.system("write app.log", errno) }
  }

  /// Drops entries older than `cutoff`. Lines are appended in time order and start with an
  /// ISO 8601 UTC timestamp of fixed width, so they compare as strings and only a prefix goes.
  private func prune(before cutoff: Date) throws {
    let stamp = Data(ISO8601DateFormatter().string(from: cutoff).utf8)
    for name in ["app.log.1", "app.log"] {
      let url = directory.appendingPathComponent(name)
      guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { continue }
      var start = data.startIndex
      while start < data.endIndex {
        let end = data[start...].firstIndex(of: 10).map { $0 + 1 } ?? data.endIndex
        let line = data[start..<end]
        if line.count >= stamp.count, line.prefix(stamp.count).lexicographicallyPrecedes(stamp) {
          start = end
        } else {
          break
        }
      }
      if start == data.startIndex { continue }
      if start == data.endIndex {
        try FileManager.default.removeItem(at: url)
        continue
      }
      // Rewrite in place via a private temp file, keeping 0600.
      let temp = directory.appendingPathComponent(".\(name).tmp")
      try? FileManager.default.removeItem(at: temp)
      let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw MonitorError.system("open \(temp.lastPathComponent)", errno) }
      let kept = data[start...]
      let count = kept.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      Darwin.close(fd)
      guard count == kept.count else { throw MonitorError.system("write \(name)", errno) }
      guard rename(temp.path, url.path) == 0 else { throw MonitorError.system("rename \(name)", errno) }
    }
  }
}
