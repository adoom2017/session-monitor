import Foundation
import SMProtocol

/// Conversation entries from a Claude transcript or Codex rollout, read incrementally
/// (DEV_SPEC §17.6). Not thread-safe: one feed per subscription, used from one task.
public final class TranscriptFeed {
  public let url: URL
  let kind: AgentKind
  private var offset: UInt64 = 0
  static let tailBytes: UInt64 = 1_048_576

  public init(url: URL, kind: AgentKind) {
    self.url = url
    self.kind = kind
  }

  /// The last `limit` entries; remembers where the file ended.
  public func initial(limit: Int) throws -> [TranscriptEntry] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let start = size > Self.tailBytes ? size - Self.tailBytes : 0
    try handle.seek(toOffset: start)
    let data = try handle.readToEnd() ?? Data()
    let entries = parse(data, base: start, dropFirst: start > 0)
    return Array(entries.suffix(limit))
  }

  /// Entries appended since the last read. `reset` when the file shrank (replaced): the caller
  /// should discard what it holds and use `entries` (a fresh tail).
  public func poll(limit: Int) throws -> (entries: [TranscriptEntry], reset: Bool) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size < offset {
      try? handle.close()
      return (try initial(limit: limit), true)
    }
    guard size > offset else { return ([], false) }
    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    return (parse(data, base: offset, dropFirst: false), false)
  }

  /// Parses complete lines only; `offset` advances past the last complete line.
  private func parse(_ data: Data, base: UInt64, dropFirst: Bool) -> [TranscriptEntry] {
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
    offset = base + UInt64(lineStart - data.startIndex)
    return entries
  }
}

public enum TranscriptParser {
  /// ISO8601DateFormatter is thread-safe for formatting and parsing.
  nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  public static func entries(_ line: Data, kind: AgentKind, offset: UInt64) -> [TranscriptEntry] {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: line) else { return [] }
    let at = json["timestamp"]?.string.flatMap { iso.date(from: $0) }
    switch kind {
    case .claude: return claude(json, at: at, offset: offset)
    case .codex: return codex(json, at: at, offset: offset)
    }
  }

  /// Main-thread user text, assistant text and tool calls; sub-agent (sidechain) and meta lines
  /// and tool results are left out.
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
      return [TranscriptEntry(id: base, role: .tool, text: "已中断", at: at)]
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
      case "tool_use":
        let name = item["name"]?.string ?? "tool"
        let summary = toolSummary(item["input"])
        result.append(
          TranscriptEntry(id: id, role: .tool, text: summary.map { "\(name): \($0)" } ?? name, at: at))
      default: continue
      }
    }
    return result
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
    case "CommandExecution":
      guard case .array(let parts)? = item["command"], let script = parts.last?.string else { return [] }
      let exit = item["exit_code"]?.number.map { $0 == 0 ? "" : "（退出码 \(Int($0))）" } ?? ""
      return [TranscriptEntry(id: id, role: .tool, text: "Bash: " + singleLine(script, limit: 200) + exit, at: at)]
    default: return []
    }
  }

  /// Injected context (AGENTS.md, environment, command wrappers) starts with a tag or heading
  /// marker and is not something the user typed.
  static func isConversational(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
  }

  static func toolSummary(_ input: JSONValue?) -> String? {
    guard let input else { return nil }
    for key in ["command", "file_path", "pattern", "url", "description", "prompt", "query"] {
      if let value = input[key]?.string, !value.isEmpty { return singleLine(value, limit: 200) }
    }
    return nil
  }
}
