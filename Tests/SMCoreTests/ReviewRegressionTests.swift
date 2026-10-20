import Foundation
import Testing

@testable import SMCore

@Suite struct ReviewRegressionTests {
  private func timeline(_ name: String) throws -> [HookEnvelope] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent("docs/payload-samples/timelines/" + name + ".jsonl"))
    return try data.split(separator: 10).map {
      try JSONDecoder().decode(HookEnvelope.self, from: Data($0))
    }
  }

  @Test @MainActor func entireRealToolsTimelinePreservesDone() throws {
    let store = SessionStore()
    let events = try timeline("tools-permissions")
    #expect(events.count == 29)
    var checkpoints = 0
    for envelope in events {
      let normalized = try ClaudeSource().normalize(envelope)
      #expect(normalized.agentId == envelope.payload["agent_id"]?.string)
      let session = try store.apply(normalized)
      let seconds = Int(envelope.receivedAt / 1000) % 86400
      if [6 * 3600 + 4 * 60 + 37, 6 * 3600 + 7 * 60 + 22, 6 * 3600 + 8 * 60 + 15].contains(seconds)
      {
        #expect(session.state == .done)
        #expect(session.unread)
        checkpoints += 1
      }
      #expect(store.sessions.count == 1)
    }
    #expect(checkpoints == 3)
  }

  @Test @MainActor func entireRealClearCompactTimelineKeepsRowAndCompletion() throws {
    let store = SessionStore()
    var firstID: String?
    var oldSID: String?
    var clearChecked = false
    var compactChecked = false
    for envelope in try timeline("startup-clear-exit") {
      let event = try ClaudeSource().normalize(envelope)
      let session = try store.apply(event)
      if firstID == nil {
        firstID = session.id
        oldSID = session.currentSessionId
      }
      #expect(session.id == firstID)
      #expect(store.sessions.count == 1)
      if event.type == .sessionStart(reason: "clear") {
        #expect(session.currentSessionId != oldSID)
        #expect(session.state == .idle)
        clearChecked = true
      }
      if event.type == .sessionStart(reason: "compact") {
        #expect(session.state == .idle || (session.state == .done && session.unread))
        compactChecked = true
      }
    }
    #expect(clearChecked && compactChecked)
  }

  @Test @MainActor func realPermissionEventsReorderedForFastApproval() throws {
    let events = try timeline("tools-permissions")
    let request = try #require(
      events.first { $0.payload["hook_event_name"]?.string == "PermissionRequest" })
    let notification = try #require(
      events.first { $0.payload["hook_event_name"]?.string == "Notification" })
    var approved = try #require(
      events.first { $0.payload["hook_event_name"]?.string == "PostToolUse" })
    approved.receivedAt = request.receivedAt + 1000
    let store = SessionStore()
    for envelope in [request, approved, notification] {
      try store.apply(ClaudeSource().normalize(envelope))
    }
    #expect(store.sessions.first?.state == .working)
    #expect(store.lastError == nil)
    #expect(
      store.drainDiagnostics().contains {
        $0.level == .info && $0.message.contains("permission_prompt")
      })
  }

  @Test @MainActor func absentTranscriptAndReconstructionAreInformation() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sm-enrich-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try! FileManager.default.removeItem(at: home) }
    let store = SessionStore()
    let file = try ClaudeSessionFile.parse(
      Data(#"{"pid":42,"sessionId":"not-created","status":"idle"}"#.utf8))
    store.reconcile(files: [file], liveness: [42: true], now: Date())
    let session = try #require(store.sessions.first)
    let source = ClaudeSource(home: home)
    for path in [nil, home.appendingPathComponent("missing.jsonl").path] as [String?] {
      var candidate = session
      candidate.transcriptPath = path
      let info = try #require(await source.enrich(candidate))
      #expect(!info.hasTranscript)
      store.applyEnrichment(info, id: session.id, sessionID: session.currentSessionId)
    }
    #expect(store.lastError == nil)
    let diagnostics = store.drainDiagnostics()
    #expect(diagnostics.count == 3)
    #expect(diagnostics.allSatisfy { $0.level == .info })
    store.record(Diagnostic(.warning, "warning probe"))
    #expect(store.lastError == nil)
    store.report(MonitorError.invalid("error probe"), context: "test")
    #expect(store.lastError != nil)
  }

  @Test func diagnosticLevelSurvivesTransport() throws {
    var envelope = HookEnvelope(source: "claude", agentPid: nil, payload: .object([:]))
    envelope.diagnostics = ["ancestor not found"]
    envelope.diagnosticLevel = .info
    let decoded = try JSONDecoder().decode(HookEnvelope.self, from: JSONEncoder().encode(envelope))
    #expect(decoded.diagnosticLevel == .info)
    #expect(decoded.diagnostics == envelope.diagnostics)
  }

  @Test func onlyIncompleteFinalTranscriptLineIsTolerated() throws {
    let good =
      "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"retained\"}]}}\n"
    for tail in ["{\"type\":", "{\"text\":\"partial"] {
      let result = try TranscriptTailReader.parse(Data((good + tail).utf8), dropFirstLine: false)
      #expect(result.snippet == "retained")
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.level == .info)
    }
    for text in [
      good + "{\"a\":nope}", good + "{\"a\":\n", "{\"a\":nope}\n" + good, "{\"a\":\n" + good,
    ] {
      #expect(throws: (any Error).self) {
        try TranscriptTailReader.parse(Data(text.utf8), dropFirstLine: false)
      }
    }
  }
}
