import SMProtocol
import SwiftUI
import UIKit

/// The tmux pane. Reading mode (default) wraps lines to the phone width at a readable size and
/// draws rule lines (────) as dividers; layout mode keeps the pane's columns, scaling the font
/// to fit (scrolls sideways below the minimum size).
struct TerminalView: View {
  let pane: PaneSnapshot?
  @AppStorage("terminalLayoutMode") private var layoutMode = false
  nonisolated static let background = ANSIRenderer.backgroundRGB.color
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
        ForEach(Array(Self.readingLines(pane.text, columns: pane.columns).enumerated()), id: \.offset) { _, line in
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
  static func readingLines(_ text: String, columns: Int?) -> [Line] {
    var lines: [Line] = []
    for raw in PaneText.unwrap(text.components(separatedBy: "\n"), columns: columns) {
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

/// An sRGB color with the arithmetic needed for contrast checks.
struct RGB: Equatable {
  var r: Double, g: Double, b: Double

  init(_ r: Double, _ g: Double, _ b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }
  init(hex: UInt32) {
    self.init(Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
  }

  var color: Color { Color(red: r, green: g, blue: b) }

  /// WCAG relative luminance.
  var luminance: Double {
    func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
  }

  func contrast(with other: RGB) -> Double {
    let (a, b) = (luminance, other.luminance)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  func mixed(with other: RGB, _ amount: Double) -> RGB {
    RGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
  }

  /// This color moved toward white or black, whichever can stand out more from `background`,
  /// until it reaches `ratio`; hue is kept as far as the ratio allows. (Mid-bright backgrounds
  /// such as a powerline prompt's orange cannot reach 4.5:1 with white text.)
  func readable(on background: RGB, ratio: Double) -> RGB {
    guard contrast(with: background) < ratio else { return self }
    let white = RGB(1, 1, 1), black = RGB(0, 0, 0)
    let target = white.contrast(with: background) >= black.contrast(with: background) ? white : black
    var amount = 0.0
    var result = self
    while result.contrast(with: background) < ratio, amount < 1 {
      amount += 0.05
      result = mixed(with: target, amount)
    }
    return result
  }
}

/// SGR escape sequences (ESC [ … m) to AttributedString runs; other escapes are dropped.
/// Every run is made readable on its background: TUIs pick dark grays (and black) that vanish on
/// the dark terminal, especially with a light terminal theme.
enum ANSIRenderer {
  struct Style: Equatable {
    var foreground: RGB?
    var background: RGB?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
  }

  static let defaultForegroundRGB = RGB(0.86, 0.88, 0.92)
  static let defaultForeground = defaultForegroundRGB.color
  static let backgroundRGB = RGB(hex: 0x0F1422)
  /// Minimum contrast: normal text (WCAG AA) and dim text (still lighter, but legible).
  static let textContrast = 4.5
  static let dimContrast = 3.0

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

  /// The colors a run is drawn with: inverse applied, dim and contrast enforced.
  static func colors(for style: Style) -> (foreground: RGB, background: RGB?) {
    var foreground = style.foreground ?? defaultForegroundRGB
    var background = style.background
    if style.inverse {
      let swapped = background ?? backgroundRGB
      background = foreground
      foreground = swapped
    }
    let behind = background ?? backgroundRGB
    if style.dim { foreground = foreground.mixed(with: behind, 0.35) }
    return (foreground.readable(on: behind, ratio: style.dim ? dimContrast : textContrast), background)
  }

  static func apply(_ style: Style, to piece: inout AttributedString) {
    let (foreground, background) = colors(for: style)
    piece.foregroundColor = foreground.color
    if let background { piece.backgroundColor = background.color }
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
        var color: RGB?
        if k + 2 < codes.count, codes[k + 1] == 5 {
          color = xterm(codes[k + 2])
          k += 2
        } else if k + 4 < codes.count, codes[k + 1] == 2 {
          color = RGB(Double(codes[k + 2]) / 255, Double(codes[k + 3]) / 255, Double(codes[k + 4]) / 255)
          k += 4
        }
        if code == 38 { style.foreground = color } else { style.background = color }
      default: break
      }
      k += 1
    }
  }

  /// The 16 base colors, tuned for the dark background ("black" is a dark gray, so a black
  /// background block stays visible; black text is lifted by the contrast check).
  static let palette: [RGB] = [
    0x2A3042, 0xFF5F6D, 0x30D158, 0xFFD60A, 0x5B9BFF, 0xC77DF5, 0x40C8E0, 0xC7CCD6,
    0x8A93A6, 0xFF7B85, 0x5EE07F, 0xFFE45C, 0x8AB4FF, 0xD9A0F9, 0x70DCEC, 0xFFFFFF,
  ].map(RGB.init(hex:))

  static func xterm(_ n: Int) -> RGB {
    switch n {
    case 0..<16: return palette[n]
    case 16..<232:
      let v = n - 16
      func level(_ x: Int) -> Double { x == 0 ? 0 : Double(55 + x * 40) / 255 }
      return RGB(level(v / 36), level(v / 6 % 6), level(v % 6))
    case 232..<256:
      let gray = Double(8 + (n - 232) * 10) / 255
      return RGB(gray, gray, gray)
    default: return defaultForegroundRGB
    }
  }
}

/// Undoes the line breaks a TUI inserts at the terminal width (Claude Code wraps its own output
/// and indents the continuation), so text reflows on the phone.
enum PaneText {
  /// Display columns of a line (wide East Asian characters and emoji take two).
  static func width(_ line: String) -> Int {
    line.unicodeScalars.reduce(0) { total, scalar in
      let v = scalar.value
      let wide =
        (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
        || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
        || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
      return total + (wide ? 2 : 1)
    }
  }

  /// Joins each line that continues one filling the pane width. Styled lines keep their
  /// escapes; a joined continuation is added as plain text.
  static func unwrap(_ styled: [String], columns: Int?) -> [String] {
    guard let columns, columns > 20 else { return styled }
    var result: [String] = []
    var previousFull = false
    for line in styled {
      let plain = ANSIRenderer.strip(line)
      let trimmed = plain.trimmingCharacters(in: .whitespaces)
      let continues = previousFull && !trimmed.isEmpty && plain.hasPrefix(" ")
        && !trimmed.allSatisfy({ "─━═".contains($0) })
      if continues, let last = result.popLast() {
        result.append(last + "\u{1B}[0m" + trimmed)
      } else {
        result.append(line)
      }
      // Claude Code wraps a few columns short of the edge (its margin, plus a wide character
      // that does not fit leaves the last column empty).
      previousFull = width(plain.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) >= columns - 6
    }
    return result
  }
}

