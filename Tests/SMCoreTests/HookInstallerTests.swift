import Foundation
import Testing

@testable import SMCore

@Suite struct HookInstallerTests {
  /// Temporary HOME with a fake bundled sm-hook.
  private final class Sandbox {
    let home: URL
    let bundledHook: URL
    init() throws {
      home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sm installer \(UUID().uuidString.prefix(8))")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      bundledHook = home.appendingPathComponent("bundled-sm-hook")
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledHook)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func write(_ relative: String, _ text: String) throws {
      let url = home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    func read(_ relative: String) throws -> OrderedJSON {
      try OrderedJSON.parse(Data(contentsOf: home.appendingPathComponent(relative)))
    }
  }

  @Test func orderedJSONKeepsOrderNumbersAndUnicode() throws {
    let text = #"{"z":1,"a":{"y":2.50,"b":[true,null,"中文\n\"x\""]},"m":-3e2}"#
    let value = try OrderedJSON.parse(Data(text.utf8))
    #expect(value.objectPairs?.map(\.0) == ["z", "a", "m"])
    let again = try OrderedJSON.parse(value.serialized())
    #expect(again == value)
    #expect(String(decoding: value.serialized(), as: UTF8.self).contains("2.50"))
    #expect(String(decoding: value.serialized(), as: UTF8.self).contains("中文"))
    #expect(throws: MonitorError.self) { try OrderedJSON.parse(Data("{\"a\":1,}".utf8)) }
  }

  @Test func claudeInstallKeepsOtherHooksAndUninstallsExactly() throws {
    let box = try Sandbox()
    let original = """
      {"env":{"A":"1"},"permissions":{"allow":["x"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]},"theme":"dark"}
      """
    try box.write(".claude/settings.json", original)
    let installer = HookInstaller(agent: .claude, home: box.home)
    #expect(installer.status() == .notInstalled)
    try installer.install(bundledHook: box.bundledHook)
    let installed = try box.read(".claude/settings.json")
    #expect(installed.objectPairs?.map(\.0) == ["env", "permissions", "hooks", "theme"])
    let preToolUse = installed["hooks"]?["PreToolUse"]?.arrayValue ?? []
    #expect(preToolUse.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "rtk-rewrite.sh")
    let ours = preToolUse.last?["hooks"]?.arrayValue?.first
    // The sandbox path contains a space, so the binary path is shell-quoted.
    #expect(ours?["command"]?.stringValue?.contains(".session-monitor/bin/sm-hook") == true)
    #expect(ours?["command"]?.stringValue?.hasSuffix(" claude") == true)
    #expect(ours?["timeout"] == .number("5"))
    #expect(Set(installed["hooks"]?.objectPairs?.map(\.0) ?? []) == Set(HookInstaller.claudeEvents))
    #expect(installer.status() == .installed)
    #expect(FileManager.default.isExecutableFile(atPath: installer.hookBinaryURL.path))
    // Idempotent.
    try installer.install(bundledHook: box.bundledHook)
    #expect(try box.read(".claude/settings.json") == installed)
    // Exact uninstall, key order included.
    try installer.uninstall()
    #expect(try box.read(".claude/settings.json") == OrderedJSON.parse(Data(original.utf8)))
    #expect(installer.status() == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: installer.hookBinaryURL.path))
    let backups = try FileManager.default.contentsOfDirectory(
      atPath: box.home.appendingPathComponent(".session-monitor/backups").path)
    #expect(backups.count == 3)
  }

  @Test func codexKeepsVibeNotifyNoTimeoutAndTrustStatus() throws {
    let box = try Sandbox()
    let vibe = #"[{"matcher":"","hooks":[{"type":"command","command":"vibe-notify hook"}]}]"#
    let original = #"{"hooks":{"Stop":\#(vibe),"SessionStart":\#(vibe)}}"#
    try box.write(".codex/hooks.json", original)
    let installer = HookInstaller(agent: .codex, home: box.home)
    try installer.install(bundledHook: box.bundledHook)
    let installed = try box.read(".codex/hooks.json")
    #expect(installed["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]
      == .string("vibe-notify hook"))
    let ours = installed["hooks"]?["Stop"]?.arrayValue?[1]["hooks"]?.arrayValue?.first
    #expect(ours?["timeout"] == nil)
    #expect(installer.status() == .awaitingTrust(untrusted: HookInstaller.codexEvents.count))
    // Trust two entries the way Codex records them.
    let path = installer.configURL.path
    try box.write(
      ".codex/config.toml",
      """
      model = "x"
      [hooks.state."\(path):stop:1:0"]
      trusted_hash = "sha256:aa"
      [hooks.state."\(path):session_start:1:0"]
      trusted_hash = "sha256:bb"
      """)
    #expect(installer.status() == .awaitingTrust(untrusted: HookInstaller.codexEvents.count - 2))
    try installer.uninstall()
    #expect(try box.read(".codex/hooks.json") == OrderedJSON.parse(Data(original.utf8)))
  }

  @Test func sharedBinaryAndMissingConfig() throws {
    let box = try Sandbox()
    let claude = HookInstaller(agent: .claude, home: box.home)
    let codex = HookInstaller(agent: .codex, home: box.home)
    try claude.install(bundledHook: box.bundledHook)  // settings.json did not exist
    try codex.install(bundledHook: box.bundledHook)
    try claude.uninstall()
    #expect(!FileManager.default.fileExists(atPath: claude.configURL.path))  // created → removed
    #expect(FileManager.default.fileExists(atPath: claude.hookBinaryURL.path))  // codex still uses it
    try codex.uninstall()
    #expect(!FileManager.default.fileExists(atPath: claude.hookBinaryURL.path))
  }

  @Test func invalidConfigIsNeverTouched() throws {
    let box = try Sandbox()
    try box.write(".claude/settings.json", "not json")
    let installer = HookInstaller(agent: .claude, home: box.home)
    #expect(throws: MonitorError.self) { try installer.install(bundledHook: box.bundledHook) }
    #expect(try String(contentsOf: installer.configURL, encoding: .utf8) == "not json")
    #expect(!FileManager.default.fileExists(atPath: installer.hookBinaryURL.path))
    if case .unreadable = installer.status() {} else { Issue.record("expected unreadable status") }
  }

  @Test func syncBinaryRefreshesAfterAppUpdate() throws {
    let box = try Sandbox()
    let installer = HookInstaller(agent: .claude, home: box.home)
    try installer.install(bundledHook: box.bundledHook)
    #expect(try !installer.syncBinary(from: box.bundledHook))
    try Data("#!/bin/sh\necho new\n".utf8).write(to: box.bundledHook)
    #expect(try installer.syncBinary(from: box.bundledHook))
    #expect(try Data(contentsOf: installer.hookBinaryURL) == Data(contentsOf: box.bundledHook))
  }
}
