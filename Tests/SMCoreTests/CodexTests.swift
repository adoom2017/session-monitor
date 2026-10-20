import Foundation
import Testing

@testable import SMCore

/// Built from a real Codex CLI 0.163.0 session (docs/payload-samples/timelines/codex-probe*.jsonl).
@Suite struct CodexTests {
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let rollout = root.appendingPathComponent(
    "docs/payload-samples/timelines/codex-probe-rollout.jsonl")

  private func timeline() throws -> [HookEnvelope] {
    let data = try Data(
      contentsOf: Self.root.appendingPathComponent("docs/payload-samples/timelines/codex-probe.jsonl"))
    return try data.split(separator: 10).map {
      try JSONDecoder().decode(HookEnvelope.self, from: Data($0))
    }
  }

  @Test @MainActor func realCodexTimeline() throws {
    let store = SessionStore()
    let events = try timeline()
    #expect(events.count == 19)
    var states: [(String, Session)] = []
    for envelope in events {
      let session = try store.apply(CodexSource().normalize(envelope))
      states.append((envelope.payload["hook_event_name"]?.string ?? "?", session))
    }
    // One row for the whole session, keyed by the TUI process.
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.id == "codex:84234")
    #expect(store.sessions.first?.kind == .codex)
    // Turn 1: Stop carries last_assistant_message.
    #expect(states[2].0 == "Stop" && states[2].1.state == .done && states[2].1.unread)
    #expect(states[2].1.lastAssistantSnippet == "OK")
    // Tool turn: Bash summary, then back to working.
    #expect(states[4].1.currentTool == "Bash: touch /tmp/sm-codex-probe-outside.txt")
    // Sandbox denial: Stop with a null last_assistant_message keeps the previous snippet.
    #expect(states[10].0 == "Stop" && states[10].1.state == .done)
    // Escalation: PermissionRequest uses tool_input.description, then auto-approval resumes work.
    #expect(states[13].0 == "PermissionRequest" && states[13].1.state == .needsPermission)
    #expect(states[13].1.attentionMessage?.hasPrefix("May I create the requested empty file") == true)
    #expect(states[14].0 == "PostToolUse" && states[14].1.state == .working)
    // Interrupted turn: no hook after PreToolUse, so the session still looks busy...
    #expect(states[17].0 == "PreToolUse" && states[17].1.state == .working)
    #expect(states[18].0 == "SessionEnd" && states[18].1.state == .ended)
  }

  @Test @MainActor func interruptedTurnIsResolvedFromRollout() async throws {
    let store = SessionStore()
    // Mirrors the interrupted turn (last hook 09:56:39Z) with a live pid so liveness keeps it.
    let lastHook = Date(timeIntervalSince1970: 1_792_403_799)
    for (offset, type) in [EventType.promptSubmitted, .toolStart(name: "Bash", summary: "sleep 30")]
      .enumerated()
    {
      try store.apply(
        AgentEvent(
          kind: .codex, sessionId: "01a15393", agentPid: getpid(),
          transcriptPath: Self.rollout.path, at: lastHook.addingTimeInterval(Double(offset - 1)),
          type: type))
    }
    #expect(store.sessions.first?.state == .working)
    try await CodexSource(discover: { [] }).reconcile(store: store)
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.state == .idle)
    #expect(store.sessions.first?.unread == false)
  }

  @Test func rolloutReader() throws {
    #expect(
      try CodexRolloutReader.lastTurnEnd(Self.rollout)?.aborted == true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-rollout-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String, _ text: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      try Data(text.utf8).write(to: url)
      return url
    }
    let started = #"{"timestamp":"2026-10-19T09:56:36.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let complete = #"{"timestamp":"2026-10-19T09:56:40.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    #expect(try CodexRolloutReader.lastTurnEnd(file("running.jsonl", complete + "\n" + started + "\n")) == nil)
    let done = try CodexRolloutReader.lastTurnEnd(file("done.jsonl", started + "\n" + complete + "\n"))
    #expect(done?.aborted == false)
    // A partially written last line (no trailing newline) is skipped; a corrupt line that is
    // fully written (newline-terminated) is an error, not something to skip.
    #expect(
      try CodexRolloutReader.lastTurnEnd(file("partial.jsonl", complete + "\n" + #"{"type":"ev"#))?
        .aborted == false)
    #expect(throws: (any Error).self) {
      try CodexRolloutReader.lastTurnEnd(file("corrupt.jsonl", started + "\n" + "{broken\n"))
    }
  }

  @Test func desktopAppThreadsAreKeyedBySessionAndJumpToApp() throws {
    let payload = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(#"{"session_id":"thread-1","hook_event_name":"UserPromptSubmit","cwd":"/w"}"#.utf8))
    let event = try CodexSource().normalize(
      HookEnvelope(source: "codex", agentPid: 38970, env: ["TTY": nil], payload: payload))
    #expect(event.agentPid == nil)
    #expect(event.key == "codex:sid:thread-1")
    #expect(event.terminal.termProgram == CodexSource.desktopProgram)
    #expect(
      try TerminalPolicy.activationBundle(
        program: event.terminal.termProgram, running: [CodexSource.desktopBundleID])
        == CodexSource.desktopBundleID)
  }

  @Test func claudeStopAlsoCarriesAssistantMessage() throws {
    let payload = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        #"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"**已修复** `login`"}"#.utf8))
    let event = try ClaudeSource().normalize(
      HookEnvelope(source: "claude", agentPid: 7, env: ["TTY": "/dev/ttys001"], payload: payload))
    let session = try SessionReducer.reduce(nil, event)
    #expect(session.state == .done && session.lastAssistantSnippet == "已修复 login")
  }

  @Test func interruptedEventGoesIdle() throws {
    var s = try SessionReducer.reduce(
      nil, AgentEvent(kind: .codex, sessionId: "s", agentPid: 1, type: .promptSubmitted))
    s = try SessionReducer.reduce(
      s, AgentEvent(kind: .codex, sessionId: "s", agentPid: 1, type: .interrupted))
    #expect(s.state == .idle && !s.unread && s.currentTool == nil)
  }

  @Test func discoveryClassifiesRealArgvShapes() {
    func classify(_ args: [String]) -> CodexProcess? {
      CodexDiscovery.classify(pid: 1, tty: "/dev/ttys001", arguments: args, cwd: "/w", startTime: nil)
    }
    #expect(classify(["codex"])?.resumeID == nil)
    #expect(classify(["codex", "resume", "01a13e35-92f1"])?.resumeID == "01a13e35-92f1")
    #expect(classify(["codex", "-c", "model_reasoning_effort=low"]) != nil)
    #expect(classify(["codex", "exec", "fix the tests"]) != nil)
    #expect(classify(["/x/bin/codex", "app-server", "--listen", "unix://"]) == nil)
    #expect(classify(["codex", "agents"]) == nil)
    #expect(classify(["codex", "sandbox", "-c", "x"]) == nil)
  }

  @Test func rolloutIndexFindsByResumeIDThenDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-codex-index-\(UUID().uuidString.prefix(8))")
    let day = root.appendingPathComponent("2026/10/20")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func rollout(_ id: String, cwd: String) throws -> URL {
      let url = day.appendingPathComponent("rollout-2026-10-20T09-00-00-\(id).jsonl")
      let meta = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#
      try Data((meta + "\n").utf8).write(to: url)
      return url
    }
    let a = try rollout("aaaa", cwd: "/work/demucs")
    _ = try rollout("bbbb", cwd: "/work/meitu")
    let byResume = CodexProcess(pid: 1, tty: "/dev/ttys1", cwd: "/x", startTime: nil, resumeID: "aaaa")
    let found = CodexRolloutIndex.find(for: byResume, root: root)
    #expect(found?.sessionID == "aaaa")
    #expect(found.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() } == a.resolvingSymlinksInPath())
    let byDirectory = CodexProcess(pid: 2, tty: "/dev/ttys2", cwd: "/work/meitu", startTime: nil)
    #expect(CodexRolloutIndex.find(for: byDirectory, root: root)?.sessionID == "bbbb")
    // A TUI started after the newest rollout has not had its first prompt yet.
    let fresh = CodexProcess(
      pid: 3, tty: "/dev/ttys3", cwd: "/work/meitu", startTime: Date().addingTimeInterval(60))
    #expect(CodexRolloutIndex.find(for: fresh, root: root) == nil)
  }

  @Test @MainActor func scannedRowsStayUntilProcessExitsAndYieldToHooks() throws {
    let store = SessionStore()
    let process = CodexProcess(pid: getpid(), tty: "/dev/ttys023", cwd: "/work/p", startTime: nil)
    store.upsertScannedCodex(
      process, sessionID: nil, rolloutPath: nil, tmuxPane: "%12", running: nil, now: Date())
    var row = try #require(store.sessions.first)
    #expect(row.id == "codex:\(getpid())" && row.source == .processScan && row.state == .idle)
    #expect(row.terminal.tmuxPane == "%12" && row.terminal.tty == "/dev/ttys023")
    // Busy/idle from the rollout for scan-only rows.
    store.upsertScannedCodex(process, sessionID: nil, rolloutPath: nil, tmuxPane: nil, running: true, now: Date())
    #expect(store.sessions.first?.state == .working)
    store.upsertScannedCodex(process, sessionID: nil, rolloutPath: nil, tmuxPane: nil, running: false, now: Date())
    row = try #require(store.sessions.first)
    #expect(row.state == .done && row.unread)
    // The first hook event takes over the same row (pending id replaced by the real thread id).
    let hooked = try store.apply(
      AgentEvent(
        kind: .codex, sessionId: "01a15393", agentPid: getpid(), at: Date().addingTimeInterval(1),
        type: .promptSubmitted))
    #expect(store.sessions.count == 1 && hooked.source == .hooks && hooked.state == .working)
    // Later scans never override hook-driven state.
    store.upsertScannedCodex(process, sessionID: nil, rolloutPath: nil, tmuxPane: nil, running: false, now: Date())
    #expect(store.sessions.first?.state == .working)
    // Idle for hours: still listed (no 30-minute expiry for pid rows); gone only when pid dies.
    store.reconcile(files: [], liveness: [getpid(): true], now: Date().addingTimeInterval(7200))
    #expect(store.sessions.count == 1)
    store.reconcile(files: [], liveness: [getpid(): false], now: Date().addingTimeInterval(7200))
    #expect(store.sessions.first?.state == .ended)
  }

  /// Real case (meitu, 2026-10-20): `webrun` tool hooks run outside the codex process tree, so
  /// sm-hook finds no agent. They must not mark the terminal session as desktop-hosted.
  @Test @MainActor func hooksWithoutAgentKeepTheTerminalRow() throws {
    let store = SessionStore()
    func envelope(_ event: String, pid: Int32?, tty: String?, tool: String? = nil) throws -> HookEnvelope {
      let toolPart = tool.map { #","tool_name":"\#($0)","tool_input":{}"# } ?? ""
      let payload = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"session_id":"meitu-1","hook_event_name":"\#(event)","cwd":"/work/meitu"\#(toolPart)}"#.utf8))
      return HookEnvelope(
        source: "codex", agentPid: pid, env: ["TTY": tty, "TERM_PROGRAM": tty == nil ? nil : "ghostty"],
        payload: payload)
    }
    try store.apply(CodexSource().normalize(envelope("UserPromptSubmit", pid: 96387, tty: "/dev/ttys014")))
    let toolEvent = try CodexSource().normalize(envelope("PreToolUse", pid: nil, tty: nil, tool: "webrun"))
    #expect(toolEvent.terminal.termProgram == nil)
    let row = try store.apply(toolEvent)
    #expect(store.sessions.count == 1 && row.id == "codex:96387")
    #expect(row.terminal.termProgram == "ghostty" && row.terminal.tty == "/dev/ttys014")
    #expect(try Jumper.target(for: row) == .local(cwd: "/work/meitu", tty: "/dev/ttys014", termProgram: "ghostty"))
  }

  /// Real case (libtv, 2026-10-20): hooks of a Codex TUI arrived without a usable pid before the
  /// process-scan row knew its session id, producing two rows for one session.
  @MainActor @Test func sessionIDRowsMergeIntoProcessRow() throws {
    let store = SessionStore()
    let base = Date()
    // Desktop-classified events (pid present, no tty) → keyed by session id.
    for (offset, type) in [EventType.sessionStart(reason: "resume"), .promptSubmitted].enumerated() {
      try store.apply(
        AgentEvent(
          kind: .codex, sessionId: "01a156ed", agentPid: nil, cwd: "/work/libtv",
          at: base.addingTimeInterval(Double(offset)), type: type,
          terminal: TerminalInfo(termProgram: CodexSource.desktopProgram)))
    }
    // The process scan finds the TUI and, via the rollout, the same session id.
    let process = CodexProcess(pid: getpid(), tty: "/dev/ttys006", cwd: "/work/libtv", startTime: nil)
    store.upsertScannedCodex(
      process, sessionID: "01a156ed", rolloutPath: nil, tmuxPane: nil, running: nil,
      now: base.addingTimeInterval(-10))
    #expect(store.sessions.count == 2)
    store.mergeSessionIDDuplicates()
    let row = try #require(store.sessions.first)
    #expect(store.sessions.count == 1 && row.id == "codex:\(getpid())")
    #expect(row.state == .working && row.source == .hooks)  // newer hook state wins
    #expect(row.terminal.tty == "/dev/ttys006" && row.terminal.termProgram == nil)
    // Later events without a pid attach by session id but cannot rewrite the terminal.
    let later = try store.apply(
      AgentEvent(
        kind: .codex, sessionId: "01a156ed", agentPid: nil, at: base.addingTimeInterval(5),
        type: .toolStart(name: "webrun", summary: nil),
        terminal: TerminalInfo(termProgram: CodexSource.desktopProgram)))
    #expect(store.sessions.count == 1 && later.terminal.termProgram == nil)
    #expect(try Jumper.target(for: later) != .app(termProgram: CodexSource.desktopProgram))
  }

  @MainActor @Test func staleEndedSessionIDRowIsDroppedNotMerged() throws {
    let store = SessionStore()
    try store.apply(
      AgentEvent(kind: .codex, sessionId: "s1", agentPid: nil, at: Date(), type: .sessionEnd(reason: "other")))
    let process = CodexProcess(pid: getpid(), tty: "/dev/ttys023", cwd: "/w", startTime: nil, resumeID: "s1")
    store.upsertScannedCodex(process, sessionID: "s1", rolloutPath: nil, tmuxPane: nil, running: nil, now: Date())
    store.mergeSessionIDDuplicates()
    #expect(store.sessions.count == 1 && store.sessions.first?.state == .idle)
  }

  /// Real case (libtv, 2026-10-20): the auto-review "guardian" sub-agent thread has its own
  /// session id and fired hooks that showed up as a second libtv row.
  @MainActor @Test func guardianSubagentThreadAttachesToParent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-guardian-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollout = directory.appendingPathComponent("rollout-guardian-sub-\(UUID().uuidString.prefix(4)).jsonl")
    let meta = #"{"type":"session_meta","payload":{"id":"sub-1","cwd":"/work/libtv","parent_thread_id":"main-1","source":{"subagent":{"other":"guardian"}}}}"#
    try Data((meta + "\n").utf8).write(to: rollout)
    let store = SessionStore()
    try store.apply(
      AgentEvent(kind: .codex, sessionId: "main-1", agentPid: getpid(), cwd: "/work/libtv",
                 at: Date(), type: .promptSubmitted, terminal: TerminalInfo(tty: "/dev/ttys006")))
    func hook(_ name: String, _ offset: Double) throws -> AgentEvent {
      let payload = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(#"{"session_id":"sub-1","hook_event_name":"\#(name)","cwd":"/work/libtv","transcript_path":"\#(rollout.path)"}"#.utf8))
      return try CodexSource().normalize(
        HookEnvelope(
          source: "codex", receivedAt: (Date().timeIntervalSince1970 + offset) * 1000, agentPid: nil,
          env: ["TTY": nil], payload: payload))
    }
    for (index, name) in ["SessionStart", "UserPromptSubmit", "Stop"].enumerated() {
      let event = try hook(name, Double(index + 1))
      #expect(event.sessionId == "main-1" && event.agentId == "sub-1")
      try store.apply(event)
    }
    #expect(store.sessions.count == 1)
    let row = try #require(store.sessions.first)
    #expect(row.state == .working)  // the guardian's Stop does not end the main turn
    #expect(row.terminal.tty == "/dev/ttys006")
  }
}
