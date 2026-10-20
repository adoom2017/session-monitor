import AppKit
import SwiftUI

/// Design tokens of the "midnight liquid glass" style (see docs/DESIGN.md): Apple SF system
/// colors, translucent surfaces with a hairline border and a top highlight, pill buttons.
/// Everything follows the system appearance: dark uses the SF colors on a deep navy canvas,
/// light their high-contrast variants on a frosted white one.
enum Theme {
  // MARK: Colors
  static let blue = dynamic(light: 0x0066CC, dark: 0x0A84FF)
  static let green = dynamic(light: 0x248A3D, dark: 0x30D158)
  static let orange = dynamic(light: 0xD25F00, dark: 0xFF9F0A)
  static let yellow = dynamic(light: 0xB88A00, dark: 0xFFD60A)
  static let pink = dynamic(light: 0xD30F45, dark: 0xFF375F)
  static let cyan = dynamic(light: 0x0071A4, dark: 0x64D2FF)
  static let indigo = dynamic(light: 0x3634A3, dark: 0x7A78EA)
  static let teal = dynamic(light: 0x007D8F, dark: 0x40C8E0)
  static let purple = dynamic(light: 0x8944AB, dark: 0xBF5AF2)
  static let idle = dynamic(light: 0x6E7687, dark: 0x798398)

  /// Tint laid over the material, and the solid raised surface (tip bar, reduced transparency).
  static let canvas = dynamic(light: 0xF7F9FC, dark: 0x090C15)
  static let canvasRaised = dynamic(light: 0xFFFFFF, dark: 0x0F1422)
  static let separator = Color.primary.opacity(0.08)
  static let textSecondary = dynamic(light: 0x5B6475, dark: 0x98A2B3)

  // MARK: Glass
  static let border = Color.primary.opacity(0.12)
  static let borderHover = Color.primary.opacity(0.24)
  static let fill = Color.primary.opacity(0.06)
  static let fillHover = Color.primary.opacity(0.13)
  /// 1px top reflection (CSS `inset 0 1px 1px rgba(255,255,255,.22)`).
  static func highlight(_ opacity: Double = 0.25) -> LinearGradient {
    LinearGradient(
      colors: [.white.opacity(opacity), .white.opacity(0)], startPoint: .top, endPoint: .center)
  }

  // MARK: Shape and motion
  static let radiusSmall: CGFloat = 8
  static let radiusMedium: CGFloat = 12
  static let radiusLarge: CGFloat = 16
  /// cubic-bezier(0.16, 1, 0.3, 1): fast out, soft landing.
  static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.25)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
      })
  }
}

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}

extension Color {
  init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - Buttons

/// Pill button. `.primary` is a filled gradient with a colored glow (one per view: the main
/// action); `.glass` is translucent with a hairline border (everything else); `.destructive` is
/// glass with pink text.
struct PillButtonStyle: ButtonStyle {
  enum Kind { case primary, glass, destructive }
  var kind: Kind = .glass
  var tint: Color = Theme.blue
  var compact = false

  /// Same heights as macOS regular / small controls, so pills line up with switches and pickers.
  static let height: CGFloat = 22
  static let compactHeight: CGFloat = 20

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, kind: kind, tint: tint, compact: compact)
  }

  private struct PillBody: View {
    let configuration: Configuration
    let kind: Kind
    let tint: Color
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var lifted: Bool { hovering && isEnabled && !configuration.isPressed }

    var body: some View {
      configuration.label
        .font(.system(size: compact ? 11 : 12, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, compact ? 9 : 12)
        .frame(minWidth: compact ? 0 : 56)
        .frame(height: compact ? PillButtonStyle.compactHeight : PillButtonStyle.height)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .overlay(Capsule().strokeBorder(Theme.highlight(kind == .primary ? 0.4 : 0.22), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(
          color: kind == .primary && isEnabled ? tint.opacity(lifted ? 0.55 : 0.35) : .clear,
          radius: lifted ? 6 : 3, y: lifted ? 3 : 1.5)
        .scaleEffect(configuration.isPressed ? 0.97 : (lifted && kind == .primary ? 1.02 : 1))
        .offset(y: lifted ? -1 : 0)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .background(HoverReporter { hovering = $0 })
        .animation(Theme.motion, value: lifted)
        .animation(Theme.motion, value: configuration.isPressed)
    }

    private var foreground: Color {
      switch kind {
      case .primary: .white
      case .glass: .primary
      case .destructive: Theme.pink
      }
    }

    @ViewBuilder private var background: some View {
      if kind == .primary {
        Capsule().fill(tint)
          .overlay(Capsule().fill(LinearGradient(
            colors: [.clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom)))
      } else {
        Capsule().fill(lifted || configuration.isPressed ? Theme.fillHover : Theme.fill)
      }
    }

    private var border: Color {
      switch kind {
      case .primary: .white.opacity(0.25)
      case .glass: lifted ? Theme.borderHover : Theme.border
      case .destructive: lifted ? Theme.pink.opacity(0.5) : Theme.border
      }
    }
  }
}

/// Round glass button for a single symbol (expand / collapse).
struct GlassCircleButtonStyle: ButtonStyle {
  var size: CGFloat = 26

  func makeBody(configuration: Configuration) -> some View {
    CircleBody(configuration: configuration, size: size)
  }

  private struct CircleBody: View {
    let configuration: Configuration
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 11, weight: .bold))
        .frame(width: size, height: size)
        .background(Circle().fill(hovering || configuration.isPressed ? Theme.fillHover : Theme.fill))
        .overlay(Circle().strokeBorder(hovering ? Theme.borderHover : Theme.border, lineWidth: 1))
        .overlay(Circle().strokeBorder(Theme.highlight(), lineWidth: 1))
        .clipShape(Circle())
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .contentShape(Circle())
        .background(HoverReporter { hovering = $0 })
        .animation(Theme.motion, value: hovering)
        .animation(Theme.motion, value: configuration.isPressed)
    }
  }
}

extension ButtonStyle where Self == PillButtonStyle {
  static var glassPill: PillButtonStyle { PillButtonStyle() }
  static var glassPillCompact: PillButtonStyle { PillButtonStyle(compact: true) }
  static func primaryPill(_ tint: Color = Theme.blue) -> PillButtonStyle {
    PillButtonStyle(kind: .primary, tint: tint)
  }
  static var destructivePill: PillButtonStyle { PillButtonStyle(kind: .destructive) }
}

// MARK: - Tags and surfaces

/// Tinted capsule label (CSS: 12% fill, 30% border, colored text).
struct Tag: View {
  let text: String
  var symbol: String?
  let color: Color

  var body: some View {
    Group {
      if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
    }
    .font(.caption2.weight(.semibold))
    .padding(.horizontal, 6).padding(.vertical, 1)
    .foregroundStyle(color)
    .background(Capsule().fill(color.opacity(0.14)))
    .overlay(Capsule().strokeBorder(color.opacity(0.32), lineWidth: 0.75))
    .fixedSize()
  }
}

/// Status dot with the soft glow of the site's live indicator.
struct GlowDot: View {
  let color: Color
  var size: CGFloat = 9
  var body: some View {
    Circle().fill(color).frame(width: size, height: size)
      .shadow(color: color.opacity(0.8), radius: size * 0.55)
  }
}

extension View {
  /// Translucent glass surface: material + canvas tint + faint blue/purple ambient light,
  /// hairline border and top highlight. Adapts to light and dark.
  func glassSurface(cornerRadius: CGFloat, reduceTransparency: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return background {
      if reduceTransparency {
        shape.fill(Theme.canvasRaised)
      } else {
        ZStack {
          shape.fill(.ultraThinMaterial)
          shape.fill(Theme.canvas.opacity(0.55))
          shape.fill(
            RadialGradient(
              colors: [Theme.blue.opacity(0.13), Theme.purple.opacity(0.06), .clear],
              center: .topLeading, startRadius: 0, endRadius: 260))
        }
      }
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
    .overlay(shape.strokeBorder(Theme.highlight(), lineWidth: 1))
  }
}
