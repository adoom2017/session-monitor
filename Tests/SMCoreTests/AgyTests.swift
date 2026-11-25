import Foundation
import SMProtocol
import Testing

@testable import SMCore

@Suite struct AgyTests {
  @Test func contextTracksTheCLISnapshotForTheCurrentThread() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let transcript = AgySource.transcript(in: AgySource.brainDirectory(home: home).appendingPathComponent("sample"))
    try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    let line = #"{"type":"PLANNER_RESPONSE","model":"gemini-4-hydrogen-high","input_tokens":10837,"output_tokens":241}"#
    try Data((line + "\n").utf8).write(to: transcript)
    let source = AgySource()
    let session = Session(event: try source.normalize(HookEnvelope(source: "agy", agentPid: 42, payload: .object([
      "hookEventName": .string("SessionStart"), "conversationId": .string("sample"),
    ]))))
    let tracker = UsageTracker(home: home)
    let starting = await tracker.update([session])[session.id]
    #expect(starting?.contextFraction == nil)

    let statusLine = #"{"conversation_id":"sample","context_window":{"total_input_tokens":15757,"total_output_tokens":241,"context_window_size":1048576,"used_percentage":1.5027046203613281,"current_usage":{"input_tokens":10837,"output_tokens":241,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    try AgyContext.record(Data(statusLine.utf8), home: home, pid: 42)
    let usage = await tracker.update([session])[session.id]
    #expect(usage?.contextTokens == 15_757)
    #expect(usage?.contextWindow == 1_048_576)
    #expect(usage?.contextFraction == 0.015027046203613281)
    #expect(usage?.total == starting?.total)

    var newThread = session
    newThread.currentSessionId = "new"
    #expect(await tracker.update([newThread])[newThread.id] == nil)
    let newLine = #"{"conversation_id":"new","context_window":{"total_input_tokens":0,"context_window_size":1048576}}"#
    try AgyContext.record(Data(newLine.utf8), home: home, pid: 42)
    #expect(await tracker.update([newThread])[newThread.id]?.contextFraction == 0)
  }

  @Test @MainActor func capturedLifecycleAdoptsDiscoveredProcess() throws {
    let source = AgySource()
    let store = SessionStore()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("docs/payload-samples/timelines/agy-probe.jsonl")
    let hooks = try Data(contentsOf: fixture).split(separator: 10).map {
      try JSONDecoder().decode(HookEnvelope.self, from: Data($0))
    }
    let first = try #require(hooks.first)
    let pid = try #require(first.agentPid)
    let time = Date(timeIntervalSince1970: first.receivedAt / 1000)
    store.upsertScannedAgy(pid: pid, cwd: "/work/app", terminal: TerminalInfo(tmuxPane: "%3"), now: time)
    #expect(store.sessions.first?.state == .idle)

    var states: [SessionState] = []
    for hook in hooks {
      let row = try store.apply(source.normalize(hook))
      states.append(row.state)
      #expect(row.source == .hooks)
      #expect(row.currentSessionId == "agy-sample")
      #expect(row.transcriptPath == hook.payload["transcriptPath"]?.string)
      #expect(row.terminal.tmuxPane == "%3")
      #expect(TmuxRemote.canSend(row))
    }
    #expect(states == [.idle, .working, .done])
    #expect(store.sessions.map(\.id) == ["agy:\(pid)"])
    #expect(store.sessions.first?.unread == true)
    store.reconcile(files: [], liveness: [pid: false], now: time.addingTimeInterval(3))
    #expect(store.sessions.first?.state == .ended)
  }

  @Test @MainActor func resumedConversationCanShowContextBeforeLifecycleHook() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let pid: Int32 = 42
    let startedAt = Date()
    let store = SessionStore()
    store.upsertScannedAgy(pid: pid, cwd: nil, terminal: TerminalInfo(), now: startedAt)
    let statusLine = #"{"conversation_id":"resumed","context_window":{"total_input_tokens":15757,"context_window_size":1048576}}"#
    try AgyContext.record(Data(statusLine.utf8), home: home, pid: pid)
    #expect(AgyContext.conversationID(home: home, pid: pid, startedAt: startedAt.addingTimeInterval(60)) == nil)
    let thread = try #require(AgyContext.conversationID(home: home, pid: pid, startedAt: startedAt))
    store.adoptScannedAgyConversation(pid: pid, conversationID: thread)
    let session = try #require(store.sessions.first)
    #expect(session.source == .processScan)
    #expect(session.currentSessionId == "resumed")
    let tracker = UsageTracker(home: home)
    #expect(await tracker.update(store.sessions)[session.id]?.contextTokens == 15_757)
    store.adoptScannedAgyConversation(pid: pid, conversationID: "other")
    #expect(store.sessions.first?.currentSessionId == "resumed")
  }

  @Test(arguments: ["USER_CANCELED", "ERROR", "NO_TOOL_CALL"])
  @MainActor func stopWhileStillActiveDoesNotNotify(reason: String) throws {
    let source = AgySource()
    let store = SessionStore()
    let start = HookEnvelope(source: "agy", agentPid: 34552, payload: .object([
      "hookEventName": .string("PreInvocation"), "conversationId": .string("sample"),
    ]))
    _ = try store.apply(source.normalize(start))
    let stop = HookEnvelope(source: "agy", agentPid: 34552, payload: .object([
      "hookEventName": .string("Stop"), "conversationId": .string("sample"),
      "terminationReason": .string(reason), "fullyIdle": .bool(false),
    ]))
    let row = try store.apply(source.normalize(stop))
    #expect(row.state == (reason == "NO_TOOL_CALL" ? .working : .idle))
    #expect(!row.unread)
  }

  @Test func agyTranscriptEntriesHandleAllRecordTypesAndResumedStepIndices() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("transcript_full.jsonl")

    let userLine = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-22T02:49:55Z","content":"<USER_REQUEST>\n<xml-like> 检查同步\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\ntime\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nmodel\n</USER_SETTINGS_CHANGE>"}"#
    let plannerLine = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-22T02:49:56Z","model":"gemini-4-neon-xhigh","thinking":"先看代码","content":"正在排查","tool_calls":[{"name":"run_command","args":{"CommandLine":"git status","toolSummary":"Check git status"}},{"name":"read_file","args":{"Path":"/tmp/a.swift"}},{"name":"invoke_subagent","args":{"Role":"Code Reviewer","Prompt":"Review very long prompt"}}]}"#
    let genericOK = #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-22T02:49:57Z","content":"Created At: 2026-11-22T10:49:57+08:00\nCompleted At: 2026-11-22T10:49:58+08:00\nCreated At: 2026-11-22T10:49:57+08:00\nCompleted At: 2026-11-22T10:49:58+08:00\nOn branch main\nclean"}"#
    let genericFail = #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"ERROR","error":"exit code 1","created_at":"2026-11-22T02:49:59Z","content":"Created At: 2026-11-22T10:49:59+08:00\nCompleted At: 2026-11-22T10:49:59+08:00\nfatal: error"}"#
    let errLine = #"{"step_index":4,"source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"API error: broken pipe","created_at":"2026-11-22T02:50:00Z"}"#
    let checkpointLine = #"{"step_index":5,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-11-22T02:50:01Z","content":"summary"}"#
    let systemLine = #"{"step_index":6,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-22T02:50:02Z","content":"<SYSTEM_MESSAGE>internal</SYSTEM_MESSAGE>"}"#

    let userEntries = TranscriptParser.entries(Data(userLine.utf8), kind: .agy, offset: 0)
    #expect(userEntries.count == 1)
    #expect(userEntries.first?.role == .user)
    #expect(userEntries.first?.text == "<xml-like> 检查同步")
    #expect(userEntries.first?.at != nil)

    let plannerEntries = TranscriptParser.entries(Data(plannerLine.utf8), kind: .agy, offset: 100)
    #expect(plannerEntries.map(\.role) == [.thinking, .assistant, .tool, .tool, .tool])
    #expect(plannerEntries[0].text == "先看代码")
    #expect(plannerEntries[1].text == "正在排查")
    #expect(plannerEntries[2].text == "run_command: Check git status")
    #expect(plannerEntries[3].text == "read_file: /tmp/a.swift")
    #expect(plannerEntries[4].text == "invoke_subagent: Code Reviewer")

    let okEntries = TranscriptParser.entries(Data(genericOK.utf8), kind: .agy, offset: 200)
    #expect(okEntries.count == 1 && okEntries[0].role == .toolResult)
    #expect(okEntries[0].text == "On branch main")
    #expect(okEntries[0].detail == "On branch main\nclean")

    let failEntries = TranscriptParser.entries(Data(genericFail.utf8), kind: .agy, offset: 300)
    #expect(failEntries[0].role == .toolResult && failEntries[0].text == "失败：fatal: error")

    let errEntries = TranscriptParser.entries(Data(errLine.utf8), kind: .agy, offset: 400)
    #expect(errEntries[0].role == .event && errEntries[0].text == "API error: broken pipe")

    let cpEntries = TranscriptParser.entries(Data(checkpointLine.utf8), kind: .agy, offset: 500)
    #expect(cpEntries[0].role == .event && cpEntries[0].text == "已压缩上下文")

    #expect(TranscriptParser.entries(Data(systemLine.utf8), kind: .agy, offset: 600).isEmpty)

    // Resumed agy sessions repeat step_index from 0; byte-offset ids keep both turns distinct.
    let resumedUser = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-22T02:51:00Z","content":"<USER_REQUEST>\n继续排查\n</USER_REQUEST>"}"#
    let resumedReply = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-22T02:51:01Z","model":"gemini-4-neon-xhigh","content":"**完成**"}"#
    try ([userLine, plannerLine, genericOK, resumedUser, ""].joined(separator: "\n"))
      .write(to: file, atomically: true, encoding: .utf8)

    let feed = TranscriptFeed(url: file, kind: .agy)
    try feed.load()
    let initial = feed.latest(20)
    #expect(initial.entries.count == 8)
    #expect(Set(initial.entries.map(\.id)).count == 8)
    let older = feed.page(before: try #require(initial.entries.last?.id), count: 2)
    #expect(older.entries.count == 2 && older.hasOlder)

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((resumedReply + "\n").utf8))
    try handle.close()
    let polled = try feed.poll()
    #expect(!polled.reset && polled.entries.map(\.text) == ["**完成**"])
    #expect(feed.latest(20).entries.map(\.id).last != initial.entries.map(\.id).last)
  }

  @Test func agyTranscriptPathAndConversationArg() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var pending = Session(event: AgentEvent(kind: .agy, sessionId: "pending-42", agentPid: 42, type: .sessionStart(reason: nil)))
    #expect(AgySource.transcript(of: pending, home: home) == nil)
    pending.currentSessionId = "conv-123"
    #expect(
      AgySource.transcript(of: pending, home: home)
        == home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-123/.system_generated/logs/transcript_full.jsonl"))
    pending.transcriptPath = "/custom/transcript_full.jsonl"
    #expect(AgySource.transcript(of: pending, home: home)?.path == "/custom/transcript_full.jsonl")

    #expect(AgySource.conversationArgument(from: ["agy", "--conversation=abc-1"]) == "abc-1")
    #expect(AgySource.conversationArgument(from: ["agy", "--model", "x", "--conversation", "abc-2"]) == "abc-2")
    #expect(AgySource.conversationArgument(from: ["agy", "--conversation", "--help"]) == nil)
    #expect(AgySource.conversationArgument(from: ["agy", "--conversation="]) == nil)
    #expect(AgySource.conversationArgument(from: ["agy"]) == nil)
  }

  @Test func agyEnrichmentReadsLatestModelAndSnippet() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let source = AgySource(home: home, discover: { [] })

    let pending = Session(event: AgentEvent(kind: .agy, sessionId: "pending-42", agentPid: 42, type: .sessionStart(reason: nil)))
    #expect(try await source.enrich(pending) == nil)

    let active = Session(event: AgentEvent(kind: .agy, sessionId: "conv-1", agentPid: 42, type: .stop))
    let missing = try await source.enrich(active)
    #expect(missing?.hasTranscript == false)

    let path = try #require(AgySource.transcript(of: active, home: home))
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = [
      #"{"type":"PLANNER_RESPONSE","model":"gemini-4-hydrogen-high","content":"旧回复"}"#,
      #"{"type":"PLANNER_RESPONSE","model":"gemini-4-neon-xhigh","content":"**已修复** sync 问题\n详情见测试"}"#,
      #"{"type":"PLANNER_RESPONSE","model":"gemini-4-neon-xhigh","tool_calls":[{"name":"run_command"}]}"#,
      #"{"type":"GENERIC","partial":true"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(to: path)

    let enriched = try #require(try await source.enrich(active))
    #expect(enriched.hasTranscript)
    #expect(enriched.model == "gemini-4-neon-xhigh")
    #expect(enriched.snippet == "已修复 sync 问题 详情见测试")
    #expect(enriched.diagnostics.count == 1)
  }

  @Test @MainActor func toolLifecycleAskQuestionAndExitPlanMode() throws {
    let source = AgySource()
    let store = SessionStore()
    let base = Date(timeIntervalSince1970: 1_795_100_000)

    func envelope(_ event: String, offset: Double, toolCall: JSONValue? = nil) -> HookEnvelope {
      var body: [String: JSONValue] = [
        "hookEventName": .string(event),
        "conversationId": .string("conv-tools"),
        "cwd": .string("/work/app"),
      ]
      if let toolCall { body["toolCall"] = toolCall }
      return HookEnvelope(
        source: "agy", receivedAt: (base.timeIntervalSince1970 + offset) * 1000,
        agentPid: 4242, payload: .object(body))
    }

    _ = try store.apply(source.normalize(envelope("PreInvocation", offset: 0)))

    // run_command shows command summary and PostToolUse clears currentTool.
    var row = try store.apply(source.normalize(envelope(
      "PreToolUse", offset: 1,
      toolCall: .object([
        "id": .string("c1"), "name": .string("run_command"),
        "args": .object(["CommandLine": .string("git status"), "toolSummary": .string("Check git status")]),
      ]))))
    #expect(row.state == .working && row.currentTool == "run_command: git status")

    row = try store.apply(source.normalize(envelope(
      "PostToolUse", offset: 2,
      toolCall: .object(["id": .string("c1"), "name": .string("run_command"), "args": .object([:])]))))
    #expect(row.state == .working && row.currentTool == nil)

    // File tools summarize by filename.
    row = try store.apply(source.normalize(envelope(
      "PreToolUse", offset: 3,
      toolCall: .object([
        "id": .string("c2"), "name": .string("read_file"),
        "args": .object(["Path": .string("/work/app/Sources/AgySource.swift")]),
      ]))))
    #expect(row.state == .working && row.currentTool == "read_file: AgySource.swift")

    // ask_question enters needsInput with the first question text, and PostToolUse returns to working.
    row = try store.apply(source.normalize(envelope(
      "PreToolUse", offset: 4,
      toolCall: .object([
        "id": .string("c3"), "name": .string("ask_question"),
        "args": .object([
          "questions": .array([
            .object(["question": .string("Tea or Coffee?"), "options": .array([.string("Tea"), .string("Coffee")])]),
          ]),
        ]),
      ]))))
    #expect(row.state == .needsInput)
    #expect(row.attentionMessage == "Tea or Coffee?")
    #expect(row.currentTool == "ask_question: Tea or Coffee?")

    row = try store.apply(source.normalize(envelope(
      "PostToolUse", offset: 5,
      toolCall: .object(["id": .string("c3"), "name": .string("ask_question"), "args": .object([:])]))))
    #expect(row.state == .working && row.attentionMessage == nil && row.currentTool == nil)

    // ask_question without questions falls back to default input prompt.
    row = try store.apply(source.normalize(envelope(
      "PreToolUse", offset: 6,
      toolCall: .object(["id": .string("c4"), "name": .string("ask_question"), "args": .object([:])]))))
    #expect(row.state == .needsInput && row.attentionMessage == "等待回答问题")

    // exit_plan_mode runs automatically in Orchestrator mode and must NOT enter needsInput.
    row = try store.apply(source.normalize(envelope(
      "PreToolUse", offset: 7,
      toolCall: .object(["id": .string("c5"), "name": .string("exit_plan_mode"), "args": .object([:])]))))
    #expect(row.state == .working && row.attentionMessage == nil && row.currentTool == "exit_plan_mode")

    // Invalid PreToolUse payloads fail loudly at the boundary.
    #expect(throws: MonitorError.self) {
      _ = try source.normalize(envelope("PreToolUse", offset: 8, toolCall: nil))
    }
    #expect(throws: MonitorError.self) {
      _ = try source.normalize(envelope(
        "PreToolUse", offset: 9,
        toolCall: .object(["name": .string("run_command"), "args": .string("bad")])))
    }
  }

  @Test func discoveryClassifiesInteractiveTUIsAndFiltersUtilities() {
    func classify(_ args: [String]) -> AgyProcess? {
      AgyDiscovery.classify(pid: 1, tty: "/dev/ttys001", arguments: args, cwd: "/w", startTime: nil)
    }

    #expect(classify(["agy"])?.conversationID == nil)
    #expect(classify(["agy", "--conversation=abc-1"])?.conversationID == "abc-1")
    #expect(classify(["agy", "--model", "models", "--conversation", "abc-2"])?.conversationID == "abc-2")
    #expect(classify(["agy", "-c"]) != nil)
    #expect(classify(["agy", "--continue"]) != nil)
    #expect(classify(["agy", "-i", "help"]) != nil)
    #expect(classify(["agy", "--prompt-interactive", "mcp"]) != nil)
    #expect(classify(["agy", "--agent", "mcp"]) != nil)
    #expect(classify(["agy", "--effort", "help"]) != nil)
    #expect(classify(["agy", "--mode", "models"]) != nil)
    #expect(classify(["agy", "--project", "update"]) != nil)
    #expect(classify(["agy", "--log-file", "install"]) != nil)

    for nonSession in [
      ["/Users/u/.gemini/bin/agy", "--hub", "--hub-port=1234", "--app_data_dir=antigravity"],
      ["agy", "--hub=true"],
      ["agy", "-p", "hi"],
      ["agy", "--print", "hi"],
      ["agy", "--prompt=hi"],
      ["agy", "-h"],
      ["agy", "--help"],
      ["agy", "-v"],
      ["agy", "--version"],
      ["agy", "acp"],
      ["agy", "agent"],
      ["agy", "agents"],
      ["agy", "changelog"],
      ["agy", "help"],
      ["agy", "install"],
      ["agy", "mcp"],
      ["agy", "mic-serve"],
      ["agy", "models"],
      ["agy", "plugin", "validate"],
      ["agy", "plugins"],
      ["agy", "remote-control"],
      ["agy", "update"],
    ] {
      #expect(classify(nonSession) == nil, "should exclude \(nonSession)")
    }
  }

  @Test @MainActor func reconcileBackfillsTerminalResetsEndedAndMergesDuplicates() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let pid = getpid()
    let store = SessionStore()
    let base = Date().addingTimeInterval(-30)

    // Pre-reset AgyContext snapshot (modified before reset) must not be re-adopted after reset.
    let staleStatus = #"{"conversation_id":"conv-stale-ctx","context_window":{"total_input_tokens":100,"context_window_size":1000}}"#
    try AgyContext.record(Data(staleStatus.utf8), home: home, pid: pid)
    let ctxURL = home.appendingPathComponent(".session-monitor/agy-context/\(pid).json")
    try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(5)], ofItemAtPath: ctxURL.path)

    // Hook arrived before process scan without tty/tmuxPane; reconcile must backfill both.
    try store.apply(AgentEvent(
      kind: .agy, sessionId: "conv-1", agentPid: pid, cwd: "/work/app", at: base,
      type: .promptSubmitted))
    #expect(store.sessions.first?.terminal.tmuxPane == nil)

    let process = AgyProcess(pid: pid, tty: "/dev/ttys009", cwd: "/work/app", startTime: base, conversationID: "conv-old")
    let source = AgySource(
      home: home,
      discover: { [process] },
      lookupPane: { tty in tty == "/dev/ttys009" ? "%7" : nil },
      capturePane: { _ in "" })

    try await source.reconcile(store: store)
    var row = try #require(store.sessions.first)
    #expect(row.state == .working && row.source == .hooks)
    #expect(row.terminal.tty == "/dev/ttys009" && row.terminal.tmuxPane == "%7")
    #expect(TmuxRemote.canSend(row))

    // If a row is marked ended while the TUI PID is still alive, reconcile resets it to idle
    // with a pending id and preserves terminal facts without re-adopting the old conversation id
    // or pre-reset AgyContext snapshot on subsequent reconcile ticks.
    try store.apply(AgentEvent(
      kind: .agy, sessionId: "conv-1", agentPid: pid, at: base.addingTimeInterval(1),
      type: .sessionEnd(reason: nil)))
    #expect(store.sessions.first?.state == .ended)
    try await source.reconcile(store: store)
    try await source.reconcile(store: store)  // Tick 2: still pending, never re-adopts conv-old or conv-stale-ctx
    row = try #require(store.sessions.first)
    #expect(row.state == .idle && row.endedAt == nil)
    #expect(row.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix))
    #expect(row.terminal.tmuxPane == "%7" && row.terminal.tty == "/dev/ttys009")

    // A pid-less hook arrives before the pending row adopts the new conversation id, creating a
    // duplicate sid row; once a fresh AgyContext written AFTER reset appears, reconcile adopts
    // it and merges the duplicate into the pid row.
    try store.apply(AgentEvent(
      kind: .agy, sessionId: "conv-fresh", agentPid: nil, cwd: "/work/app",
      at: Date().addingTimeInterval(10), type: .promptSubmitted))
    #expect(store.sessions.count == 2)

    let freshStatus = #"{"conversation_id":"conv-fresh","context_window":{"total_input_tokens":200,"context_window_size":1000}}"#
    try AgyContext.record(Data(freshStatus.utf8), home: home, pid: pid)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: ctxURL.path)
    try await source.reconcile(store: store)
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.id == "agy:\(pid)")
    #expect(store.sessions.first?.currentSessionId == "conv-fresh")
    #expect(store.sessions.first?.state == .working)
    #expect(store.sessions.first?.terminal.tmuxPane == "%7")
  }

  @Test @MainActor func quietTmuxPaneDetectsPermissionApprovalAndIdleAfterEscOrDeny() async throws {
    let permissionScreen = """
      Command
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Requesting permission for:
         echo PERM_STRICT_OK
      Run this command?
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
      esc to cancel                                            auto · Orchestrator · Gemini 4 Neon · xhigh
      """
    let askQuestionScreen = """
      ? Tea or Coffee?
      Question
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Question 1/1: Tea or Coffee?
      > 1. Tea
        2. Coffee
        3. Write-in...
        ↑/↓ Navigate · enter Select · esc Skip
      esc to cancel                                            auto · Orchestrator · Gemini 4 Neon · xhigh
      """
    let workingScreen = """
      ● Ran (sleep 3 && echo LIVE_TOOL_OK)
      ⣷  Running command...
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      esc to cancel                                            auto · Orchestrator · Gemini 4 Neon · xhigh
      """
    let idleAfterEscScreen = """
        ⎿  Interrupted · What should Antigravity CLI do instead?
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      ? for shortcuts                                          auto · Orchestrator · Gemini 4 Neon · xhigh
      ctx 15k/1M (1.5%)
      """

    #expect(AgySource.classifyQuietPane(permissionScreen) == .needsPermission(message: "echo PERM_STRICT_OK"))
    #expect(AgySource.classifyQuietPane(askQuestionScreen) == nil)
    #expect(AgySource.classifyQuietPane(workingScreen) == .working)
    #expect(AgySource.classifyQuietPane(idleAfterEscScreen) == .idle)

    // End-to-end quiet reconcile: working (>8s) -> needsPermission -> immediately approved (no 8s wait) -> working.
    let pid = getpid()
    let store = SessionStore()
    let old = Date().addingTimeInterval(-20)
    try store.apply(AgentEvent(
      kind: .agy, sessionId: "conv-quiet", agentPid: pid, cwd: "/work/app", at: old,
      type: .toolStart(name: "run_command", summary: "echo PERM_STRICT_OK"),
      terminal: TerminalInfo(tmuxPane: "%5", tty: "/dev/ttys005")))
    #expect(store.sessions.first?.state == .working)

    let permSource = AgySource(discover: { [] }, capturePane: { _ in permissionScreen })
    try await permSource.reconcile(store: store)
    var row = try #require(store.sessions.first)
    #expect(row.state == .needsPermission && row.attentionMessage == "echo PERM_STRICT_OK")
    #expect(row.currentTool == "run_command: echo PERM_STRICT_OK")

    // Approving clears the menu into `esc to cancel`: next reconcile tick immediately recovers
    // .needsPermission -> .working (clearing attentionMessage while preserving currentTool).
    let approvedSource = AgySource(discover: { [] }, capturePane: { _ in workingScreen })
    try await approvedSource.reconcile(store: store)
    row = try #require(store.sessions.first)
    #expect(row.state == .working && row.attentionMessage == nil)
    #expect(row.currentTool == "run_command: echo PERM_STRICT_OK")

    // Fresh (<8s) working session is not touched even if capture would return idle.
    let idleSource = AgySource(discover: { [] }, capturePane: { _ in idleAfterEscScreen })
    try await idleSource.reconcile(store: store)
    #expect(store.sessions.first?.state == .working)

    // Denying permission immediately transitions .needsPermission -> .idle on the next tick (no 8s wait).
    let denyStore = SessionStore()
    try denyStore.apply(AgentEvent(
      kind: .agy, sessionId: "conv-deny", agentPid: pid, cwd: "/work/app", at: Date(),
      type: .permissionRequested(tool: nil, message: "echo PERM_STRICT_OK"),
      terminal: TerminalInfo(tmuxPane: "%5", tty: "/dev/ttys005")))
    try await idleSource.reconcile(store: denyStore)
    row = try #require(denyStore.sessions.first)
    #expect(row.state == .idle && row.attentionMessage == nil && !row.unread)

    // Quiet (>=8s) .needsInput (e.g. Esc-canceled ask_question) also recovers to .idle.
    let inputStore = SessionStore()
    try inputStore.apply(AgentEvent(
      kind: .agy, sessionId: "conv-input", agentPid: pid, cwd: "/work/app", at: old,
      type: .toolStart(name: "ask_question", summary: "Tea or Coffee?"),
      terminal: TerminalInfo(tmuxPane: "%5", tty: "/dev/ttys005")))
    #expect(inputStore.sessions.first?.state == .needsInput)
    // Still showing ask_question menu: stays .needsInput.
    try await AgySource(discover: { [] }, capturePane: { _ in askQuestionScreen }).reconcile(store: inputStore)
    #expect(inputStore.sessions.first?.state == .needsInput)
    // After Esc to idle: returns to .idle.
    try await idleSource.reconcile(store: inputStore)
    row = try #require(inputStore.sessions.first)
    #expect(row.state == .idle && row.attentionMessage == nil && !row.unread)
  }

  @Test func agyQuotaParsesRealPayloadAndFormatsResetTimes() throws {
    let now = Date(timeIntervalSince1970: 1_795_576_200)  // 2026-11-25T03:10:00Z
    let payload = #"""
    {
      "plan_tier": "Pro",
      "quota": {
        "3p-5h": { "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z", "reset_in_seconds": 0 },
        "3p-weekly": { "remaining_fraction": 1.2, "reset_time": "1970-01-01T00:00:00Z", "reset_in_seconds": 0 },
        "gemini-5h": { "remaining_fraction": 0.9058288, "reset_time": "2026-11-25T06:02:15Z", "reset_in_seconds": 10118 },
        "gemini-weekly": { "remaining_fraction": 0.68006825, "reset_time": "2026-12-01T01:20:17Z", "reset_in_seconds": 511600 },
        "hidden-bucket": { "remaining_fraction": 0.5, "disabled": true },
        "credits": { "remaining_amount": 42, "reset_in_seconds": 90 }
      }
    }
    """#
    let snapshot = try #require(try AgyQuota.parse(Data(payload.utf8), now: now))
    #expect(snapshot.planTier == "Pro")
    #expect(snapshot.buckets.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "credits", "hidden-bucket"])
    #expect(snapshot.activeBuckets.count == 5)

    let g5h = snapshot.buckets[0]
    #expect(g5h.remainingPercent == 91)
    #expect(g5h.valueText == "91%")
    #expect(g5h.resetAt != nil)
    #expect(g5h.compactResetText(now: now) == "2h52m")

    let gWeekly = snapshot.buckets[1]
    #expect(gWeekly.remainingPercent == 68)
    #expect(gWeekly.compactResetText(now: now) == "5d22h")

    let p35h = snapshot.buckets[2]
    #expect(p35h.resetAt == nil)
    #expect(p35h.resetText(now: now) == "未消耗")
    #expect(p35h.compactResetText(now: now).isEmpty)

    let p3Weekly = snapshot.buckets[3]
    #expect(p3Weekly.remainingFraction == 1.0)

    let credits = snapshot.buckets[4]
    #expect(credits.valueText == "42")
    #expect(credits.resetAt == now.addingTimeInterval(90))
    #expect(credits.compactResetText(now: now) == "1m")

    let utc = TimeZone(secondsFromGMT: 0)!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    #expect(g5h.resetText(now: now, calendar: cal, timeZone: utc) == "2h 52m · 06:02")
    #expect(gWeekly.resetText(now: now, calendar: cal, timeZone: utc) == "5d 22h · 12/01 01:20")
    #expect(credits.resetText(now: now, calendar: cal, timeZone: utc) == "1m · 03:11")
    #expect(g5h.resetText(now: now.addingTimeInterval(15_000), calendar: cal, timeZone: utc) == "已重置")
    #expect(AgyQuotaBucket(id: "x", remainingFraction: 0.5, resetAt: now.addingTimeInterval(30)).resetText(now: now) == "<1m")
  }

  @Test func agyQuotaRecordRoundTripAndDeduplication() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let t0 = Date(timeIntervalSince1970: 1_795_576_200)
    let payload = #"{"plan_tier":"Pro","quota":{"gemini-5h":{"remaining_fraction":0.8,"reset_time":"2026-11-25T06:00:00Z"}}}"#
    try AgyQuota.record(Data(payload.utf8), home: home, now: t0)
    let loaded = try #require(AgyQuota.load(home: home))
    #expect(loaded.planTier == "Pro")
    #expect(loaded.buckets.first?.remainingPercent == 80)

    // Within 30s with identical buckets: deduped (updatedAt stays t0).
    try AgyQuota.record(Data(payload.utf8), home: home, now: t0.addingTimeInterval(10))
    #expect(AgyQuota.load(home: home)?.updatedAt == t0)

    // After 30s: updated.
    let t2 = t0.addingTimeInterval(35)
    try AgyQuota.record(Data(payload.utf8), home: home, now: t2)
    #expect(AgyQuota.load(home: home)?.updatedAt == t2)
  }

  @Test func agyDiscoveryExcludesQuotaProbeAndFindsLocalExecutable() throws {
    #expect(
      AgyDiscovery.classify(
        pid: 99, tty: "/dev/ttys010",
        arguments: ["agy", "--settings", "/tmp/agy-quota-probe-123/agy-quota-probe-settings.json"],
        cwd: "/tmp", startTime: nil) == nil)

    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let bin = home.appendingPathComponent(".local/bin/agy")
    try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: bin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    #expect(AgyQuotaProbe.findExecutable(home: home, environment: [:]) == bin.path)
  }
}
