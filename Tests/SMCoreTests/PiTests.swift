import Foundation
import SMProtocol
import Testing

@testable import SMCore

/// Line shapes copied from a real Pi 1.5.2 session file (~/.pi/agent/sessions), content shortened.
@Suite struct PiTests {
  static let header =
    #"{"type":"session","version":3,"id":"01a1cec7","timestamp":"2026-11-12T08:02:52.872Z","cwd":"/work/app"}"#
  static let modelChange =
    #"{"type":"model_change","id":"17d1c72a","parentId":null,"timestamp":"2026-11-12T08:02:52.898Z","provider":"modelrelay","modelId":"deepseek-flash"}"#
  static let system =
    #"{"type":"message","id":"bfd5a5ce","parentId":"5d4c87ec","timestamp":"2026-11-12T08:03:40.132Z","message":{"role":"system","content":"","sections":{"preamble":"You are"},"timestamp":1}}"#
  static let user =
    #"{"type":"message","id":"65f4419f","parentId":"bfd5a5ce","timestamp":"2026-11-12T08:03:40.133Z","message":{"role":"user","content":[{"type":"text","text":"增加 pi 支持"}],"timestamp":1}}"#
  static func assistant(id: String, output: Int, text: String = "好的") -> String {
    #"{"type":"message","id":"\#(id)","parentId":"65f4419f","timestamp":"2026-11-12T08:03:48.508Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"先看仓库"},{"type":"text","text":"\#(text)"},{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"git status"}}],"api":"openai-responses","provider":"modelrelay","model":"claude-opus-5-5","usage":{"input":1872,"output":\#(output),"cacheRead":7489,"cacheWrite":0,"reasoning":0,"totalTokens":9489},"stopReason":"toolUse","timestamp":1}}"#
  }
  static let toolResult =
    #"{"type":"message","id":"1a63e860","parentId":"d8b396f5","timestamp":"2026-11-12T08:03:48.786Z","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","content":[{"type":"text","text":"On branch main\nclean"}],"isError":false,"timestamp":1}}"#
  static let named =
    #"{"type":"session_info","id":"k1l2m3n4","parentId":"x","timestamp":"2026-11-12T08:05:00.000Z","name":"Pi 支持"}"#

  private func temp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sm-pi-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func envelope(_ json: String, pid: Int32? = 4242) throws -> HookEnvelope {
    HookEnvelope(
      source: "pi", agentPid: pid, env: ["TMUX_PANE": "%3", "TTY": "/dev/ttys022"],
      payload: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  @Test @MainActor func extensionEventsDriveTheRow() throws {
    let store = SessionStore()
    let source = PiSource(discover: { [] })
    let base = #""session_id":"s1","cwd":"/work/app","transcript_path":"/tmp/s1.jsonl""#
    let steps: [(String, SessionState)] = [
      (#"{\#(base),"hook_event_name":"SessionStart","source":"startup"}"#, .idle),
      (#"{\#(base),"hook_event_name":"UserPromptSubmit"}"#, .working),
      (#"{\#(base),"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"git status"}}"#, .working),
      (#"{\#(base),"hook_event_name":"PostToolUse","tool_name":"bash"}"#, .working),
      (#"{\#(base),"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","message":"Allow?"}"#, .needsInput),
      (#"{\#(base),"hook_event_name":"PromptEnded","state":"working"}"#, .working),
      (#"{\#(base),"hook_event_name":"Stop","last_assistant_message":"**完成**"}"#, .done),
      (#"{\#(base),"hook_event_name":"UserPromptSubmit"}"#, .working),
      (#"{\#(base),"hook_event_name":"Interrupt"}"#, .idle),
      (#"{\#(base),"hook_event_name":"SessionEnd","reason":"quit"}"#, .ended),
    ]
    for (index, (json, state)) in steps.enumerated() {
      let session = try store.apply(source.normalize(envelope(json)))
      #expect(session.state == state, "step \(index)")
      if index == 2 { #expect(session.currentTool == "bash: git status") }
      if index == 6 { #expect(session.lastAssistantSnippet == "完成" && session.unread) }
    }
    #expect(store.sessions.map(\.id) == ["pi:4242"])
    #expect(store.sessions.first?.terminal.tmuxPane == "%3")
    #expect(throws: MonitorError.self) {
      try source.normalize(envelope(#"{\#(base),"hook_event_name":"Bogus"}"#))
    }
  }

  @Test @MainActor func idleDialogReturnsToIdle() throws {
    let store = SessionStore()
    let source = PiSource(discover: { [] })
    for event in [
      #"{"session_id":"s1","hook_event_name":"SessionStart"}"#,
      #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion"}"#,
      #"{"session_id":"s1","hook_event_name":"PromptEnded","state":"idle"}"#,
    ] {
      _ = try store.apply(source.normalize(envelope(event)))
    }
    let row = try #require(store.sessions.first)
    #expect(row.state == .idle)
    #expect(row.attentionMessage == nil && row.currentTool == nil && !row.unread)
    #expect(throws: MonitorError.self) {
      try source.normalize(envelope(#"{"session_id":"s1","hook_event_name":"PromptEnded","state":"invalid"}"#))
    }
  }

  @Test func extensionResetsRepliesAndReportsCompactionOutcomes() async throws {
    let dir = try temp()
    defer { try? FileManager.default.removeItem(at: dir) }
    try PiExtension.source.write(to: dir.appendingPathComponent("extension.ts"), atomically: true, encoding: .utf8)
    let script = #"""
    import assert from "node:assert/strict";
    import childProcess from "node:child_process";
    import { syncBuiltinESMExports } from "node:module";
    const payloads = [];
    childProcess.spawnSync = (_file, _args, options) => {
      payloads.push(JSON.parse(options.input));
      return { status: 0 };
    };
    syncBuiltinESMExports();
    const { default: extension } = await import("./extension.ts");
    const handlers = new Map();
    extension({ on: (name, handler) => handlers.set(name, handler) });
    const ctx = {
      cwd: "/work/app", isIdle: () => false,
      sessionManager: { getSessionId: () => "s1", getSessionFile: () => "/tmp/s1.jsonl" },
    };
    const emit = async (name, event = {}) => handlers.get(name)(event, ctx);
    await emit("session_start", { reason: "startup" });
    await emit("before_agent_start");
    await emit("turn_end", { message: { content: [{ type: "text", text: "first reply" }] } });
    await emit("agent_settled", { aborted: false });
    assert.equal(payloads.at(-1).last_assistant_message, "first reply");
    await emit("before_agent_start");
    await emit("turn_end", { message: { content: [] } });
    await emit("agent_settled", { aborted: false });
    assert.equal(payloads.at(-1).last_assistant_message, "");
    for (const reason of ["manual", "threshold", "overflow"]) {
      for (const end of ["session_compact", "session_compact_failed"]) {
        await emit("session_before_compact", { reason });
        assert.equal(payloads.at(-1).hook_event_name, "PreCompact");
        await emit(end, { reason });
        assert.equal(payloads.at(-1).hook_event_name, "PostCompact");
        assert.equal(payloads.at(-1).state, reason === "manual" ? "idle" : "working");
      }
    }
    """#
    let harness = dir.appendingPathComponent("test.mjs")
    try script.write(to: harness, atomically: true, encoding: .utf8)
    _ = try await ProcessRunner.run("/usr/bin/env", arguments: ["node", harness.path], timeout: 10)
  }

  @Test @MainActor func compactionShowsWorkAndClearsTheTool() throws {
    let source = PiSource(discover: { [] })
    for state in ["idle", "working"] {
      let store = SessionStore()
      let start = try store.apply(source.normalize(envelope(
        #"{"session_id":"s1","hook_event_name":"PreCompact"}"#)))
      #expect(start.state == .working && start.currentTool == "压缩上下文")
      let end = try store.apply(source.normalize(envelope(
        #"{"session_id":"s1","hook_event_name":"PostCompact","state":"\#(state)"}"#)))
      #expect(end.state.rawValue == state)
      #expect(end.currentTool == nil && !end.unread)
    }
  }

  @Test @MainActor func emptyReplyDoesNotReuseAnEarlierSnippet() async throws {
    let dir = try temp()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s1.jsonl")
    try (Self.assistant(id: "a1", output: 10) + "\n")
      .write(to: file, atomically: true, encoding: .utf8)
    let source = PiSource(discover: { [] })
    let store = SessionStore()
    _ = try store.apply(source.normalize(envelope(
      #"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"old reply"}"#)))
    let row = try store.apply(source.normalize(envelope(
      #"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":""}"#)))
    #expect(row.state == .done && row.lastAssistantSnippet == nil)
    var session = row
    session.transcriptPath = file.path
    let info = try #require(await source.enrich(session))
    store.applyEnrichment(info, id: row.id, sessionID: row.currentSessionId)
    #expect(store.sessions.first?.lastAssistantSnippet == nil)
    session.source = .processScan
    #expect(try await source.enrich(session)?.snippet == "好的")
  }

  @Test func scanLeavesAmbiguousTranscriptsPending() throws {
    let dir = try temp()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = dir.appendingPathComponent("a_01a1cec7.jsonl")
    let second = dir.appendingPathComponent("b_second.jsonl")
    try (Self.header + "\n").write(to: first, atomically: true, encoding: .utf8)
    try (Self.header.replacingOccurrences(of: "01a1cec7", with: "second") + "\n")
      .write(to: second, atomically: true, encoding: .utf8)
    let a = PiProcess(pid: 1, tty: "", cwd: "/work/app", startTime: nil)
    let b = PiProcess(pid: 2, tty: "", cwd: "/work/app", startTime: nil)
    #expect(PiSessionIndex.matches(for: [a, b], after: [:], excluding: [], root: dir).isEmpty)
    #expect(PiSessionIndex.find(for: a, root: dir) == nil)
    let matches = PiSessionIndex.matches(
      for: [b], after: [:], excluding: ["01a1cec7"], root: dir)
    #expect(matches[2]?.sessionID == "second")
    #expect(PiSessionIndex.matches(
      for: [b], after: [2: Date(timeIntervalSinceNow: 60)], excluding: [], root: dir).isEmpty)
    try FileManager.default.removeItem(at: second)
    #expect(PiSessionIndex.matches(for: [a, b], after: [:], excluding: [], root: dir).isEmpty)
  }

  @Test func configuredPiContextWindowsOverrideFamilyDefaults() throws {
    let home = try temp()
    defer { try? FileManager.default.removeItem(at: home) }
    let agent = home.appendingPathComponent(".pi/agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    let config = agent.appendingPathComponent("models.json")
    try Data(#"{"providers":{"r":{"models":[{"id":"claude-opus-5-5","contextWindow":200000},{"id":"custom","contextWindow":64000}],"modelOverrides":{"claude-opus-5-5":{"contextWindow":128000},"builtin":{"contextWindow":32000}}}}}"#.utf8)
      .write(to: config)
    let file = home.appendingPathComponent("session.jsonl")
    try (Self.assistant(id: "a1", output: 10) + "\n")
      .write(to: file, atomically: true, encoding: .utf8)
    var reader = UsageReader(kind: .pi, home: home)
    _ = try reader.read(file) { _ in }
    #expect(reader.contextWindow == 128_000)
    #expect(PiModelCatalog.contextWindow("custom", home: home) == 64_000)
    #expect(PiModelCatalog.contextWindow("builtin", home: home) == 32_000)
    #expect(PiModelCatalog.contextWindow("custom", home: home.appendingPathComponent("other")) == nil)
  }

  @Test func sessionFileGivesTitleModelSnippetAndConversation() throws {
    let lines = [Self.header, Self.modelChange, Self.system, Self.user, Self.assistant(id: "a1", output: 128), Self.toolResult, Self.named]
    let enrichment = try PiSessionReader.parse(Data((lines.joined(separator: "\n") + "\n").utf8), dropFirstLine: false)
    #expect(enrichment.title == "Pi 支持")
    #expect(enrichment.model == "claude-opus-5-5")
    #expect(enrichment.snippet == "好的")
    let entries = lines.flatMap { TranscriptParser.entries(Data($0.utf8), kind: .pi, offset: 0) }
    #expect(entries.map(\.role) == [.user, .thinking, .assistant, .tool, .toolResult])
    #expect(entries[3].text == "bash: git status")
    #expect(entries[4].text == "On branch main")
  }

  @Test func usageCountsAssistantMessagesOnce() throws {
    let dir = try temp()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"{"providers":{"r":{"models":[{"id":"deepseek-flash","contextWindow":1048576}]}}}"#.utf8)
      .write(to: dir.appendingPathComponent("models.json"))
    let file = dir.appendingPathComponent("s.jsonl")
    let usageEntry =
      #"{"type":"usage","id":"u1","parentId":"x","timestamp":"2026-11-12T08:08:00.000Z","kind":"cache_warm","provider":"r","model":"deepseek-flash","usage":{"input":0,"output":0,"cacheRead":500,"cacheWrite":0}}"#
    try ([Self.header, Self.modelChange, Self.user, Self.assistant(id: "a1", output: 128), Self.assistant(id: "a2", output: 10), usageEntry, ""]
      .joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
    var reader = UsageReader(kind: .pi, home: dir)
    var contributions: [UsageContribution] = []
    #expect(try reader.read(file) { contributions.append($0) })
    let total = contributions.reduce(TokenUsage()) { $0 + $1.usage }
    #expect(total == TokenUsage(input: 3744, cacheRead: 15478, cacheWrite: 0, output: 138))
    #expect(contributions.first?.cwd == "/work/app")
    #expect(reader.model == "claude-opus-5-5")
    #expect(reader.contextTokens == 9361 && reader.contextWindow == 1_000_000)
    #expect(PiModelCatalog.parse(dir.appendingPathComponent("models.json"))["deepseek-flash"] == 1_048_576)
  }

  @Test @MainActor func scannedTUIAdoptsItsSessionFile() throws {
    let dir = try temp()
    defer { try? FileManager.default.removeItem(at: dir) }
    let project = dir.appendingPathComponent("--work-app--")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("2026-11-12T08-02-52-872Z_01a1cec7.jsonl")
    try (Self.header + "\n").write(to: file, atomically: true, encoding: .utf8)
    let process = PiProcess(pid: 4242, tty: "/dev/ttys022", cwd: "/work/app", startTime: Date(timeIntervalSinceNow: -60))
    let match = PiSessionIndex.find(for: process, root: dir)
    // macOS resolves /var → /private/var; compare via standardizedFileURL.
    func norm(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    #expect(match?.sessionID == "01a1cec7")
    #expect(match.map { norm($0.path) } == norm(file.path))
    #expect(PiSessionIndex.find(sessionID: "01a1cec7", root: dir).map { norm($0.path) } == norm(file.path))
    #expect(PiSessionIndex.find(for: PiProcess(pid: 1, tty: "", cwd: "/other", startTime: nil), root: dir) == nil)
    let store = SessionStore()
    store.upsertScannedPi(process, session: nil, tmuxPane: "%3", now: Date())
    #expect(store.sessions.first?.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) == true)
    store.upsertScannedPi(process, session: match, tmuxPane: nil, now: Date())
    #expect(store.sessions.first?.currentSessionId == "01a1cec7")
    #expect(store.sessions.first?.transcriptPath.map(norm) == norm(file.path))
    #expect(store.sessions.first?.terminal.tmuxPane == "%3")
  }
}
