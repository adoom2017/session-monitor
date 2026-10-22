import Foundation
import Testing

@testable import SMCore

@Suite struct SourceAndFileTests {
  @Test func everyRealGoldenSampleNormalizes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let paths = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("docs/payload-samples"), includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".provenance.json") }
    var names = Set<String>()
    for path in paths {
      let payload = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
      let name = try payload.requiredString("hook_event_name")
      names.insert(name)
      let envelope = HookEnvelope(
        source: "claude", receivedAt: 1000, agentPid: 123, payload: payload)
      let event = try ClaudeSource().normalize(envelope)
      #expect(event.sessionId == payload["session_id"]?.string)
      #expect(event.at == Date(timeIntervalSince1970: 1))
      #expect(event.agentPid == 123)
      #expect(event.agentId == payload["agent_id"]?.string)
      switch name {
      case "SessionStart": #expect(event.type == .sessionStart(reason: payload["source"]?.string))
      case "UserPromptSubmit": #expect(event.type == .promptSubmitted)
      case "PreToolUse":
        if case .toolStart(let tool, _) = event.type {
          #expect(tool == payload["tool_name"]?.string)
        } else {
          Issue.record("wrong tool event")
        }
      case "PostToolUse":
        #expect(event.type == .toolEnd(name: try payload.requiredString("tool_name")))
      case "PermissionRequest":
        #expect(
          event.type == .permissionRequested(tool: payload["tool_name"]?.string, message: nil))
      case "Notification":
        if case .notification(let kind, _) = event.type {
          #expect(kind == payload["notification_type"]?.string)
        } else {
          Issue.record("wrong notification event")
        }
      case "Stop": #expect(event.type == .stop)
      case "SubagentStart": #expect(event.type == .subagentStart)
      case "SubagentStop": #expect(event.type == .subagentStop)
      case "PreCompact": #expect(event.type == .compacting)
      case "SessionEnd": #expect(event.type == .sessionEnd(reason: payload["reason"]?.string))
      default: Issue.record("unexpected golden event")
      }
    }
    #expect(names.count == 11)
    #expect(paths.count >= 11)
  }

  @Test func malformedAndUnknownEnvelopesThrow() throws {
    let payload: JSONValue = .object([
      "session_id": .string("id"), "hook_event_name": .string("new-unsupported-event"),
    ])
    #expect(throws: MonitorError.self) {
      try ClaudeSource().normalize(HookEnvelope(source: "claude", agentPid: 1, payload: payload))
    }
    #expect(throws: MonitorError.self) {
      try ClaudeSource().normalize(HookEnvelope(source: "unknown", agentPid: 1, payload: payload))
    }
    #expect(throws: MonitorError.self) {
      try ClaudeSource().normalize(
        HookEnvelope(source: "claude", agentPid: 1, payload: .object([:])))
    }
  }

  @Test func sessionFilesStrictlyReportMalformedFields() throws {
    let file = try ClaudeSessionFile.parse(
      Data(
        #"{"pid":42,"sessionId":"id","cwd":"/tmp/project","tmux":"SerenPing:@4.%9","statusUpdatedAt":1000}"#
          .utf8))
    #expect(file.pid == 42)
    #expect(file.tmux == "%9")
    #expect(file.statusUpdatedAt == Date(timeIntervalSince1970: 1))
    let minimal = try ClaudeSessionFile.parse(Data(#"{"pid":42,"sessionId":"id"}"#.utf8))
    #expect(minimal.cwd == nil)
    let wrongField = try ClaudeSessionFile.parse(
      Data(#"{"pid":42,"sessionId":"id","cwd":false}"#.utf8))
    #expect(wrongField.cwd == nil)
    #expect(!wrongField.diagnostics.isEmpty)
    for json in ["{}", "not-json", #"{"pid":"42","sessionId":"id"}"#] {
      #expect(throws: (any Error).self) { try ClaudeSessionFile.parse(Data(json.utf8)) }
    }
  }

  @Test func keyFilesNeverOpened() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: dir) }
    try Data("INVALID SECRET MUST NOT PARSE".utf8).write(to: dir.appendingPathComponent("123.key"))
    try Data(#"{"pid":42,"sessionId":"id"}"#.utf8).write(to: dir.appendingPathComponent("42.json"))
    #expect(try ClaudeSessionFileScanner.scanReport(directory: dir).files.count == 1)
  }

  @Test(arguments: ["", "%9", "name:@x.%9", "name:@4.%x", "name:@4.%9.extra", "name:@4.%9\n"])
  func badTmuxReturnsNil(_ input: String) { #expect(ClaudeSessionFile.parseTmux(input) == nil) }

  @Test func transcriptSidechainsAndLastText() throws {
    let data = Data(
      """
      {"type":"ai-title","aiTitle":"Title"}
      {"type":"assistant","gitBranch":"main","message":{"model":"model","content":[{"type":"text","text":"first"},{"type":"text","text":"last\\nline"}]}}
      {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sidechain"}]}}
      """.utf8)
    let result = try TranscriptTailReader.parse(data, dropFirstLine: false)
    #expect(result.title == "Title")
    #expect(result.snippet == "last line")
    #expect(result.model == "model")
    #expect(result.gitBranch == "main")
  }

  @Test func transcriptTruncatedHeadAndEmpty() throws {
    let result = try TranscriptTailReader.parse(
      Data(
        "truncated\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n"
          .utf8), dropFirstLine: true)
    #expect(result.snippet == "ok")
    #expect(result.title == nil)
    #expect(try TranscriptTailReader.parse(Data(), dropFirstLine: false) == SessionEnrichment())
    #expect(throws: (any Error).self) {
      try TranscriptTailReader.parse(Data("malformed\n".utf8), dropFirstLine: false)
    }
  }

  @Test func transcriptReadsOnlyBoundedEnds() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jsonl")
    defer { try! FileManager.default.removeItem(at: path) }
    let title = Data("{\"type\":\"ai-title\",\"aiTitle\":\"header\"}\n".utf8)
    let largeLine = Data(
      ("{\"padding\":\"" + String(repeating: "x", count: 400_000) + "\"}\n").utf8)
    let assistant = Data(
      "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"tail\"}]}}\n"
        .utf8)
    try (title + largeLine + assistant).write(to: path)
    let result = try TranscriptTailReader.read(path)
    #expect(result.title == "header")
    #expect(result.snippet == "tail")
  }

  @Test func snippetStripsMarkdown() {
    #expect(plainText("**复审结论：上次提的** `R1` 已修复") == "复审结论：上次提的 R1 已修复")
    #expect(plainText("## 标题\n- 第一项\n> 引用 [链接](http://x)") == "标题 第一项 引用 链接")
    #expect(plainText("```swift\nlet a = 1\n```") == "let a = 1")
    #expect(plainText("| a | b |\n|---|---|") == "| a | b |")
    #expect(plainText("__init__ 保留") == "__init__ 保留")
  }

  @Test func appLogKeepsOnlyRecentDays() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-log-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = try AppLog(directory: dir)
    let now = Date()
    let iso = ISO8601DateFormatter()
    func line(_ daysAgo: Double, _ text: String) -> String {
      iso.string(from: now.addingTimeInterval(-daysAgo * 86400)) + " " + text + "\n"
    }
    let current = dir.appendingPathComponent("app.log")
    let rotated = dir.appendingPathComponent("app.log.1")
    try (line(5, "old") + line(4, "older") + line(2, "kept")).write(to: current, atomically: true, encoding: .utf8)
    try line(6, "stale").write(to: rotated, atomically: true, encoding: .utf8)
    try log.write("new", now: now)
    let text = try String(contentsOf: current, encoding: .utf8)
    #expect(!text.contains("old") && text.hasPrefix(line(2, "kept")) && text.hasSuffix(" new\n"))
    #expect(!FileManager.default.fileExists(atPath: rotated.path))
    let mode = try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }
}
