import Foundation

/// Token counts, the same way for Claude and Codex: `input` is input not read from or written to
/// the cache, `output` includes reasoning/thinking. `total` matches Codex's `total_tokens`
/// (all input plus output).
public struct TokenUsage: Codable, Sendable, Equatable, Hashable {
  public var input = 0
  public var cacheRead = 0
  public var cacheWrite = 0
  public var output = 0
  /// Part of `output`.
  public var reasoning = 0

  public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0) {
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
    self.reasoning = reasoning
  }

  public var total: Int { input + cacheRead + cacheWrite + output }
  public var isZero: Bool { self == TokenUsage() }

  public static func + (a: Self, b: Self) -> Self {
    Self(
      input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
      output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
  }
  public static func - (a: Self, b: Self) -> Self {
    Self(
      input: a.input - b.input, cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite,
      output: a.output - b.output, reasoning: a.reasoning - b.reasoning)
  }
  public static func += (a: inout Self, b: Self) { a = a + b }
}

/// One session's current thread (after /clear or /new it starts again).
public struct SessionUsage: Codable, Sendable, Equatable {
  public var total: TokenUsage
  public var model: String?
  /// Input of the latest request: what the conversation occupies now.
  public var contextTokens: Int?
  public var contextWindow: Int?

  public init(total: TokenUsage, model: String?, contextTokens: Int?, contextWindow: Int?) {
    self.total = total
    self.model = model
    self.contextTokens = contextTokens
    self.contextWindow = contextWindow
  }

  public var contextFraction: Double? {
    guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
    return min(1, Double(contextTokens) / Double(contextWindow))
  }

  /// Context this full gets a warning color: auto-compaction is near.
  public static let contextWarning = 0.8
}

/// Usage of one day, agent, model and project, summed over all local sessions.
public struct UsageRow: Codable, Sendable, Equatable {
  /// Local calendar day, `yyyy-MM-dd`.
  public var day: String
  /// `claude` or `codex`.
  public var agent: String
  public var model: String
  public var project: String
  public var usage: TokenUsage

  public init(day: String, agent: String, model: String, project: String, usage: TokenUsage) {
    self.day = day
    self.agent = agent
    self.model = model
    self.project = project
    self.usage = usage
  }
}

/// Aggregations over usage rows, shared by the Mac window and the phone page.
public enum UsageReport {
  public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The day keys of the last `days` days, oldest first, ending today.
  public static func lastDays(_ days: Int, now: Date = Date(), calendar: Calendar = .current) -> [String] {
    (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map {
      dayKey($0, calendar: calendar)
    }
  }

  public static func total(_ rows: [UsageRow]) -> TokenUsage { rows.reduce(TokenUsage()) { $0 + $1.usage } }

  /// Totals grouped by `key`, largest first.
  public static func ranking(_ rows: [UsageRow], by key: (UsageRow) -> String) -> [(name: String, usage: TokenUsage)] {
    var groups: [String: TokenUsage] = [:]
    for row in rows { groups[key(row), default: TokenUsage()] += row.usage }
    return groups.map { (name: $0.key, usage: $0.value) }.sorted {
      $0.usage.total != $1.usage.total ? $0.usage.total > $1.usage.total : $0.name < $1.name
    }
  }

  /// 950, 24.6k, 1.8M, 2.31B.
  public static func format(_ tokens: Int) -> String {
    let value = Double(tokens)
    switch abs(value) {
    case ..<1_000: return "\(tokens)"
    case ..<100_000: return String(format: "%.1fk", value / 1_000)
    case ..<1_000_000: return String(format: "%.0fk", value / 1_000)
    case ..<100_000_000: return String(format: "%.1fM", value / 1_000_000)
    case ..<1_000_000_000: return String(format: "%.0fM", value / 1_000_000)
    default: return String(format: "%.2fB", value / 1_000_000_000)
    }
  }

  /// "输入 1.2M · 缓存读 21.0M · 缓存写 1.9M · 输出 0.5M（思考 0.1M）"
  public static func breakdown(_ usage: TokenUsage) -> String {
    var text = "输入 \(format(usage.input)) · 缓存读 \(format(usage.cacheRead)) · 缓存写 \(format(usage.cacheWrite)) · 输出 \(format(usage.output))"
    if usage.reasoning > 0 { text += "（思考 \(format(usage.reasoning))）" }
    return text
  }
}
