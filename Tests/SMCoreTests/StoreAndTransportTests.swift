import Darwin
import Foundation
import Testing

@testable import SMCore

@Suite struct StoreAndTransportTests {
  @Test @MainActor func reconcilerMetadataLivenessAndExpiry() throws {
    let store = SessionStore()
    let now = Date(timeIntervalSince1970: 1000)
    let event = AgentEvent(sessionId: "id", agentPid: 42, at: now, type: .promptSubmitted)
    let file = try ClaudeSessionFile.parse(
      Data(
        #"{"pid":42,"sessionId":"id","name":"Custom","status":"idle","statusUpdatedAt":2000000,"tmux":"s:@4.%9"}"#
          .utf8))
    store.reconcile(files: [file], liveness: [42: true], now: now)
    #expect(store.sessions.first?.source == .sessionFileOnly)
    #expect(store.lastError == nil)
    try store.apply(event)
    store.reconcile(files: [file], liveness: [42: true], now: now.addingTimeInterval(10))
    #expect(store.sessions.first?.state == .done)
    #expect(store.sessions.first?.displayName == "Custom")
    #expect(store.sessions.first?.terminal.tmuxPane == "%9")
    store.reconcile(files: [], liveness: [42: false], now: now.addingTimeInterval(12))
    #expect(store.sessions.first?.state == .ended)
    store.reconcile(files: [], liveness: [:], now: now.addingTimeInterval(42))
    #expect(store.sessions.isEmpty)
  }

  @Test @MainActor func unreadAndStaleEnrichment() throws {
    let store = SessionStore()
    try store.apply(AgentEvent(sessionId: "one", agentPid: 42, type: .stop))
    store.markAllRead()
    #expect(store.sessions.first?.unread == false)
    try store.apply(
      AgentEvent(sessionId: "two", agentPid: 42, type: .sessionStart(reason: "clear")))
    store.applyEnrichment(SessionEnrichment(title: "stale"), id: "claude:42", sessionID: "one")
    #expect(store.sessions.first?.title == nil)
  }

  @Test @MainActor func noPIDExpiryAndWorkingRetention() throws {
    let store = SessionStore()
    let now = Date(timeIntervalSince1970: 1000)
    try store.apply(AgentEvent(sessionId: "idle", agentPid: nil, at: now, type: .stop))
    try store.apply(
      AgentEvent(sessionId: "working", agentPid: nil, at: now, type: .promptSubmitted))
    store.reconcile(files: [], liveness: [:], now: now.addingTimeInterval(1801))
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.state == .working)
  }

  @Test @MainActor func exitingHookMissingPIDUsesOnlyUniqueKnownSession() throws {
    let store = SessionStore()
    try store.apply(AgentEvent(sessionId: "same", agentPid: 42, type: .sessionStart(reason: nil)))
    try store.apply(AgentEvent(sessionId: "same", agentPid: nil, type: .sessionEnd(reason: "exit")))
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.id == "claude:42")
    #expect(store.sessions.first?.state == .ended)
    #expect(!store.drainDiagnostics().isEmpty)
    try store.apply(AgentEvent(sessionId: "same", agentPid: 43, type: .sessionStart(reason: nil)))
    #expect(throws: MonitorError.self) {
      try store.apply(AgentEvent(sessionId: "same", agentPid: nil, type: .stop))
    }
  }

  @Test @MainActor func latePIDMergesEarlierSessionIDRow() throws {
    let store = SessionStore()
    try store.apply(AgentEvent(sessionId: "same", agentPid: nil, type: .stop))
    try store.apply(AgentEvent(sessionId: "same", agentPid: 42, type: .promptSubmitted))
    #expect(store.sessions.count == 1)
    #expect(store.sessions.first?.id == "claude:42")
  }

  @Test @MainActor func reconciliationBusyAndHookPrecedence() throws {
    let store = SessionStore()
    let now = Date(timeIntervalSince1970: 1000)
    let busy = try ClaudeSessionFile.parse(
      Data(#"{"pid":42,"sessionId":"id","status":"busy","statusUpdatedAt":1005000}"#.utf8))
    try store.apply(AgentEvent(sessionId: "id", agentPid: 42, at: now, type: .stop))
    store.reconcile(files: [busy], liveness: [42: true], now: now.addingTimeInterval(6))
    #expect(store.sessions.first?.state == .working)
    #expect(!store.drainDiagnostics().isEmpty)
    try store.apply(
      AgentEvent(
        sessionId: "id", agentPid: 42, at: now.addingTimeInterval(7),
        type: .permissionRequested(tool: "Bash", message: nil)))
    let idle = try ClaudeSessionFile.parse(
      Data(#"{"pid":42,"sessionId":"id","status":"idle","statusUpdatedAt":1020000}"#.utf8))
    store.reconcile(files: [idle], liveness: [42: true], now: now.addingTimeInterval(21))
    #expect(store.sessions.first?.state == .needsPermission)
  }

  @Test func absentSocketReportsError() {
    #expect(throws: MonitorError.self) {
      try SocketClient.send(Data("{}".utf8), to: "/tmp/\(UUID().uuidString).sock")
    }
  }

  @Test func actualSocketRoundTripAndPermissions() async throws {
    let dir = URL(fileURLWithPath: "/tmp/sm-\(UUID().uuidString.prefix(8))")
    let server = SocketServer(directory: dir)
    let pair = AsyncStream<Result<Data, MonitorError>>.makeStream()
    try server.start { pair.continuation.yield($0) }
    defer {
      server.stop()
      pair.continuation.finish()
      if FileManager.default.fileExists(atPath: dir.path) {
        do { try FileManager.default.removeItem(at: dir) } catch {
          Issue.record("socket fixture cleanup failed: \(error)")
        }
      }
    }
    let second = SocketServer(directory: dir)
    #expect(throws: MonitorError.self) { try second.start { _ in } }
    let attributes = try FileManager.default.attributesOfItem(atPath: server.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try SocketClient.send(Data("{\"test\":true}".utf8), to: server.path)
    var iterator = pair.stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(try received?.get() == Data("{\"test\":true}".utf8))
    server.stop()
    for _ in 0..<100 {
      if !FileManager.default.fileExists(atPath: server.path) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!FileManager.default.fileExists(atPath: server.path))
    try FileManager.default.removeItem(at: dir)
  }

  @Test func processTimeoutAndExitFailureAreVisible() async throws {
    let result = try await ProcessRunner.run("/usr/bin/printf", arguments: ["hello"])
    #expect(result.stdout == "hello")
    await #expect(throws: MonitorError.self) {
      try await ProcessRunner.run("/usr/bin/false", arguments: [])
    }
    await #expect(throws: MonitorError.self) {
      try await ProcessRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.05)
    }
  }
}
