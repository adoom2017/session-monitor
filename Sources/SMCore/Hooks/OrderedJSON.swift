import Foundation

/// JSON that keeps object key order and number literals, for editing user config files
/// (~/.claude/settings.json, ~/.codex/hooks.json) without reshuffling them.
public indirect enum OrderedJSON: Equatable, Sendable {
  case object([(String, OrderedJSON)])
  case array([OrderedJSON])
  case string(String)
  case number(String)  // literal text, written back unchanged
  case bool(Bool)
  case null

  public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
    switch (lhs, rhs) {
    case (.object(let a), .object(let b)):
      a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    case (.array(let a), .array(let b)): a == b
    case (.string(let a), .string(let b)): a == b
    case (.number(let a), .number(let b)): a == b
    case (.bool(let a), .bool(let b)): a == b
    case (.null, .null): true
    default: false
    }
  }

  public subscript(key: String) -> OrderedJSON? {
    guard case .object(let pairs) = self else { return nil }
    return pairs.first { $0.0 == key }?.1
  }

  public var objectPairs: [(String, OrderedJSON)]? {
    if case .object(let pairs) = self { return pairs }
    return nil
  }

  public var arrayValue: [OrderedJSON]? {
    if case .array(let items) = self { return items }
    return nil
  }

  public var stringValue: String? {
    if case .string(let text) = self { return text }
    return nil
  }

  /// Sets `key`, keeping its position if present, else appending.
  public mutating func set(_ key: String, _ value: OrderedJSON?) {
    guard case .object(var pairs) = self else { return }
    if let index = pairs.firstIndex(where: { $0.0 == key }) {
      if let value { pairs[index].1 = value } else { pairs.remove(at: index) }
    } else if let value {
      pairs.append((key, value))
    }
    self = .object(pairs)
  }

  // MARK: Parsing

  public static func parse(_ data: Data) throws -> OrderedJSON {
    var parser = Parser(bytes: Array(data))
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
    return value
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    func error(_ message: String) -> MonitorError {
      MonitorError.invalid("JSON \(message) at byte \(index)")
    }

    mutating func skipWhitespace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> OrderedJSON {
      skipWhitespace()
      guard index < bytes.count else { throw error("unexpected end") }
      switch bytes[index] {
      case UInt8(ascii: "{"): return try object()
      case UInt8(ascii: "["): return try array()
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"): try literal("true"); return .bool(true)
      case UInt8(ascii: "f"): try literal("false"); return .bool(false)
      case UInt8(ascii: "n"): try literal("null"); return .null
      default: return .number(try number())
      }
    }

    mutating func literal(_ word: String) throws {
      let expected = Array(word.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index..<index + expected.count]) == expected
      else { throw error("invalid literal") }
      index += expected.count
    }

    mutating func object() throws -> OrderedJSON {
      index += 1
      var pairs: [(String, OrderedJSON)] = []
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(pairs)
      }
      while true {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
          throw error("expected key")
        }
        let key = try string()
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
          throw error("expected ':'")
        }
        index += 1
        pairs.append((key, try value()))
        skipWhitespace()
        guard index < bytes.count else { throw error("unterminated object") }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
        } else if bytes[index] == UInt8(ascii: "}") {
          index += 1
          return .object(pairs)
        } else {
          throw error("expected ',' or '}'")
        }
      }
    }

    mutating func array() throws -> OrderedJSON {
      index += 1
      var items: [OrderedJSON] = []
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(items)
      }
      while true {
        items.append(try value())
        skipWhitespace()
        guard index < bytes.count else { throw error("unterminated array") }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
        } else if bytes[index] == UInt8(ascii: "]") {
          index += 1
          return .array(items)
        } else {
          throw error("expected ',' or ']'")
        }
      }
    }

    mutating func string() throws -> String {
      // Delegate escapes and UTF-8 validation to JSONSerialization on the exact literal.
      let start = index
      index += 1
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\\"): index += 2
        case UInt8(ascii: "\""):
          index += 1
          let literal = Data(bytes[start..<index])
          guard
            let text = try JSONSerialization.jsonObject(
              with: literal, options: [.fragmentsAllowed]) as? String
          else { throw error("invalid string") }
          return text
        default: index += 1
        }
      }
      throw error("unterminated string")
    }

    mutating func number() throws -> String {
      let start = index
      while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
      guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8),
        Double(text) != nil
      else { throw error("invalid value") }
      return text
    }
  }

  // MARK: Serializing (2-space indent, non-ASCII kept, like json.dump(indent=2, ensure_ascii=False))

  public func serialized() -> Data {
    var out = ""
    write(into: &out, indent: 0)
    out += "\n"
    return Data(out.utf8)
  }

  private func write(into out: inout String, indent: Int) {
    let pad = String(repeating: "  ", count: indent + 1)
    let close = String(repeating: "  ", count: indent)
    switch self {
    case .object(let pairs):
      if pairs.isEmpty { out += "{}"; return }
      out += "{\n"
      for (offset, pair) in pairs.enumerated() {
        out += pad + Self.quote(pair.0) + ": "
        pair.1.write(into: &out, indent: indent + 1)
        out += offset == pairs.count - 1 ? "\n" : ",\n"
      }
      out += close + "}"
    case .array(let items):
      if items.isEmpty { out += "[]"; return }
      out += "[\n"
      for (offset, item) in items.enumerated() {
        out += pad
        item.write(into: &out, indent: indent + 1)
        out += offset == items.count - 1 ? "\n" : ",\n"
      }
      out += close + "]"
    case .string(let text): out += Self.quote(text)
    case .number(let literal): out += literal
    case .bool(let flag): out += flag ? "true" : "false"
    case .null: out += "null"
    }
  }

  static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}
