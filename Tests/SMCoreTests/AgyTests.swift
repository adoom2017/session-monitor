import Foundation
import Testing

@testable import SMCore

@Suite struct AgyTests {
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
      #expect(row.terminal.tmuxPane == "%3")
      #expect(!TmuxRemote.canSend(row))
    }
    #expect(states == [.idle, .working, .done])
    #expect(store.sessions.map(\.id) == ["agy:\(pid)"])
    #expect(store.sessions.first?.unread == true)
    store.reconcile(files: [], liveness: [pid: false], now: time.addingTimeInterval(3))
    #expect(store.sessions.first?.state == .ended)
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
