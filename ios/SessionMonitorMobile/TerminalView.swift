import SMProtocol
import SwiftUI
import UIKit

/// The tmux pane. Reading mode (default) wraps lines to the phone width at a readable size and
/// draws rule lines (────) as dividers; layout mode keeps the pane's columns, scaling the font
/// to fit (scrolls sideways below the minimum size).
struct TerminalView: View {
  let pane: PaneSnapshot?
  @AppStorage("terminalLayoutMode") private var layoutMode = false
  nonisolated static let background = Color(red: 0x0F / 255, green: 0x14 / 255, blue: 0x22 / 255)
  static let readingFont: CGFloat = 11
  static let minimumFont: CGFloat = 7
  static let maximumFont: CGFloat = 13
  /// Advance width of one column relative to the point size, measured from the system
  /// monospaced font.
  static let glyphWidth: CGFloat = {
    let font = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
    return ("0000000000" as NSString).size(withAttributes: [.font: font]).width / 1000
  }()

  var body: some View {
    if let pane {
      ZStack(alignment: .topTrailing) {
        if layoutMode { layout(pane) } else { reading(pane) }
        Button {
          layoutMode.toggle()
        } label: {
          Label(layoutMode ? "阅读模式" : "原始布局", systemImage: layoutMode ? "text.alignleft" : "rectangle.split.3x1")
            .font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(8)
      }
      .background(Self.background)
      .environment(\.colorScheme, .dark)
    } else {
      ProgressView("正在读取终端画面…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func reading(_ pane: PaneSnapshot) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(Array(Self.readingLines(pane.text).enumerated()), id: \.offset) { _, line in
          switch line {
          case .rule:
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.vertical, 4)
          case .blank:
            Color.clear.frame(height: 6)
          case .text(let value):
            Text(ANSIRenderer.render(value, styled: pane.styled == true))
              .font(.system(size: Self.readingFont, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .textSelection(.enabled)
    }
    .defaultScrollAnchor(.bottom)
  }

  private func layout(_ pane: PaneSnapshot) -> some View {
    GeometryReader { geometry in
      let columns = CGFloat(max(pane.columns ?? 80, 20))
      let padding: CGFloat = 10
      let fitted = (geometry.size.width - padding * 2) / (columns * Self.glyphWidth)
      let size = min(Self.maximumFont, max(Self.minimumFont, fitted))
      ScrollView([.vertical, .horizontal]) {
        Text(ANSIRenderer.render(pane.text, styled: pane.styled == true))
          .font(.system(size: size, design: .monospaced))
          .lineSpacing(1)
          .fixedSize(horizontal: true, vertical: false)
          .padding(padding)
          .frame(minWidth: geometry.size.width, alignment: .leading)
          .textSelection(.enabled)
      }
      .defaultScrollAnchor(.bottomLeading)
    }
  }

  enum Line: Equatable { case text(String), rule, blank }

  /// Lines for reading mode: rule lines become dividers, blank runs collapse, leading blanks go.
  static func readingLines(_ text: String) -> [Line] {
    var lines: [Line] = []
    for raw in text.components(separatedBy: "\n") {
      let plain = ANSIRenderer.strip(raw).trimmingCharacters(in: .whitespaces)
      let line: Line
      if plain.isEmpty {
        line = .blank
      } else if plain.count >= 8, plain.allSatisfy({ "─━═╌┄┈-_".contains($0) }) {
        line = .rule
      } else {
        line = .text(raw)
      }
      if line == .blank, lines.last == .blank || lines.isEmpty { continue }
      lines.append(line)
    }
    return lines
  }
}

/// SGR escape sequences (ESC [ … m) to AttributedString runs; other escapes are dropped.
enum ANSIRenderer {
  struct Style: Equatable {
    var foreground: Color?
    var background: Color?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
  }

  static let defaultForeground = Color(red: 0.86, green: 0.88, blue: 0.92)

  /// The text without escape sequences.
  static func strip(_ text: String) -> String {
    String(String.UnicodeScalarView(render(text, styled: true).characters.flatMap(\.unicodeScalars)))
  }

  static func render(_ text: String, styled: Bool) -> AttributedString {
    guard styled else {
      var plain = AttributedString(text)
      plain.foregroundColor = defaultForeground
      return plain
    }
    var result = AttributedString()
    var style = Style()
    var run = ""
    func flush() {
      guard !run.isEmpty else { return }
      var piece = AttributedString(run)
      apply(style, to: &piece)
      result += piece
      run = ""
    }
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
      let c = scalars[i]
      guard c == "\u{1B}" else {
        run.unicodeScalars.append(c)
        i += 1
        continue
      }
      flush()
      guard i + 1 < scalars.count else { break }
      if scalars[i + 1] == "[" {
        // CSI: parameters, then a final byte in @…~.
        var j = i + 2
        var parameters = ""
        while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
          parameters.unicodeScalars.append(scalars[j])
          j += 1
        }
        if j < scalars.count, scalars[j] == "m" { update(&style, with: parameters) }
        i = j + 1
      } else if scalars[i + 1] == "]" {
        // OSC: up to BEL or ESC \.
        var j = i + 2
        while j < scalars.count, scalars[j] != "\u{07}", scalars[j] != "\u{1B}" { j += 1 }
        i = j < scalars.count && scalars[j] == "\u{1B}" ? j + 2 : j + 1
      } else {
        i += 2
      }
    }
    flush()
    return result
  }

  static func apply(_ style: Style, to piece: inout AttributedString) {
    var foreground = style.foreground ?? defaultForeground
    var background = style.background
    if style.inverse {
      let swapped = background ?? TerminalView.background
      background = foreground
      foreground = swapped
    }
    piece.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground
    if let background { piece.backgroundColor = background }
    if style.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
    if style.italic {
      piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.emphasized)
    }
    if style.underline { piece.underlineStyle = .single }
  }

  static func update(_ style: inout Style, with parameters: String) {
    var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    if codes.isEmpty { codes = [0] }
    var k = 0
    while k < codes.count {
      let code = codes[k]
      switch code {
      case 0: style = Style()
      case 1: style.bold = true
      case 2: style.dim = true
      case 3: style.italic = true
      case 4: style.underline = true
      case 7: style.inverse = true
      case 22: style.bold = false; style.dim = false
      case 23: style.italic = false
      case 24: style.underline = false
      case 27: style.inverse = false
      case 30...37: style.foreground = palette[code - 30]
      case 90...97: style.foreground = palette[code - 90 + 8]
      case 39: style.foreground = nil
      case 40...47: style.background = palette[code - 40]
      case 100...107: style.background = palette[code - 100 + 8]
      case 49: style.background = nil
      case 38, 48:
        // 38;5;n (256 colors) or 38;2;r;g;b (true color).
        var color: Color?
        if k + 2 < codes.count, codes[k + 1] == 5 {
          color = xterm(codes[k + 2])
          k += 2
        } else if k + 4 < codes.count, codes[k + 1] == 2 {
          color = Color(
            red: Double(codes[k + 2]) / 255, green: Double(codes[k + 3]) / 255, blue: Double(codes[k + 4]) / 255)
          k += 4
        }
        if code == 38 { style.foreground = color } else { style.background = color }
      default: break
      }
      k += 1
    }
  }

  /// The 16 base colors, tuned for the dark background.
  static let palette: [Color] = [
    0x1B2030, 0xFF5F6D, 0x30D158, 0xFFD60A, 0x4C8DFF, 0xBF5AF2, 0x40C8E0, 0xC7CCD6,
    0x6E7687, 0xFF7B85, 0x5EE07F, 0xFFE45C, 0x7AA8FF, 0xD48CF7, 0x70DCEC, 0xFFFFFF,
  ].map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }

  static func xterm(_ n: Int) -> Color {
    switch n {
    case 0..<16: return palette[n]
    case 16..<232:
      let v = n - 16
      func level(_ x: Int) -> Double { x == 0 ? 0 : Double(55 + x * 40) / 255 }
      return Color(red: level(v / 36), green: level(v / 6 % 6), blue: level(v % 6))
    case 232..<256:
      let gray = Double(8 + (n - 232) * 10) / 255
      return Color(red: gray, green: gray, blue: gray)
    default: return defaultForeground
    }
  }
}
