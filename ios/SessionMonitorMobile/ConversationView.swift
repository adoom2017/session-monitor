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
                .onAppear { followBottom = true }
                .onDisappear { followBottom = false }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
          }
          .defaultScrollAnchor(.bottom)
          // Keep following new output only while the reader is at the bottom.
          .onChange(of: entries.last?.id) { _, _ in
            if followBottom { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
          }
          // An older page went in above: stay on the entry being read instead of the top,
          // which also moves the spinner off screen.
          .onChange(of: entries.first?.id) { previous, _ in
            if let previous, entries.contains(where: { $0.id == previous }) {
              proxy.scrollTo(previous, anchor: .top)
            }
          }
          .onChange(of: live?.text) { _, _ in
            if followBottom { proxy.scrollTo("bottom", anchor: .bottom) }
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
  @State private var expanded = false

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
      Text(Self.markdown(entry.text)).font(.callout)
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
        ScrollView(.horizontal) {
          Text(full)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .caption)
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize(horizontal: monospaced, vertical: false)
            .padding(10)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
      }
    }
    .padding(.horizontal, 4)
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
      ?? AttributedString(text)
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
/// sent, above the agent's input box (Claude `❯`, Codex `›`).
struct LiveOutput: Equatable {
  let text: String
  let styled: Bool

  static func extract(_ pane: PaneSnapshot, agent: String) -> LiveOutput? {
    let styledLines = PaneText.unwrap(pane.text.components(separatedBy: "\n"), columns: pane.columns)
    let plain = styledLines.map { ANSIRenderer.strip($0) }
    let marker: Character = agent == "codex" ? "›" : "❯"
    func isPrompt(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).first == marker }
    func isRule(_ line: String) -> Bool {
      let t = line.trimmingCharacters(in: .whitespaces)
      return t.count >= 8 && t.allSatisfy { "─━═".contains($0) }
    }
    // The input box: the last prompt line; for Claude also the rule just above it.
    guard var end = plain.lastIndex(where: isPrompt) else { return nil }
    if end > 0, isRule(plain[end - 1]) { end -= 1 }
    // The user's message echoed above: the previous prompt line, then its continuation lines.
    guard let echo = plain[..<end].lastIndex(where: isPrompt) else { return nil }
    var start = echo + 1
    while start < end, plain[start].hasPrefix("  "), !plain[start].trimmingCharacters(in: .whitespaces).isEmpty,
      !plain[start].contains("⏺"), !plain[start].contains("•")
    {
      start += 1
    }
    var lines = Array(styledLines[start..<end])
    while let first = lines.first, ANSIRenderer.strip(first).trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last, ANSIRenderer.strip(last).trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return nil }
    return LiveOutput(text: lines.suffix(60).joined(separator: "\n"), styled: pane.styled == true)
  }
}
