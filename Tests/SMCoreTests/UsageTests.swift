import Foundation
import SMProtocol
import Testing

@testable import SMCore

@Suite struct UsageTests {
  func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sm-usage-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func claudeLine(id: String, output: Int, at: String = "2026-10-26T02:00:00.000Z", sidechain: Bool = false, model: String = "claude-opus-5-5") -> String {
    #"{"type":"assistant","isSidechain":\#(sidechain),"cwd":"/work/demo","timestamp":"\#(at)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":2,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"output_tokens":\#(output),"output_tokens_details":{"thinking_tokens":10}}}}"#
  }

  func codexLine(
    input: Int, cached: Int, output: Int, last: (input: Int, output: Int)? = nil, at: String = "2026-10-26T03:00:00.000Z"
  ) -> String {
    // By default the first request of the thread: last equals total.
    let lastUsage =
      last.map { #""input_tokens":\#($0.input),"output_tokens":\#($0.output)"# }
      ?? #""input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":5"#
    return #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":5,"total_tokens":\#(input + output)},"last_token_usage":{\#(lastUsage),"total_tokens":4000},"model_context_window":258400}}}"#
  }

  /// Real shapes (Claude Code 2.1.3xx): a message is written once per content block with the
  /// same id; the last one may report more output.
  @Test func claudeMessagesCountOnceAndFollowTheContext() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s.jsonl")
    try ([claudeLine(id: "m1", output: 50), claudeLine(id: "m1", output: 50), claudeLine(id: "m1", output: 80),
      #"{"type":"user","message":{"content":"usage"}}"#, ""].joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
    var reader = UsageReader(kind: .claude)
    var total = TokenUsage()
    #expect(try reader.read(file) { total += $0.usage })
    #expect(total == TokenUsage(input: 2, cacheRead: 1000, cacheWrite: 300, output: 80, reasoning: 10))
    #expect(reader.contextTokens == 1302 && reader.contextWindow == 1_000_000 && reader.model == "claude-opus-5-5")
    // Appended lines only; a half-written line waits.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((claudeLine(id: "m2", output: 7, sidechain: true) + "\n" + #"{"type":"assist"#).utf8))
    try handle.close()
    #expect(try reader.read(file) { total += $0.usage })
    #expect(total.output == 87)
    #expect(reader.contextTokens == 1302)  // a subagent's request is not this conversation's context
    #expect(UsageReader.claudeContextWindow(model: "claude-sonnet-4-5", largest: 150_000) == 200_000)
    #expect(UsageReader.claudeContextWindow(model: "claude-sonnet-4-5", largest: 250_000) == 1_000_000)
  }

  /// Codex reports cumulative totals; input includes the cached part.
  @Test func codexCountsDifferences() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("rollout.jsonl")
    try ([
      #"{"type":"session_meta","payload":{"cwd":"/work/app"}}"#,
      #"{"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/work/app"}}"#,
      codexLine(input: 1000, cached: 0, output: 10), codexLine(input: 1000, cached: 0, output: 10),
      codexLine(input: 3000, cached: 1500, output: 30), "",
    ].joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
    var reader = UsageReader(kind: .codex)
    var parts: [UsageContribution] = []
    #expect(try reader.read(file) { parts.append($0) })
    #expect(parts.count == 2)
    #expect(parts.reduce(TokenUsage()) { $0 + $1.usage } == TokenUsage(input: 1500, cacheRead: 1500, output: 30, reasoning: 5))
    #expect(parts.allSatisfy { $0.model == "gpt-5.5" && $0.cwd == "/work/app" })
    #expect(reader.contextTokens == 4000 && reader.contextWindow == 258_400)
  }

  /// Real case (2026-10-26): a subagent's rollout starts from its parent's cumulative total
  /// (4.95M) before its own first turn_context; only its own requests count, under its model.
  @Test func forkedCodexThreadsCountOnlyTheirOwnRequests() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("rollout.jsonl")
    try ([
      #"{"type":"session_meta","payload":{"cwd":"/work/app","parent_thread_id":"p1"}}"#,
      codexLine(input: 4_900_000, cached: 0, output: 50_000, last: (30_000, 600)),
      #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna","cwd":"/work/app"}}"#,
      codexLine(input: 4_930_000, cached: 0, output: 50_400), "",
    ].joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
    var reader = UsageReader(kind: .codex)
    var parts: [UsageContribution] = []
    #expect(try reader.read(file) { parts.append($0) })
    #expect(parts.map(\.model) == ["gpt-5.6-luna", "gpt-5.6-luna"])
    #expect(parts.reduce(TokenUsage()) { $0 + $1.usage }.total == 30_600 + 30_400)
  }

  /// Sums all local sessions by day; a resumed Claude session's copied messages count once, and a
  /// moved Codex rollout is not counted again.
  @Test func ledgerSumsEverySessionOnce() throws {
    let home = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let projects = home.appendingPathComponent(".claude/projects/-work-demo")
    let codex = home.appendingPathComponent(".codex/sessions/2026/10/26")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try (claudeLine(id: "m1", output: 50, at: "2026-10-25T10:00:00.000Z") + "\n").write(
      to: projects.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    try ([claudeLine(id: "m1", output: 50, at: "2026-10-25T10:00:00.000Z"), claudeLine(id: "m2", output: 20)].joined(separator: "\n") + "\n")
      .write(to: projects.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
    try ([#"{"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/work/app"}}"#, codexLine(input: 1000, cached: 200, output: 10)]
      .joined(separator: "\n") + "\n").write(to: codex.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
    let state = home.appendingPathComponent("state")
    let ledger = UsageLedger(directory: state, home: home)
    #expect(try ledger.refresh())
    #expect(try !ledger.refresh())
    var rows = ledger.rows()
    let claude = rows.filter { $0.agent == "claude" }
    #expect(UsageReport.total(claude).output == 70)
    #expect(Set(claude.map(\.project)) == ["demo"])
    #expect(UsageReport.total(rows.filter { $0.agent == "codex" }) == TokenUsage(input: 800, cacheRead: 200, output: 10, reasoning: 5))

    // Archived by Codex: same file name elsewhere, nothing new.
    let archive = home.appendingPathComponent(".codex/archived_sessions")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: codex.appendingPathComponent("rollout-1.jsonl"), to: archive.appendingPathComponent("rollout-1.jsonl"))
    let reopened = UsageLedger(directory: state, home: home)
    try reopened.refresh()
    rows = reopened.rows()
    #expect(UsageReport.total(rows.filter { $0.agent == "codex" }).output == 10)
    // History stays after the agent deletes old transcripts.
    try FileManager.default.removeItem(at: projects.appendingPathComponent("a.jsonl"))
    try reopened.refresh()
    #expect(UsageReport.total(reopened.rows().filter { $0.agent == "claude" }).output == 70)
  }

  @Test func agyUsageTracksAppendedTurnsAndCountsOnlyFullTranscripts() async throws {
    let home = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let brain = home.appendingPathComponent(".gemini/antigravity-cli/brain")
    let a = brain.appendingPathComponent("first/.system_generated/logs")
    let b = brain.appendingPathComponent("second/.system_generated/logs")
    try FileManager.default.createDirectory(at: a.appendingPathComponent("chunks"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let full = a.appendingPathComponent("transcript_full.jsonl")
    let first = """
      {"type":"USER_INPUT","step_index":0,"status":"DONE","created_at":"2026-11-16T11:49:00Z"}
      {"type":"PLANNER_RESPONSE","step_index":1,"status":"DONE","created_at":"2026-11-16T11:49:01Z","model":"gemini-4-hydrogen-medium","input_tokens":3502,"cache_read_tokens":8905,"output_tokens":292}

      """
    let resumed = """
      {"type":"PLANNER_RESPONSE","step_index":1,"status":"DONE","created_at":"2026-11-19T08:10:12Z","model":"gemini-4-hydrogen-high","input_tokens":10593,"cache_read_tokens":0,"output_tokens":70}

      """
    for url in [full, a.appendingPathComponent("transcript.jsonl"), a.appendingPathComponent("chunks/part.jsonl")] {
      try first.write(to: url, atomically: true, encoding: .utf8)
    }
    // Both real conversations have the same transcript file name.
    try first.write(to: b.appendingPathComponent("transcript_full.jsonl"), atomically: true, encoding: .utf8)

    let hook = HookEnvelope(source: "agy", agentPid: 4242, payload: .object([
      "hookEventName": .string("SessionStart"), "conversationId": .string("first"),
      "transcriptPath": .string(full.path),
    ]))
    let session = Session(event: try AgySource().normalize(hook))
    let tracker = UsageTracker(home: home)
    let initial = TokenUsage(input: 3502, cacheRead: 8905, output: 292)
    #expect(await tracker.update([session])[session.id]?.total == initial)

    let state = home.appendingPathComponent("state")
    let ledger = UsageLedger(directory: state, home: home)
    #expect(try ledger.refresh())
    let initialRow = try #require(ledger.rows().first)
    #expect(ledger.rows().count == 1)
    #expect(initialRow.agent == "agy")
    #expect(initialRow.model == "gemini-4-hydrogen-medium")
    #expect(initialRow.usage == initial + initial)

    let handle = try FileHandle(forWritingTo: full)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(resumed.utf8))
    let next = TokenUsage(input: 10593, output: 70)
    #expect(await tracker.update([session])[session.id] == SessionUsage(
      total: initial + next, model: "gemini-4-hydrogen-high", contextTokens: nil, contextWindow: nil))
    #expect(await tracker.update([session])[session.id]?.total == initial + next)

    let reopened = UsageLedger(directory: state, home: home)
    #expect(try reopened.refresh())
    #expect(try !reopened.refresh())
    let rows = reopened.rows()
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.agent)) == ["agy"])
    let date = try #require(ISO8601DateFormatter().date(from: "2026-11-19T08:10:12Z"))
    #expect(rows.first { $0.day == UsageReport.dayKey(date) && $0.model == "gemini-4-hydrogen-high" }?.usage == next)
    #expect(UsageReport.total(rows) == initial + initial + next)
  }

  @Test func formatting() {
    #expect(UsageReport.format(950) == "950")
    #expect(UsageReport.format(24_600) == "24.6k")
    #expect(UsageReport.format(1_840_000) == "1.8M")
    #expect(UsageReport.format(2_310_000_000) == "2.31B")
    #expect(UsageReport.percent(TokenUsage(input: 100, cacheRead: 700, cacheWrite: 200, output: 50).cacheHitRate) == "70.0%")
    #expect(UsageReport.percent(TokenUsage(output: 50).cacheHitRate) == "—")
  }

  /// Opt-in timing against this Mac's real logs: SM_USAGE_REAL=1 swift test --filter realLogs
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SM_USAGE_REAL"] == "1")) func realLogs() throws {
    let state = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: state) }
    let ledger = UsageLedger(directory: state)
    var start = Date()
    try ledger.refresh()
    print("first scan \(Date().timeIntervalSince(start))s")
    start = Date()
    try ledger.refresh()
    print("second scan \(Date().timeIntervalSince(start))s")
    let rows = ledger.rows()
    for (day, usage) in UsageReport.ranking(rows, by: \.day).sorted(by: { $0.name > $1.name }).prefix(5) {
      print(day, UsageReport.format(usage.total), UsageReport.breakdown(usage))
    }
    for (model, usage) in UsageReport.ranking(rows, by: \.model) { print(model, UsageReport.format(usage.total)) }
    let size = try FileManager.default.attributesOfItem(atPath: state.appendingPathComponent("usage/ledger.json").path)[.size] as? Int
    print("cache bytes", size ?? -1)
  }
}
