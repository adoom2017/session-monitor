import Foundation

/// Installs/uninstalls SessionMonitor's hook entries in the agent's config, from inside the app.
/// Manifest files (~/.session-monitor/hook-installation*.json) are shared with earlier script
/// installs, so those uninstall cleanly too. Back up first, add only our entries (other tools' hooks and key order are kept), write
/// atomically, verify, roll back on failure; uninstall restores the original semantics exactly.
public struct HookInstaller: Sendable {
  public enum Agent: String, Sendable, CaseIterable { case claude, codex }

  public enum Status: Equatable, Sendable {
    case notInstalled
    case installed
    /// Codex only: our entries are present, but not all are trusted in config.toml yet.
    case awaitingTrust(untrusted: Int)
    case unreadable(String)
  }

  public static let marker = ".session-monitor/bin/sm-hook"
  public static let claudeEvents = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
    "Notification", "Stop", "SubagentStart", "SubagentStop", "SessionEnd", "PreCompact",
  ]
  /// No "timeout" key and no "Interrupt" event: unverified against Codex's schema, and an unknown
  /// key could invalidate the whole file (and other tools' hooks in it).
  public static let codexEvents = [
    "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreToolUse",
    "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "UserPromptSubmit", "Stop",
  ]

  public let agent: Agent
  public let home: URL
  public init(agent: Agent, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.agent = agent
    self.home = home
  }

  var runtime: URL { home.appendingPathComponent(".session-monitor") }
  public var configURL: URL {
    home.appendingPathComponent(agent == .claude ? ".claude/settings.json" : ".codex/hooks.json")
  }
  var manifestURL: URL {
    runtime.appendingPathComponent(
      agent == .claude ? "hook-installation.json" : "hook-installation-codex.json")
  }
  public var hookBinaryURL: URL { runtime.appendingPathComponent("bin/sm-hook") }
  var events: [String] { agent == .claude ? Self.claudeEvents : Self.codexEvents }
  var command: String { Self.shellQuote(hookBinaryURL.path) + " " + agent.rawValue }

  // MARK: Status

  public func status() -> Status {
    guard FileManager.default.fileExists(atPath: configURL.path) else { return .notInstalled }
    do {
      let root = try OrderedJSON.parse(Data(contentsOf: configURL))
      let ours = try Self.ourEntryPositions(in: root)
      guard !ours.isEmpty else { return .notInstalled }
      guard agent == .codex else { return .installed }
      let untrusted = ours.filter { !isTrusted(event: $0.event, group: $0.group, hook: $0.hook) }
      return untrusted.isEmpty ? .installed : .awaitingTrust(untrusted: untrusted.count)
    } catch {
      return .unreadable(error.localizedDescription)
    }
  }

  /// Codex records approval as `[hooks.state."<file>:<event_snake>:<group>:<hook>"]` + trusted_hash.
  func isTrusted(event: String, group: Int, hook: Int) -> Bool {
    let config = home.appendingPathComponent(".codex/config.toml")
    guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
    let header = "[hooks.state.\"\(configURL.path):\(Self.snakeCase(event)):\(group):\(hook)\"]"
    guard let range = text.range(of: header) else { return false }
    let rest = text[range.upperBound...]
    let section = rest.range(of: "\n[").map { rest[..<$0.lowerBound] } ?? rest
    return section.contains("trusted_hash")
  }

  static func snakeCase(_ name: String) -> String {
    var out = ""
    for (index, character) in name.enumerated() {
      if character.isUppercase, index > 0 { out += "_" }
      out += character.lowercased()
    }
    return out
  }

  static func ourEntryPositions(in root: OrderedJSON) throws -> [(event: String, group: Int, hook: Int)] {
    guard let hooks = root["hooks"] else { return [] }
    guard let events = hooks.objectPairs else { throw MonitorError.invalid("hooks must be an object") }
    var found: [(String, Int, Int)] = []
    for (event, groups) in events {
      for (groupIndex, group) in (groups.arrayValue ?? []).enumerated() {
        for (hookIndex, hook) in (group["hooks"]?.arrayValue ?? []).enumerated() where isOurs(hook) {
          found.append((event, groupIndex, hookIndex))
        }
      }
    }
    return found
  }

  static func isOurs(_ hook: OrderedJSON) -> Bool {
    hook["type"]?.stringValue == "command"
      && hook["command"]?.stringValue?.contains(marker) == true
  }

  // MARK: Install / uninstall

  /// Copies `bundledHook` (the app's sm-hook) into place and adds our entries.
  /// Returns the backup file of the previous config.
  @discardableResult
  public func install(bundledHook: URL) throws -> URL {
    try edit { root, hooks, _ in
      try installBinary(from: bundledHook)
      var entry: [(String, OrderedJSON)] = [("type", .string("command")), ("command", .string(command))]
      if agent == .claude { entry.append(("timeout", .number("5"))) }
      for event in events {
        var groups = hooks[event]?.arrayValue ?? []
        let present = groups.contains { ($0["hooks"]?.arrayValue ?? []).contains(where: Self.isOurs) }
        if !present {
          groups.append(.object([("matcher", .string("")), ("hooks", .array([.object(entry)]))]))
          hooks.set(event, .array(groups))
        }
      }
    }
  }

  @discardableResult
  public func uninstall() throws -> URL {
    let backup = try edit(uninstalling: true) { _, hooks, _ in
      guard let pairs = hooks.objectPairs else { return }
      for (event, groups) in pairs {
        var kept: [OrderedJSON] = []
        for group in groups.arrayValue ?? [] {
          let entries = group["hooks"]?.arrayValue ?? []
          let remaining = entries.filter { !Self.isOurs($0) }
          if !remaining.isEmpty {
            var updated = group
            updated.set("hooks", .array(remaining))
            kept.append(updated)
          } else if entries.isEmpty {
            kept.append(group)  // an existing empty group is not ours
          }
        }
        hooks.set(event, kept.isEmpty ? nil : .array(kept))
      }
    }
    // The binary is shared: keep it while the other agent's hooks still use it.
    let otherManifest = HookInstaller(agent: agent == .claude ? .codex : .claude, home: home).manifestURL
    if FileManager.default.fileExists(atPath: hookBinaryURL.path),
      !FileManager.default.fileExists(atPath: otherManifest.path)
    {
      try FileManager.default.removeItem(at: hookBinaryURL)
    }
    return backup
  }

  /// After an app update: refresh the installed sm-hook if it differs from the bundled one.
  /// Returns true when it was replaced.
  @discardableResult
  public func syncBinary(from bundledHook: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: hookBinaryURL.path) else { return false }
    let installed = try Data(contentsOf: hookBinaryURL)
    let bundled = try Data(contentsOf: bundledHook)
    guard installed != bundled else { return false }
    try installBinary(from: bundledHook)
    return true
  }

  private func installBinary(from source: URL) throws {
    let fm = FileManager.default
    guard fm.isExecutableFile(atPath: source.path) else {
      throw MonitorError.invalid("bundled sm-hook missing at \(source.path)")
    }
    try fm.createDirectory(
      at: hookBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // Replace atomically; never truncate an executable a running hook may be using.
    let temporary = hookBinaryURL.deletingLastPathComponent()
      .appendingPathComponent("sm-hook-\(UUID().uuidString.prefix(8))")
    try fm.copyItem(at: source, to: temporary)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
    if fm.fileExists(atPath: hookBinaryURL.path) {
      _ = try fm.replaceItemAt(hookBinaryURL, withItemAt: temporary)
    } else {
      try fm.moveItem(at: temporary, to: hookBinaryURL)
    }
  }

  private struct Manifest: Codable { var hadHooks: Bool; var existed: Bool }

  /// Shared transaction: validate → back up → (manifest) → mutate → atomic write → verify.
  private func edit(
    uninstalling: Bool = false,
    _ mutate: (inout OrderedJSON, inout OrderedJSON, Manifest?) throws -> Void
  ) throws -> URL {
    let fm = FileManager.default
    let existed = fm.fileExists(atPath: configURL.path)
    let original = existed ? try Data(contentsOf: configURL) : Data("{}\n".utf8)
    var root = try OrderedJSON.parse(original)
    guard root.objectPairs != nil else { throw MonitorError.invalid("config root must be an object") }
    let hadHooks = root["hooks"] != nil
    var hooks = root["hooks"] ?? .object([])
    guard let events = hooks.objectPairs else { throw MonitorError.invalid("hooks must be an object") }
    for (event, groups) in events {  // validate everything before touching anything
      guard let list = groups.arrayValue else { throw MonitorError.invalid("hooks.\(event) must be an array") }
      for group in list where group["hooks"]?.arrayValue == nil {
        throw MonitorError.invalid("hook group in \(event) must contain a hooks array")
      }
    }
    var manifest: Manifest?
    if let data = fm.contents(atPath: manifestURL.path) {
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    try fm.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let backups = runtime.appendingPathComponent("backups")
    try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let backup = backups.appendingPathComponent(
      "\(configURL.lastPathComponent).\(agent.rawValue).\(stamp)-\(UUID().uuidString.prefix(4))"
        + (existed ? "" : ".missing"))
    try (existed ? original : Data("\(configURL.lastPathComponent) did not exist\n".utf8))
      .write(to: backup, options: [.withoutOverwriting])
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)

    if !uninstalling, manifest == nil {
      let created = Manifest(hadHooks: hadHooks, existed: existed)
      try JSONEncoder().encode(created).write(to: manifestURL, options: [.withoutOverwriting])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
      manifest = created
    }

    try mutate(&root, &hooks, manifest)
    let keepHooksKey =
      !(hooks.objectPairs ?? []).isEmpty
      || (uninstalling && manifest?.hadHooks == true) || (!uninstalling && hadHooks)
    root.set("hooks", keepHooksKey ? hooks : nil)

    try fm.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    do {
      let data = root.serialized()
      _ = try OrderedJSON.parse(data)  // never write something we cannot read back
      try data.write(to: configURL, options: [.atomic])
      _ = try OrderedJSON.parse(Data(contentsOf: configURL))
      if uninstalling {
        if manifest?.existed == false, root.objectPairs?.isEmpty == true {
          try fm.removeItem(at: configURL)
        }
        if fm.fileExists(atPath: manifestURL.path) { try fm.removeItem(at: manifestURL) }
      }
    } catch {
      if existed {
        try? original.write(to: configURL, options: [.atomic])
      } else if fm.fileExists(atPath: configURL.path) {
        try? fm.removeItem(at: configURL)
      }
      throw error
    }
    return backup
  }

  static func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "/._-=%+:@".contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
