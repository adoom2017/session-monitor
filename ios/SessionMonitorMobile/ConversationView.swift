import SMProtocol
import SwiftUI

/// The whole conversation: history pages loaded on demand at the top, tool calls, results and
/// thinking expandable, and (tmux sessions) the turn being generated, live from the pane.
struct ConversationView: View {
  let sessionID: String
  let entries: [TranscriptEntry]?
  let hasOlder: Bool
  let live: LiveOutput?
  let loadOlder: () -> Void
  @State private var followBottom = true
  @State private var userScrolling = false

  var body: some View {
    if let entries {
      if entries.isEmpty && live == nil {
        ContentUnavailableView("还没有对话", systemImage: "text.bubble", description: Text("会话的对话记录会显示在这里。"))
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              if hasOlder {
                ProgressView()
                  .frame(maxWidth: .infinity).padding(.vertical, 6)
                  // Reaching the top loads the page before. Keyed by the oldest entry, so a page
                  // that arrived while the spinner stayed on screen asks for the next one (an
                  // onAppear alone fired once and left the spinner turning).
                  .task(id: entries.first?.id) { loadOlder() }
              }
              ForEach(entries) { EntryView(entry: $0).id($0.id) }
              if let live { LiveCard(live: live).id("live") }
              Color.clear.frame(height: 1).id("bottom")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
          }
          .defaultScrollAnchor(.bottom)
          // Rows render taller or shorter than the lazy stack estimated, so the opening position
          // drifts off the bottom; while following, every size change goes back there. Only the
          // reader's own scrolling stops or resumes following, not content pushing the end away.
          .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
          .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            if userScrolling {
              followBottom = new.visibleRect.maxY >= new.contentSize.height - 24
            } else if followBottom, old.contentSize.height != new.contentSize.height {
              proxy.scrollTo("bottom", anchor: .bottom)
            }
          }
          // An older page went in above: stay on the entry being read instead of the top,
          // which also moves the spinner off screen.
          .onChange(of: entries.first?.id) { previous, _ in
            if let previous, entries.contains(where: { $0.id == previous }) {
              proxy.scrollTo(previous, anchor: .top)
            }
          }
        }
      }
    } else if let live {
      ScrollView { LiveCard(live: live).padding(14) }.defaultScrollAnchor(.bottom)
    } else {
      ProgressView("正在读取对话…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct EntryView: View {
  let entry: TranscriptEntry
  /// Thinking starts open (it is read, not skimmed); tool input and output start collapsed.
  @State private var expanded: Bool

  init(entry: TranscriptEntry) {
    self.entry = entry
    _expanded = State(initialValue: entry.role == .thinking)
  }

  var body: some View {
    switch entry.role {
    case .user:
      HStack {
        Spacer(minLength: 40)
        Text(entry.text).font(.callout).foregroundStyle(.white)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(RoundedRectangle(cornerRadius: 16).fill(Theme.blue))
          .textSelection(.enabled)
      }
    case .assistant:
      MarkdownView(entry.text).font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        .textSelection(.enabled)
    case .tool:
      expandable(symbol: "terminal", tint: Theme.textSecondary, monospaced: true)
    case .toolResult:
      expandable(symbol: "arrow.turn.down.right", tint: Theme.idle, monospaced: true)
        .padding(.leading, 18)
    case .thinking:
      expandable(symbol: "brain", tint: Theme.indigo, monospaced: false)
    case .event:
      Label(entry.text, systemImage: "stop.circle")
        .font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  /// One line, tap to show the full input / output / thought.
  private func expandable(symbol: String, tint: Color, monospaced: Bool) -> some View {
    let full = entry.role == .thinking ? entry.text : entry.detail
    // Thinking shows only the label "思考" collapsed; tools show their summary line.
    let canExpand = full.map { !$0.isEmpty && (entry.role == .thinking || $0 != entry.text) } ?? false
    return VStack(alignment: .leading, spacing: 6) {
      Button {
        if canExpand { withAnimation(.snappy) { expanded.toggle() } }
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: symbol).font(.caption).foregroundStyle(tint)
          Text(entry.role == .thinking ? "思考" : entry.text)
            .font(monospaced ? .caption.monospaced() : .caption.italic())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          if canExpand {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .font(.caption2.weight(.semibold)).foregroundStyle(Theme.idle)
          }
        }
      }
      .buttonStyle(.plain)
      if expanded, let full {
        Group {
          if monospaced {
            // Commands and output keep their lines; scroll sideways for long ones.
            ScrollView(.horizontal) {
              Text(full)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
            }
          } else {
            // Prose (thinking) wraps to the screen width, with inline Markdown (code, bold).
            // Thinking often ends with blank lines, which left an empty band in the box.
            MarkdownView.inline(full.trimmingCharacters(in: .whitespacesAndNewlines))
              .font(.caption)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
          }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
      }
    }
    .padding(.horizontal, 4)
  }
}

/// The current turn as the terminal shows it while it is being generated.
struct LiveCard: View {
  let live: LiveOutput
  @State private var pulse = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle().fill(Theme.green).frame(width: 7, height: 7)
          .opacity(pulse ? 0.35 : 1)
          .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
          .onAppear { pulse = true }
        Text("正在生成 · 实时").font(.caption.weight(.semibold)).foregroundStyle(Theme.green)
      }
      Text(ANSIRenderer.render(live.text, styled: live.styled))
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 14).fill(TerminalView.background))
    .environment(\.colorScheme, .dark)
  }
}

/// The part of the pane that belongs to the turn in progress: below the last prompt the user
/// sent, above the agent's input box (Claude `❯`, Codex `›`, Antigravity `>`).
struct LiveOutput: Equatable {
  let text: String
  let styled: Bool

  static func extract(_ pane: PaneSnapshot, agent: String) -> LiveOutput? {
    let styledLines = PaneText.unwrap(pane.text.components(separatedBy: "\n"), columns: pane.columns)
    let plain = styledLines.map { ANSIRenderer.strip($0) }
    guard let range = agent == "agy"
      ? agyTurnRange(styled: styledLines, plain: plain, isStyled: pane.styled == true)
      : defaultTurnRange(plain: plain, marker: agent == "codex" ? "›" : "❯")
    else { return nil }
    var lines = Array(styledLines[range])
    while let first = lines.first, ANSIRenderer.strip(first).trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last, ANSIRenderer.strip(last).trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return nil }
    return LiveOutput(text: lines.suffix(60).joined(separator: "\n"), styled: pane.styled == true)
  }

  private static func isRule(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.count >= 8 && t.allSatisfy { "─━═".contains($0) }
  }

  private static func defaultTurnRange(plain: [String], marker: Character) -> Range<Int>? {
    func isPrompt(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).first == marker }
    // The input box: the last prompt line; for Claude also the rule just above it.
    guard var end = plain.lastIndex(where: isPrompt) else { return nil }
    if end > 0, isRule(plain[end - 1]) { end -= 1 }
    // The user's message echoed above: the previous prompt line, then its continuation lines.
    // Not found (scrolled out even of the scrollback): everything above the input box, rather
    // than no live view at all.
    let echo = plain[..<end].lastIndex(where: isPrompt)
    var start = echo.map { $0 + 1 } ?? 0
    while echo != nil, start < end, plain[start].hasPrefix("  "), !plain[start].trimmingCharacters(in: .whitespaces).isEmpty,
      !plain[start].contains("⏺"), !plain[start].contains("•")
    {
      start += 1
    }
    return start < end ? start..<end : nil
  }

  /// Antigravity uses ASCII `>`, which also appears in menus (`> 1. …`), answer echoes and
  /// Markdown quotes. Anchor on the rule-framed input box (or permission/question overlay),
  /// and match the echoed user prompt by the turn-separator rule directly above it.
  private static func agyTurnRange(styled: [String], plain: [String], isStyled: Bool) -> Range<Int>? {
    guard let end = agyEnd(in: plain), end > 0 else { return nil }
    let echo = (1..<end).reversed().first { isAgyPrompt(plain[$0]) && isRule(plain[$0 - 1]) }
    var start = echo.map { $0 + 1 } ?? 0
    // Plain assistant replies also start with two spaces (non-bold); multi-line echoed user
    // prompts carry SGR bold before the two spaces.
    while echo != nil, isStyled, start < end,
      plain[start].hasPrefix("  "),
      !isAgyOutputMarker(plain[start].trimmingCharacters(in: .whitespaces)),
      hasLeadingBold(styled[start])
    {
      start += 1
    }
    return start < end ? start..<end : nil
  }

  private static func isAgyPrompt(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).first == ">"
  }

  private static func agyEnd(in plain: [String]) -> Int? {
    guard let lastNonEmpty = plain.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      return nil
    }
    // Normal turn: `>` input box framed by rules directly above and below, near the bottom footer.
    for closeRule in stride(from: lastNonEmpty, through: max(0, lastNonEmpty - 3), by: -1) where isRule(plain[closeRule]) {
      let below = plain[(closeRule + 1)..<(lastNonEmpty + 1)]
      if below.contains(where: { agyMenuOption($0) != nil }) { continue }
      var i = closeRule - 1
      var draftLines = 0
      while i > 0, draftLines < 10,
        plain[i].trimmingCharacters(in: .whitespaces).isEmpty || plain[i].hasPrefix("  ")
      {
        i -= 1
        draftLines += 1
      }
      if i > 0, isAgyPrompt(plain[i]), isRule(plain[i - 1]) {
        return i - 1
      }
    }
    // Permission / ask_question overlay replaces the input box: stop above its menu or footer.
    // A custom status line (e.g. context usage) can appear below `esc to cancel`.
    let tailStart = max(0, lastNonEmpty - 5)
    if let footerBottom = (tailStart...lastNonEmpty).reversed().first(where: {
      isAgyFooter(plain[$0].trimmingCharacters(in: .whitespaces))
    }) {
      var end = footerBottom
      while end > 0 {
        let trimmed = plain[end - 1].trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || isAgyFooter(trimmed) { end -= 1 } else { break }
      }
      return agyMenuStart(in: plain, endingAt: end) ?? end
    }
    return agyMenuStart(in: plain, endingAt: lastNonEmpty + 1)
  }

  private static func isAgyFooter(_ trimmed: String) -> Bool {
    trimmed.contains("esc to cancel") || trimmed.contains("? for shortcuts") || trimmed.contains("↑/↓ Navigate")
  }

  /// Start index of a contiguous `1. … N.` selection menu with one `>` marker right above `end`.
  private static func agyMenuStart(in plain: [String], endingAt end: Int) -> Int? {
    var idx = end - 1
    while idx >= 0, plain[idx].trimmingCharacters(in: .whitespaces).isEmpty { idx -= 1 }
    var expected: Int?
    var count = 0
    var selectedCount = 0
    var continuations = 0
    var top = end
    while idx >= 0 {
      let line = plain[idx]
      if let option = agyMenuOption(line) {
        if let want = expected {
          guard option.number == want else { break }
          expected = want - 1
        } else {
          expected = option.number - 1
        }
        count += 1
        if option.selected { selectedCount += 1 }
        continuations = 0
        top = idx
        if expected == 0 { break }
      } else if continuations < 4, line.hasPrefix("   "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
        continuations += 1
      } else {
        break
      }
      idx -= 1
    }
    return expected == 0 && count >= 2 && selectedCount == 1 ? top : nil
  }

  private static func agyMenuOption(_ line: String) -> (number: Int, selected: Bool)? {
    var rest = Substring(line.trimmingCharacters(in: .whitespaces))
    let selected = rest.first == ">"
    if selected { rest = rest.dropFirst().drop(while: { $0 == " " }) }
    let digits = rest.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
    let after = rest.dropFirst(digits.count)
    guard after.first == ".", after.dropFirst().first == " " else { return nil }
    guard !after.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return (number, selected)
  }

  private static func isAgyOutputMarker(_ trimmed: String) -> Bool {
    guard let first = trimmed.first else { return true }
    if "○●▸?└•⎿".contains(first) { return true }
    return first.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
  }

  /// Whether SGR bold is turned on before the first visible character.
  private static func hasLeadingBold(_ styledLine: String) -> Bool {
    let scalars = Array(styledLine.unicodeScalars)
    var style = ANSIRenderer.Style()
    var i = 0
    while i < scalars.count {
      guard scalars[i] == "\u{1B}" else { return style.bold }
      guard i + 1 < scalars.count else { return style.bold }
      if scalars[i + 1] == "[" {
        var j = i + 2
        var parameters = ""
        while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
          parameters.unicodeScalars.append(scalars[j])
          j += 1
        }
        if j < scalars.count, scalars[j] == "m" { ANSIRenderer.update(&style, with: parameters) }
        i = j + 1
      } else if scalars[i + 1] == "]" {
        var j = i + 2
        while j < scalars.count, scalars[j] != "\u{07}", scalars[j] != "\u{1B}" { j += 1 }
        i = j < scalars.count && scalars[j] == "\u{1B}" ? j + 2 : j + 1
      } else {
        i += 2
      }
    }
    return false
  }
}
