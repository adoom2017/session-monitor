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
    #expect(store.sessions.first?.state == .unknown)

    var states: [SessionState] = []
    for hook in hooks {
      let row = try store.apply(source.normalize(hook))
      states.append(row.state)
      #expect(row.source == .hooks)
      #expect(row.currentSessionId == "agy-sample")
      #expect(row.transcriptPath == hook.payload["transcriptPath"]?.string)
      #expect(row.terminal.tmuxPane == "%3")
      #expect(!TmuxRemote.canSend(row))
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
}
