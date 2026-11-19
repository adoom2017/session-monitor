import Foundation

/// Installs/uninstalls SessionMonitor's hook entries in the agent's config, from inside the app.
/// Manifest files (~/.session-monitor/hook-installation*.json) are shared with earlier script
/// installs, so those uninstall cleanly too. Back up first, add only our entries (other tools' hooks and key order are kept), write
/// atomically, verify, roll back on failure; uninstall restores the original semantics exactly.
public struct HookInstaller: Sendable {
  public enum Agent: String, Sendable, CaseIterable { case claude, codex, pi, agy }

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
  // PreToolUse requires a permission decision. These events only observe the lifecycle.
  static let agyEvents = ["SessionStart", "PreInvocation", "Stop"]
  static let agyGroup = "codewhistle"

  public let agent: Agent
  public let home: URL
  public init(agent: Agent, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.agent = agent
    self.home = home
  }

  var runtime: URL { home.appendingPathComponent(".session-monitor") }
  public var configURL: URL {
    switch agent {
    case .claude: home.appendingPathComponent(".claude/settings.json")
    case .codex: home.appendingPathComponent(".codex/hooks.json")
    // Pi has no hooks file: an auto-discovered extension forwards its lifecycle events.
    case .pi: home.appendingPathComponent(".pi/agent/extensions/codewhistle.ts")
    case .agy: home.appendingPathComponent(".gemini/config/hooks.json")
    }
  }
  var manifestURL: URL {
    let name: String
    switch agent {
    case .claude: name = "hook-installation.json"
    case .codex: name = "hook-installation-codex.json"
    case .pi: name = "hook-installation-pi.json"  // unused: the extension is the whole install
    case .agy: name = "hook-installation-agy.json"
    }
    return runtime.appendingPathComponent(name)
  }
  public var hookBinaryURL: URL { runtime.appendingPathComponent("bin/sm-hook") }
  var events: [String] {
    switch agent {
    case .claude: Self.claudeEvents
    case .codex: Self.codexEvents
    case .pi: []
    case .agy: Self.agyEvents
    }
  }
  var command: String { Self.shellQuote(hookBinaryURL.path) + " " + agent.rawValue }

  // MARK: Status

  public func status() -> Status {
    if agent == .pi {
      guard FileManager.default.fileExists(atPath: configURL.path) else { return .notInstalled }
      guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
        return .unreadable("无法读取 \(configURL.path)")
      }
      return text.contains(PiExtension.marker)
        ? .installed : .unreadable("同名扩展不是码哨安装的，未改动：\(configURL.path)")
    }
    guard FileManager.default.fileExists(atPath: configURL.path) else { return .notInstalled }
    do {
      let root = try OrderedJSON.parse(Data(contentsOf: configURL))
      if agent == .agy {
        guard let group = try agyHookGroup(in: root) else { return .notInstalled }
        return group["enabled"] == .bool(false) ? .notInstalled : .installed
      }
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

  private func agyHookGroup(in root: OrderedJSON) throws -> OrderedJSON? {
    guard root.objectPairs != nil else { throw MonitorError.invalid("config root must be an object") }
    guard let group = root[Self.agyGroup] else { return nil }
    guard let pairs = group.objectPairs, Self.agyEvents.allSatisfy({ group[$0] != nil }),
      pairs.allSatisfy({ key, value in
        if key == "enabled" { return value == .bool(true) || value == .bool(false) }
        guard Self.agyEvents.contains(key), let handlers = value.arrayValue, handlers.count == 1 else {
          return false
        }
        return handlers[0]["type"]?.stringValue == "command" && handlers[0]["command"]?.stringValue == command
      })
    else { throw MonitorError.invalid("Antigravity hook 组 codewhistle 与已有配置冲突") }
    return group
  }

  // MARK: Install / uninstall

  /// Copies `bundledHook` (the app's sm-hook) into place and adds our entries.
  /// Returns the backup file of the previous config.
  @discardableResult
  public func install(bundledHook: URL) throws -> URL {
    if agent == .pi {
      try installBinary(from: bundledHook)
      return try installExtension()
    }
    return try edit { root, hooks, _ in
      try installBinary(from: bundledHook)
      var entry: [(String, OrderedJSON)] = [("type", .string("command")), ("command", .string(command))]
      if agent == .agy {
        entry.append(("timeout", .number("5")))
        root.set(Self.agyGroup, .object(events.map { ($0, .array([.object(entry)])) }))
        return
      }
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
    if agent == .pi { return try uninstallExtension() }
    let backup = try edit(uninstalling: true) { root, hooks, _ in
      if agent == .agy {
        root.set(Self.agyGroup, nil)
        return
      }
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
    removeSharedBinaryIfUnused()
    return backup
  }

  /// The binary is shared by every agent: keep it while another install still uses it.
  private func removeSharedBinaryIfUnused() {
    let inUse = Agent.allCases.contains { other in
      other != agent && HookInstaller(agent: other, home: home).status() != .notInstalled
    }
    if !inUse, FileManager.default.fileExists(atPath: hookBinaryURL.path) {
      try? FileManager.default.removeItem(at: hookBinaryURL)
    }
  }

  // MARK: Pi extension

  private func installExtension() throws -> URL {
    let fm = FileManager.default
    let existed = fm.fileExists(atPath: configURL.path)
    let original = existed ? try Data(contentsOf: configURL) : Data()
    if existed, !String(decoding: original, as: UTF8.self).contains(PiExtension.marker) {
      throw MonitorError.invalid("\(configURL.path) 已存在且不是码哨安装的扩展，未改动")
    }
    let backup = try writeBackup(original, existed: existed)
    let data = Data(PiExtension.source.utf8)
    do {
      try fm.createDirectory(
        at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: configURL, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
      guard try Data(contentsOf: configURL) == data else {
        throw MonitorError.invalid("扩展写入后回读不一致")
      }
    } catch {
      if existed { try? original.write(to: configURL, options: .atomic) } else {
        try? fm.removeItem(at: configURL)
      }
      throw error
    }
    return backup
  }

  private func uninstallExtension() throws -> URL {
    let fm = FileManager.default
    let existed = fm.fileExists(atPath: configURL.path)
    let original = existed ? try Data(contentsOf: configURL) : Data()
    if existed, !String(decoding: original, as: UTF8.self).contains(PiExtension.marker) {
      throw MonitorError.invalid("\(configURL.path) 不是码哨安装的扩展，未改动")
    }
    let backup = try writeBackup(original, existed: existed)
    if existed { try fm.removeItem(at: configURL) }
    removeSharedBinaryIfUnused()
    return backup
  }

  /// After an app update: refresh the installed sm-hook if it differs from the bundled one.
  /// Returns true when it was replaced.
  @discardableResult
  public func syncBinary(from bundledHook: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: hookBinaryURL.path) else { return false }
    var replaced = false
    let installed = try Data(contentsOf: hookBinaryURL)
    let bundled = try Data(contentsOf: bundledHook)
    if installed != bundled {
      try installBinary(from: bundledHook)
      replaced = true
    }
    if agent == .pi, FileManager.default.fileExists(atPath: configURL.path),
      let current = try? Data(contentsOf: configURL),
      String(decoding: current, as: UTF8.self).contains(PiExtension.marker),
      current != Data(PiExtension.source.utf8)
    {
      _ = try installExtension()
      replaced = true
    }
    return replaced
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
    let hadHooks = agent != .agy && root["hooks"] != nil
    var hooks = OrderedJSON.object([])
    if agent == .agy {
      _ = try agyHookGroup(in: root)
    } else {
      hooks = root["hooks"] ?? .object([])
      guard let events = hooks.objectPairs else { throw MonitorError.invalid("hooks must be an object") }
      for (event, groups) in events {  // validate everything before touching anything
        guard let list = groups.arrayValue else { throw MonitorError.invalid("hooks.\(event) must be an array") }
        for group in list where group["hooks"]?.arrayValue == nil {
          throw MonitorError.invalid("hook group in \(event) must contain a hooks array")
        }
      }
    }
    var manifest: Manifest?
    if let data = fm.contents(atPath: manifestURL.path) {
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    let backup = try writeBackup(original, existed: existed)

    if !uninstalling, manifest == nil {
      let created = Manifest(hadHooks: hadHooks, existed: existed)
      try JSONEncoder().encode(created).write(to: manifestURL, options: [.withoutOverwriting])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
      manifest = created
    }

    try mutate(&root, &hooks, manifest)
    if agent != .agy {
      let keepHooksKey =
        !(hooks.objectPairs ?? []).isEmpty
        || (uninstalling && manifest?.hadHooks == true) || (!uninstalling && hadHooks)
      root.set("hooks", keepHooksKey ? hooks : nil)
    }

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

  /// Backs up the current config (or records that it was missing) before any change.
  private func writeBackup(_ original: Data, existed: Bool) throws -> URL {
    let fm = FileManager.default
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
    return backup
  }

  static func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "/._-=%+:@".contains($0) }) {
      return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
