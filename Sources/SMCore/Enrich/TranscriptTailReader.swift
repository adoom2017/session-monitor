import Foundation

public struct SessionEnrichment: Sendable, Equatable {
  public var hasTranscript = true
  public var diagnostics: [Diagnostic] = []
  public var title: String?
  public var snippet: String?
  public var model: String?
  public var gitBranch: String?
  public init(
    title: String? = nil, snippet: String? = nil, model: String? = nil, gitBranch: String? = nil
  ) {
    self.title = title
    self.snippet = snippet
    self.model = model
    self.gitBranch = gitBranch
  }
  public static func pendingTranscript(_ id: String) -> Self {
    var result = Self()
    result.hasTranscript = false
    result.diagnostics = [Diagnostic(.info, "transcript 尚未生成：\(id)")]
    return result
  }
}

public enum TranscriptTailReader {
  public static let tailLimit = 256 * 1024
  public static let headLimit = 64 * 1024

  public static func read(_ url: URL) throws -> SessionEnrichment {
    guard url.pathExtension == "jsonl" else {
      throw MonitorError.invalid("transcript must be a .jsonl file")
    }
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw MonitorError.invalid("refusing symlink transcript")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    let size = try handle.seekToEnd()
    let offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: tailLimit) else { return SessionEnrichment() }  // EOF is a valid empty transcript.
    var result = try parse(data, dropFirstLine: offset > 0)
    if result.title == nil, offset > 0 {
      try handle.seek(toOffset: 0)
      guard let head = try handle.read(upToCount: headLimit) else {
        throw MonitorError.invalid("unexpected EOF reading transcript header")
      }
      var lines = head.split(separator: 10, omittingEmptySubsequences: false)
      if size > UInt64(headLimit), head.last != 10 { lines.removeLast() }
      result.title = try parse(
        Data(lines.map { Data($0) }.joined(separator: Data([10]))), dropFirstLine: false
      ).title
    }
    return result
  }

  public static func parse(_ data: Data, dropFirstLine: Bool) throws -> SessionEnrichment {
    var lines = data.split(separator: 10, omittingEmptySubsequences: false)
    if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
    var result = SessionEnrichment()
    var foundAssistant = false
    for (index, line) in lines.enumerated().reversed() where !line.isEmpty {
      let json: JSONValue
      do { json = try JSONDecoder().decode(JSONValue.self, from: Data(line)) } catch {
        // A writer may still be appending the final physical line at EOF.
        guard index == lines.count - 1, data.last != 10,
          case DecodingError.dataCorrupted(let context) = error,
          let underlying = context.underlyingError as NSError?,
          underlying.domain == NSCocoaErrorDomain,
          underlying.code == CocoaError.propertyListReadCorrupt.rawValue,
          underlying.userInfo[NSDebugDescriptionErrorKey] as? String == "Unexpected end of file"
        else { throw error }
        result.diagnostics.append(Diagnostic(.info, "transcript 最后一行尚未写完，已跳过。"))
        continue
      }
      if result.title == nil, json["type"]?.string == "ai-title" {
        result.title = json["aiTitle"]?.string.map { singleLine($0, limit: 120) }
      }
      if result.gitBranch == nil { result.gitBranch = json["gitBranch"]?.string }
      if !foundAssistant, json["type"]?.string == "assistant", json["isSidechain"]?.bool != true {
        foundAssistant = true
        result.model = json["message"]?["model"]?.string
        if let content = json["message"]?["content"]?.array {
          result.snippet = content.last(where: { $0["type"]?.string == "text" })?["text"]?.string
            .map { singleLine(plainText($0), limit: 120) }
        }
      }
    }
    return result
  }
}

/// Assistant replies are markdown; the one-line snippet shows plain text.
public func plainText(_ markdown: String) -> String {
  var lines: [String] = []
  for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
    var line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("```") { continue }
    line = line.replacingOccurrences(
      of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
    line = line.replacingOccurrences(
      of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    for marker in ["**", "`", "~~"] { line = line.replacingOccurrences(of: marker, with: "") }
    if line.range(of: #"^[|:\-\s]+$"#, options: .regularExpression) != nil { continue }
    if !line.isEmpty { lines.append(line) }
  }
  return lines.joined(separator: " ")
}
