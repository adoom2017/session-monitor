import Darwin
import Foundation

public struct ClaudeSessionFile: Sendable {
  public var pid: Int32
  public var sessionID: String
  public var cwd: String?
  public var status: String?
  public var name: String?
  public var tmux: String?
  public var entrypoint: String?
  public var statusUpdatedAt: Date?
  public var diagnostics: [String] = []

  public static func parse(_ data: Data) throws -> ClaudeSessionFile {
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let number = json["pid"]?.number, number > 0, number <= Double(Int32.max),
      number.rounded() == number
    else { throw MonitorError.invalid("session file pid") }
    var diagnostics: [String] = []
    func optional(_ key: String) -> String? {
      guard let value = json[key], value != .null else { return nil }
      guard let string = value.string else {
        diagnostics.append("session file \(key) type invalid; field ignored")
        return nil
      }
      return string
    }
    let rawTmux = optional("tmux")
    let pane: String?
    if let rawTmux, !rawTmux.isEmpty {
      pane = Self.parseTmux(rawTmux)
      if pane == nil { diagnostics.append("session file tmux malformed; field ignored") }
    } else {
      pane = nil
    }
    var updatedAt: Date?
    if let value = json["statusUpdatedAt"], value != .null {
      if let ms = value.number, ms.isFinite {
        updatedAt = Date(timeIntervalSince1970: ms / 1000)
      } else {
        diagnostics.append("session file statusUpdatedAt invalid; field ignored")
      }
    }
    let cwd = optional("cwd")
    let status = optional("status")
    let name = optional("name")
    let entrypoint = optional("entrypoint")
    return ClaudeSessionFile(
      pid: Int32(number), sessionID: try json.requiredString("sessionId"), cwd: cwd,
      status: status, name: name, tmux: pane,
      entrypoint: entrypoint, statusUpdatedAt: updatedAt, diagnostics: diagnostics)
  }

  public static func parseTmux(_ value: String) -> String? {
    guard let range = value.range(of: #"^.+:@[0-9]+\.(%[0-9]+)$"#, options: .regularExpression)
    else { return nil }
    let full = String(value[range])
    guard let dot = full.lastIndex(of: ".") else { return nil }
    return String(full[full.index(after: dot)...])
  }
}

public enum ClaudeSessionFileScanner {
  public struct ScanReport: Sendable {
    public var files: [ClaudeSessionFile]
    public var issues: [String]
  }
  public static func scanReport(directory: URL) throws -> ScanReport {
    let paths = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    var report = ScanReport(files: [], issues: [])
    for path in paths {
      do {
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw MonitorError.invalid("session JSON must be a regular, non-symlink file")
        }
        report.files.append(try ClaudeSessionFile.parse(Data(contentsOf: path)))
      } catch { report.issues.append("\(path.lastPathComponent): \(error.localizedDescription)") }
    }
    return report
  }

}

public enum ProcessLiveness {
  public static func isAlive(_ pid: Int32) throws -> Bool {
    guard pid > 0 else { throw MonitorError.invalid("pid must be positive") }
    if kill(pid, 0) == 0 { return true }
    let code = errno
    if code == ESRCH { return false }
    if code == EPERM { return true }
    throw MonitorError.system("kill(pid, 0)", code)
  }
}
