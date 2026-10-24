import SwiftUI

/// Block-level Markdown for agent replies: headings, lists, fenced code, tables, quotes and rules,
/// with inline formatting (bold, italic, code, links) inside each block. SwiftUI's own Markdown
/// support is inline only, which showed `#`, `|` and ``` as text.
struct MarkdownView: View {
  let blocks: [MarkdownBlock]

  init(_ text: String) {
    blocks = MarkdownBlock.parse(text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
  }

  @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Self.inline(text)
        .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
        .padding(.top, level <= 2 ? 4 : 2)
    case .paragraph(let text):
      Self.inline(text)
    case .list(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
            Self.inline(item.text)
          }
          .padding(.leading, CGFloat(item.depth) * 16)
        }
      }
    case .code(let code):
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(size: 12, design: .monospaced))
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    case .quote(let text):
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.25)).frame(width: 3)
        Self.inline(text).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let header, let rows):
      ScrollView(.horizontal, showsIndicators: false) {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
              Self.inline(cell).font(.callout.weight(.semibold))
            }
          }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(header.indices), id: \.self) { column in
                Self.inline(column < row.count ? row[column] : "")
              }
            }
          }
        }
        .padding(10)
      }
      .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    case .rule:
      Divider().padding(.vertical, 2)
    }
  }

  static func inline(_ text: String) -> Text {
    let attributed = (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
      ?? AttributedString(text)
    return Text(attributed)
  }
}

enum MarkdownBlock: Equatable {
  struct Item: Equatable {
    var depth: Int
    var marker: String
    var text: String
  }

  case heading(level: Int, text: String)
  case paragraph(String)
  case list([Item])
  case code(String)
  case quote(String)
  case table(header: [String], rows: [[String]])
  case rule

  /// Line-based parse of the subset agents write. Anything unrecognized stays a paragraph, so
  /// no text is ever dropped.
  static func parse(_ text: String) -> [MarkdownBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var i = 0

    func flushParagraph() {
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph = []
      }
    }

    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Fenced code: everything up to the closing fence (or the end) verbatim.
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flushParagraph()
        let fence = String(trimmed.prefix(3))
        var code: [String] = []
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
          code.append(lines[i])
          i += 1
        }
        blocks.append(.code(code.joined(separator: "\n")))
        i += 1
        continue
      }
      if trimmed.isEmpty {
        flushParagraph()
        i += 1
        continue
      }
      if let heading = headingLevel(trimmed) {
        flushParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
        i += 1
        continue
      }
      if isRule(trimmed) {
        flushParagraph()
        blocks.append(.rule)
        i += 1
        continue
      }
      // Table: a header row followed by a |---|---| separator.
      if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
        flushParagraph()
        let header = cells(trimmed)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
          rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
          i += 1
        }
        blocks.append(.table(header: header, rows: rows))
        continue
      }
      if trimmed.hasPrefix(">") {
        flushParagraph()
        var quoted: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
          i += 1
        }
        blocks.append(.quote(quoted.joined(separator: "\n")))
        continue
      }
      if listItem(line) != nil {
        flushParagraph()
        var items: [Item] = []
        while i < lines.count {
          if let item = listItem(lines[i]) {
            items.append(item)
          } else if !items.isEmpty, lines[i].hasPrefix("  "),
            !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
          {
            // A wrapped continuation of the previous item.
            items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)
          } else {
            break
          }
          i += 1
        }
        blocks.append(.list(items))
        continue
      }
      paragraph.append(line)
      i += 1
    }
    flushParagraph()
    return blocks
  }

  static func headingLevel(_ line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
  }

  static func isRule(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  static func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
  }

  static func cells(_ row: String) -> [String] {
    var body = row
    if body.hasPrefix("|") { body.removeFirst() }
    if body.hasSuffix("|") { body.removeLast() }
    return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// `- item`, `* item`, `+ item`, `1. item`, `1) item`; two spaces of indent per level.
  static func listItem(_ line: String) -> Item? {
    let indent = line.prefix(while: { $0 == " " }).count
    let rest = line.dropFirst(indent)
    let depth = min(indent / 2, 4)
    if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
      return Item(depth: depth, marker: depth == 0 ? "•" : "◦", text: String(rest.dropFirst(2)))
    }
    let digits = rest.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 3 {
      let after = rest.dropFirst(digits.count)
      if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
        return Item(depth: depth, marker: "\(digits).", text: String(after.dropFirst(2)))
      }
    }
    return nil
  }
}
