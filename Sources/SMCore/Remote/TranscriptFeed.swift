import Foundation
import SMProtocol

/// Conversation entries from a Claude transcript or Codex rollout (DEV_SPEC §17.6): the whole
/// history is parsed once, then the file is followed incrementally. Thread-safe; parse it off the
/// main actor (transcripts reach tens of MB).
public final class TranscriptFeed: @unchecked Sendable {
  public let url: URL
  let kind: AgentKind
  private let lock = NSLock()
  private var offset: UInt64 = 0
  private var all: [TranscriptEntry] = []
  /// Files beyond this are read from their tail only.
  static let maxBytes: UInt64 = 64 * 1_048_576

  public init(url: URL, kind: AgentKind) {
    self.url = url
    self.kind = kind
  }

  /// Parses the whole history (or the last 64 MB of it).
  public func load() throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let start = size > Self.maxBytes ? size - Self.maxBytes : 0
    try handle.seek(toOffset: start)
    let data = try handle.readToEnd() ?? Data()
    let (entries, end) = Self.parse(data, base: start, dropFirst: start > 0, kind: kind)
    lock.withLock {
      all = entries
      offset = end
    }
  }

  /// The newest `count` entries, and whether older ones exist.
  public func latest(_ count: Int) -> (entries: [TranscriptEntry], hasOlder: Bool) {
    lock.withLock { (Array(all.suffix(count)), all.count > count) }
  }

  /// Up to `count` entries before the entry `id`.
  public func page(before id: String, count: Int) -> (entries: [TranscriptEntry], hasOlder: Bool) {
    lock.withLock {
      guard let index = all.firstIndex(where: { $0.id == id }) else { return ([], false) }
      let start = max(0, index - count)
      return (Array(all[start..<index]), start > 0)
    }
  }

  /// Entries appended since the last read. `reset` when the file shrank (replaced): the history
  /// was reloaded and the caller should start over from `latest`.
  public func poll() throws -> (entries: [TranscriptEntry], reset: Bool) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let known = lock.withLock { offset }
    if size < known {
      try? handle.close()
      try load()
      return ([], true)
    }
    guard size > known else { return ([], false) }
    try handle.seek(toOffset: known)
    let data = try handle.readToEnd() ?? Data()
    let (entries, end) = Self.parse(data, base: known, dropFirst: false, kind: kind)
    lock.withLock {
      all += entries
      offset = end
    }
    return (entries, false)
  }

  /// Complete lines only; returns where the last complete line ended.
  static func parse(_ data: Data, base: UInt64, dropFirst: Bool, kind: AgentKind) -> ([TranscriptEntry], UInt64) {
    var entries: [TranscriptEntry] = []
    var lineStart = data.startIndex
    var first = true
    while let newline = data[lineStart...].firstIndex(of: 10) {
      let line = data[lineStart..<newline]
      let lineOffset = base + UInt64(lineStart - data.startIndex)
      if !(first && dropFirst), !line.isEmpty {
        entries += TranscriptParser.entries(Data(line), kind: kind, offset: lineOffset)
      }
      first = false
      lineStart = newline + 1
    }
    return (entries, base + UInt64(lineStart - data.startIndex))
  }
}

public enum TranscriptParser {
  /// ISO8601DateFormatter is thread-safe for formatting and parsing.
  nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()
  private static let isoLock = NSLock()

  static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    return isoLock.withLock { iso.date(from: text) ?? isoPlain.date(from: text) }
  }

  public static func entries(_ line: Data, kind: AgentKind, offset: UInt64) -> [TranscriptEntry] {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: line) else { return [] }
    let at = date((json["timestamp"] ?? json["created_at"])?.string)
    switch kind {
    case .claude: return claude(json, at: at, offset: offset)
    case .codex: return codex(json, at: at, offset: offset)
    case .pi: return pi(json, at: at, offset: offset)
    case .agy: return agy(json, at: at, offset: offset)
    }
  }

  /// Tool output kept per entry; the rest is cut (the phone shows it on demand).
  static let detailLimit = 6000

  static func clipped(_ text: String) -> String {
    text.count <= detailLimit ? text : String(text.prefix(detailLimit)) + "\n…（已截断）"
  }

  /// Main-thread messages, thinking, tool calls with their input, and tool results; sub-agent
  /// (sidechain) and meta lines are left out.
  static func claude(_ json: JSONValue, at: Date?, offset: UInt64) -> [TranscriptEntry] {
    guard let type = json["type"]?.string, type == "user" || type == "assistant",
      json["isSidechain"]?.bool != true, json["isMeta"]?.bool != true,
      let content = json["message"]?["content"]
    else { return [] }
    let base = json["uuid"]?.string ?? "c\(offset)"
    // Claude records Esc as a user line; show it as an event, not as something the user wrote.
    if type == "user", let text = content.string ?? content.array?.first?["text"]?.string,
      text.hasPrefix("[Request interrupted")
    {
      return [TranscriptEntry(id: base, role: .event, text: "已中断", at: at)]
    }
    if let text = content.string {
      return type == "user" && isConversational(text)
        ? [TranscriptEntry(id: base, role: .user, text: text, at: at)] : []
    }
    guard case .array(let items) = content else { return [] }
    var result: [TranscriptEntry] = []
    for (index, item) in items.enumerated() {
      let id = "\(base)-\(index)"
      switch item["type"]?.string {
      case "text":
        guard let text = item["text"]?.string, !text.isEmpty else { continue }
        if type == "user" && !isConversational(text) { continue }
        result.append(TranscriptEntry(id: id, role: type == "user" ? .user : .assistant, text: text, at: at))
      case "thinking":
        guard let text = item["thinking"]?.string, !text.isEmpty else { continue }
        result.append(TranscriptEntry(id: id, role: .thinking, text: text, at: at))
      case "tool_use":
        let name = item["name"]?.string ?? "tool"
        let summary = toolSummary(item["input"])
        result.append(
          TranscriptEntry(
            id: id, role: .tool, text: summary.map { "\(name): \($0)" } ?? name,
            detail: item["input"].map { clipped(pretty($0)) }, at: at))
      case "tool_result":
        let output = toolResultText(item["content"])
        let failed = item["is_error"]?.bool == true
        result.append(
          TranscriptEntry(
            id: id, role: .toolResult,
            text: (failed ? "失败：" : "") + (output.split(separator: "\n").first.map(String.init) ?? "（无输出）"),
            detail: output.isEmpty ? nil : clipped(output), at: at))
      default: continue
      }
    }
    return result
  }

  static func toolResultText(_ value: JSONValue?) -> String {
    if let text = value?.string { return text }
    guard case .array(let parts)? = value else { return "" }
    return parts.compactMap { part in
      part["text"]?.string ?? (part["type"]?.string == "image" ? "[图片]" : nil)
    }.joined(separator: "\n")
  }

  static func pretty(_ value: JSONValue) -> String {
    if let text = value.string { return text }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  /// Codex 0.16x writes each finished item as `event_msg` / `item_completed`.
  static func codex(_ json: JSONValue, at: Date?, offset: UInt64) -> [TranscriptEntry] {
    guard json["type"]?.string == "event_msg", json["payload"]?["type"]?.string == "item_completed",
      let item = json["payload"]?["item"]
    else { return [] }
    let id = item["id"]?.string ?? "x\(offset)"
    func text(_ value: JSONValue?) -> String {
      guard case .array(let parts)? = value else { return value?.string ?? "" }
      return parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
    }
    switch item["type"]?.string {
    case "UserMessage":
      let value = text(item["content"])
      return isConversational(value) ? [TranscriptEntry(id: id, role: .user, text: value, at: at)] : []
    case "AgentMessage":
      let value = text(item["content"])
      return value.isEmpty ? [] : [TranscriptEntry(id: id, role: .assistant, text: value, at: at)]
    case "Reasoning":
      let value = (item["summary_text"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
      return value.isEmpty ? [] : [TranscriptEntry(id: id, role: .thinking, text: value, at: at)]
    case "CommandExecution":
      guard case .array(let parts)? = item["command"], let script = parts.last?.string else { return [] }
      let code = item["exit_code"]?.number.map(Int.init)
      let output = item["aggregated_output"]?.string ?? ""
      var entries = [
        TranscriptEntry(
          id: id, role: .tool, text: "Bash: " + singleLine(script, limit: 200), detail: clipped(script), at: at)
      ]
      let status = code.map { $0 == 0 ? "" : "退出码 \($0)：" } ?? ""
      entries.append(
        TranscriptEntry(
          id: id + "-out", role: .toolResult,
          text: status + (output.split(separator: "\n").first.map(String.init) ?? "（无输出）"),
          detail: output.isEmpty ? nil : clipped(output), at: at))
      return entries
    default: return []
    }
  }

  /// Pi stores every entry as `type: "message"` / `role`: user, assistant (text, thinking,
  /// toolCall blocks) or toolResult. System messages carry the prompt and are not conversation.
  static func pi(_ json: JSONValue, at: Date?, offset: UInt64) -> [TranscriptEntry] {
    guard json["type"]?.string == "message", let message = json["message"],
      let role = message["role"]?.string
    else { return [] }
    let base = json["id"]?.string ?? "p\(offset)"
    let content = message["content"]
    if role == "user" {
      if let text = content?.string {
        return isConversational(text) ? [TranscriptEntry(id: base, role: .user, text: text, at: at)] : []
      }
      return (content?.array ?? []).enumerated().compactMap { index, item in
        guard item["type"]?.string == "text", let text = item["text"]?.string,
          isConversational(text)
        else { return nil }
        return TranscriptEntry(id: "\(base)-\(index)", role: .user, text: text, at: at)
      }
    }
    if role == "assistant" {
      if let text = content?.string {
        return text.isEmpty ? [] : [TranscriptEntry(id: base, role: .assistant, text: text, at: at)]
      }
      var result: [TranscriptEntry] = []
      for (index, item) in (content?.array ?? []).enumerated() {
        let id = "\(base)-\(index)"
        switch item["type"]?.string {
        case "text":
          guard let text = item["text"]?.string, !text.isEmpty else { continue }
          result.append(TranscriptEntry(id: id, role: .assistant, text: text, at: at))
        case "thinking":
          guard let text = item["thinking"]?.string, !text.isEmpty else { continue }
          result.append(TranscriptEntry(id: id, role: .thinking, text: text, at: at))
        case "toolCall":
          let name = item["name"]?.string ?? "tool"
          let arguments = item["arguments"]
          let summary = arguments?.string.map { singleLine($0, limit: 200) } ?? toolSummary(arguments)
          result.append(
            TranscriptEntry(
              id: id, role: .tool, text: summary.map { "\(name): \($0)" } ?? name,
              detail: arguments.map { clipped(pretty($0)) }, at: at))
        default: continue
        }
      }
      return result
    }
    if role == "toolResult" {
      let output = toolResultText(content)
      let failed = message["isError"]?.bool == true
      return [
        TranscriptEntry(
          id: base, role: .toolResult,
          text: (failed ? "失败：" : "")
            + (output.split(separator: "\n").first.map(String.init) ?? "（无输出）"),
          detail: output.isEmpty ? nil : clipped(output), at: at)
      ]
    }
    return []
  }

  /// Agy logs `USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC`, `ERROR_MESSAGE` and `CHECKPOINT` in
  /// `transcript_full.jsonl`. Entry ids use the byte offset because resumed threads restart
  /// `step_index` from 0.
  static func agy(_ json: JSONValue, at: Date?, offset: UInt64) -> [TranscriptEntry] {
    switch json["type"]?.string {
    case "USER_INPUT":
      guard let raw = json["content"]?.string, let text = agyUserText(raw) else { return [] }
      return [TranscriptEntry(id: "a\(offset)", role: .user, text: text, at: at)]
    case "PLANNER_RESPONSE":
      var result: [TranscriptEntry] = []
      if let thinking = json["thinking"]?.string,
        !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        result.append(TranscriptEntry(id: "a\(offset)-th", role: .thinking, text: thinking, at: at))
      }
      if let content = json["content"]?.string {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          result.append(TranscriptEntry(id: "a\(offset)-txt", role: .assistant, text: trimmed, at: at))
        }
      }
      for (index, call) in (json["tool_calls"]?.array ?? []).enumerated() {
        let name = call["name"]?.string ?? "tool"
        let args = call["args"]
        let summary = toolSummary(args)
        result.append(
          TranscriptEntry(
            id: "a\(offset)-tc-\(index)", role: .tool,
            text: summary.map { "\(name): \($0)" } ?? name,
            detail: args.map { clipped(pretty($0)) }, at: at))
      }
      return result
    case "GENERIC":
      let body = agyGenericBody(json["content"]?.string ?? "")
      let errorText = json["error"]?.string ?? ""
      let status = json["status"]?.string
      let failed = status == "ERROR" || status == "INVALID" || !errorText.isEmpty
      let output = body.isEmpty ? errorText : body
      let firstLine = output.split(separator: "\n").lazy
        .map { singleLine(String($0), limit: 200) }
        .first { !$0.isEmpty } ?? "（无输出）"
      return [
        TranscriptEntry(
          id: "a\(offset)", role: .toolResult, text: (failed ? "失败：" : "") + firstLine,
          detail: output.isEmpty ? nil : clipped(output), at: at)
      ]
    case "ERROR_MESSAGE":
      let message = [json["error"]?.string, json["content"]?.string]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
      guard let message else { return [] }
      return [
        TranscriptEntry(
          id: "a\(offset)", role: .event, text: singleLine(message, limit: 120),
          detail: clipped(message), at: at)
      ]
    case "CHECKPOINT":
      return [TranscriptEntry(id: "a\(offset)", role: .event, text: "已压缩上下文", at: at)]
    default:
      return []
    }
  }

  /// Extracts the prompt inside `<USER_REQUEST>…</USER_REQUEST>` without applying `isConversational`
  /// (user requests can legitimately begin with `<`).
  static func agyUserText(_ raw: String) -> String? {
    if let start = raw.range(of: "<USER_REQUEST>"),
      let end = raw.range(of: "</USER_REQUEST>", range: start.upperBound..<raw.endIndex)
    {
      let body = raw[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      return body.isEmpty ? nil : body
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return isConversational(trimmed) ? trimmed : nil
  }

  static func agyGenericBody(_ raw: String) -> String {
    var lines = raw.components(separatedBy: "\n")[...]
    while let first = lines.first,
      first.hasPrefix("Created At:") || first.hasPrefix("Completed At:")
    {
      lines = lines.dropFirst()
    }
    let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : joined
  }

  /// Injected context (AGENTS.md, environment, command wrappers) starts with a tag or heading
  /// marker and is not something the user typed.
  static func isConversational(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
  }

  static func toolSummary(_ input: JSONValue?) -> String? {
    guard let input else { return nil }
    for key in [
      "toolSummary", "command", "CommandLine", "file_path", "path", "Path", "pattern", "url",
      "description", "Role", "prompt", "Prompt", "query", "title", "brief", "reason", "Action",
      "action", "text",
    ] {
      if let value = input[key]?.string, !value.isEmpty { return singleLine(value, limit: 200) }
    }
    return nil
  }
}
