import Foundation
import SMProtocol

/// Tokens counted from one transcript line (or the correction of an earlier one).
public struct UsageContribution: Sendable, Equatable {
  public var at: Date?
  public var model: String
  public var cwd: String?
  /// Negative parts when a repeated message reports less than first counted.
  public var usage: TokenUsage
  /// Claude's message id, for de-duplicating messages copied into a resumed session's file.
  public var messageId: String?
}

/// Reads token usage from a Claude transcript or a Codex rollout incrementally: each `read` only
/// parses complete lines appended since the previous one. Codable so the ledger can resume.
///
/// - Claude: every assistant line carries `message.usage`; one message is written as several
///   lines (one per content block) with the same id, so each id counts once.
/// - Codex: `token_count` events carry the thread's cumulative usage; the difference to the
///   previous event is what was spent since. A forked thread (subagent) starts from its parent's
///   cumulative total, so a file's first event counts only its own request (`last_token_usage`).
public struct UsageReader: Codable, Sendable, Equatable {
  public let kind: AgentKind
  public private(set) var offset: UInt64 = 0
  public private(set) var model: String?
  public private(set) var cwd: String?
  public private(set) var contextTokens: Int?
  public private(set) var contextWindow: Int?
  private var largestContext = 0
  private var codexTotal: TokenUsage?
  /// Codex usage seen before the first `turn_context` named the model.
  private var unattributed: [Unattributed] = []
  /// Claude messages counted most recently, to fold their repeated lines.
  private var recent: [Recent] = []

  struct Unattributed: Codable, Sendable, Equatable {
    var at: Date?
    var usage: TokenUsage
  }

  struct Recent: Codable, Sendable, Equatable {
    var id: String
    var usage: TokenUsage
    var at: Date?
    var model: String
    var cwd: String?
  }

  static let recentLimit = 16
  static let chunkSize = 4 << 20

  public init(kind: AgentKind) { self.kind = kind }

  /// Context window in tokens for a Claude model. Claude 5 models (and `[1m]` variants) have
  /// 1M in Claude Code; a conversation seen above 200k proves 1M as well.
  static func claudeContextWindow(model: String?, largest: Int) -> Int {
    if largest > 200_000 || model?.contains("[1m]") == true { return 1_000_000 }
    if let model, let range = model.range(of: #"^claude-[a-z]+-(\d+)"#, options: .regularExpression),
      let major = Int(model[range].split(separator: "-").last ?? ""), major >= 5
    {
      return 1_000_000
    }
    return 200_000
  }

  /// Parses what was appended since the last call. Returns false without reading when the file
  /// is shorter than what was already read (it was replaced): start over with a new reader.
  public mutating func read(_ url: URL, _ add: (UsageContribution) -> Void) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size < offset { return false }
    guard size > offset else { return true }
    try handle.seek(toOffset: offset)
    var pending = Data()
    while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
      pending.append(chunk)
      // Only complete lines; the rest waits for the next chunk (or the next call).
      guard let last = pending.lastIndex(of: 10) else { continue }
      let complete = pending[pending.startIndex...last]
      for line in complete.split(separator: 10) where !line.isEmpty { consume(Data(line), add) }
      offset += UInt64(complete.count)
      pending = Data(pending[pending.index(after: last)...])
    }
    return true
  }

  mutating func consume(_ line: Data, _ add: (UsageContribution) -> Void) {
    switch kind {
    case .claude:
      guard line.contains(Self.usageTag) else { return }
      consumeClaude(line, add)
    case .codex:
      guard line.contains(Self.tokenCountTag) || line.contains(Self.turnContextTag) || line.contains(Self.sessionMetaTag)
      else { return }
      consumeCodex(line, add)
    }
  }

  private mutating func consumeClaude(_ line: Data, _ add: (UsageContribution) -> Void) {
    guard let object = Self.object(line), object["type"] as? String == "assistant",
      let message = object["message"] as? [String: Any], let raw = message["usage"] as? [String: Any]
    else { return }
    let name = message["model"] as? String ?? model ?? "unknown"
    guard name != "<synthetic>" else { return }  // local placeholder replies, no tokens
    let usage = TokenUsage(
      input: Self.int(raw["input_tokens"]), cacheRead: Self.int(raw["cache_read_input_tokens"]),
      cacheWrite: Self.int(raw["cache_creation_input_tokens"]), output: Self.int(raw["output_tokens"]),
      reasoning: Self.int((raw["output_tokens_details"] as? [String: Any])?["thinking_tokens"]))
    let at = Self.date(object["timestamp"])
    let lineCwd = object["cwd"] as? String ?? cwd
    if object["isSidechain"] as? Bool != true {
      model = name
      cwd = lineCwd
      let context = usage.input + usage.cacheRead + usage.cacheWrite
      largestContext = max(largestContext, context)
      contextTokens = context
      contextWindow = Self.claudeContextWindow(model: name, largest: largestContext)
    }
    let id = message["id"] as? String ?? object["requestId"] as? String
    if let id, let index = recent.firstIndex(where: { $0.id == id }) {
      let counted = recent[index]
      guard counted.usage != usage else { return }
      recent[index].usage = usage
      add(UsageContribution(at: counted.at, model: counted.model, cwd: counted.cwd, usage: usage - counted.usage, messageId: id))
      return
    }
    if let id {
      recent.append(Recent(id: id, usage: usage, at: at, model: name, cwd: lineCwd))
      if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }
    add(UsageContribution(at: at, model: name, cwd: lineCwd, usage: usage, messageId: id))
  }

  private mutating func consumeCodex(_ line: Data, _ add: (UsageContribution) -> Void) {
    guard let object = Self.object(line), let payload = object["payload"] as? [String: Any] else { return }
    switch object["type"] as? String {
    case "session_meta":
      cwd = payload["cwd"] as? String ?? cwd
    case "turn_context":
      model = payload["model"] as? String ?? model
      cwd = payload["cwd"] as? String ?? cwd
      if let model {
        for item in unattributed {
          add(UsageContribution(at: item.at, model: model, cwd: cwd, usage: item.usage, messageId: nil))
        }
        unattributed.removeAll()
      }
    case "event_msg":
      guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
        let raw = info["total_token_usage"] as? [String: Any]
      else { return }
      let total = Self.codexUsage(raw)
      let lastRaw = info["last_token_usage"] as? [String: Any]
      let last = lastRaw.map(Self.codexUsage)
      if let window = info["model_context_window"] { contextWindow = Self.int(window) }
      if let lastRaw { contextTokens = Self.int(lastRaw["total_tokens"]) }
      var delta = codexTotal.map { total - $0 } ?? (last ?? total)
      // A smaller cumulative total means the count restarted.
      if [delta.input, delta.cacheRead, delta.cacheWrite, delta.output].contains(where: { $0 < 0 }) { delta = last ?? total }
      codexTotal = total
      guard !delta.isZero else { return }
      let at = Self.date(object["timestamp"])
      guard let model else {
        unattributed.append(Unattributed(at: at, usage: delta))
        return
      }
      add(UsageContribution(at: at, model: model, cwd: cwd, usage: delta, messageId: nil))
    default: break
    }
  }

  /// Codex's `input_tokens` includes the cached part.
  static func codexUsage(_ raw: [String: Any]) -> TokenUsage {
    let cached = int(raw["cached_input_tokens"])
    let written = int(raw["cache_write_input_tokens"])
    return TokenUsage(
      input: max(0, int(raw["input_tokens"]) - cached - written), cacheRead: cached, cacheWrite: written,
      output: int(raw["output_tokens"]), reasoning: int(raw["reasoning_output_tokens"]))
  }

  static let usageTag = Data(#""usage""#.utf8)
  static let tokenCountTag = Data(#""token_count""#.utf8)
  static let turnContextTag = Data(#""turn_context""#.utf8)
  static let sessionMetaTag = Data(#""session_meta""#.utf8)

  static func object(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
  }
  static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

  nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
  private static let dateLock = NSLock()

  static func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return dateLock.withLock { isoFractional.date(from: text) ?? iso.date(from: text) }
  }
}

extension Data {
  /// Byte search (memmem), much faster than `range(of:)` on the gigabytes of logs scanned.
  func contains(_ needle: Data) -> Bool {
    withUnsafeBytes { haystack in
      needle.withUnsafeBytes { pattern in
        guard let base = haystack.baseAddress, let target = pattern.baseAddress else { return false }
        return memmem(base, haystack.count, target, pattern.count) != nil
      }
    }
  }
}
