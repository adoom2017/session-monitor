import Darwin
import Foundation

public enum HookDiagnostics {
  public static func record(_ message: String, directory: URL) throws {
    let text = singleLine(message, limit: 400) + "\n"
    FileHandle.standardError.write(Data(("sm-hook: " + text).utf8))
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let fd = open(
      directory.appendingPathComponent("hook-error.log").path,
      O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MonitorError.system("open hook-error.log", errno) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw MonitorError.system("lock hook-error.log", errno) }
    defer { flock(fd, LOCK_UN) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw MonitorError.system("stat hook-error.log", errno) }
    let data = Data(text.utf8)
    if info.st_size + Int64(data.count) > 256 * 1024 {
      guard ftruncate(fd, 0) == 0 else {
        throw MonitorError.system("truncate hook-error.log", errno)
      }
    }
    try SpoolQueue.writeAll(fd, data: data)
  }
}
