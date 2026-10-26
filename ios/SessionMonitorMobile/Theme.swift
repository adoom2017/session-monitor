import SMProtocol
import SwiftUI
import UIKit

enum AppInfo {
  /// The product name in the system language: 码哨 (Chinese) or Codewhistle.
  static var name: String {
    Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Codewhistle"
  }
}

/// The Mac app's tokens (docs/DESIGN.md), as dynamic colors for light and dark.
enum Theme {
  static let blue = dynamic(light: 0x0066CC, dark: 0x0A84FF)
  static let green = dynamic(light: 0x248A3D, dark: 0x30D158)
  static let orange = dynamic(light: 0xD25F00, dark: 0xFF9F0A)
  static let yellow = dynamic(light: 0xB88A00, dark: 0xFFD60A)
  static let pink = dynamic(light: 0xD30F45, dark: 0xFF375F)
  static let cyan = dynamic(light: 0x0071A4, dark: 0x64D2FF)
  static let indigo = dynamic(light: 0x3634A3, dark: 0x7A78EA)
  static let idle = dynamic(light: 0x6E7687, dark: 0x798398)
  /// Usage chart series, as on the Mac (validated for both modes and color blindness).
  static let chartClaude = dynamic(light: 0x5856D6, dark: 0x7A78EA)
  static let chartCodex = dynamic(light: 0x00897B, dark: 0x1F9E8F)
  static let textSecondary = dynamic(light: 0x5B6475, dark: 0x98A2B3)
  static let canvas = dynamic(light: 0xF7F9FC, dark: 0x090C15)
  static let raised = dynamic(light: 0xFFFFFF, dark: 0x111727)
  static let border = Color.primary.opacity(0.12)
  static let fill = Color.primary.opacity(0.06)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      uiColor: UIColor { traits in
        let hex = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      })
  }
}

extension RemoteSession {
  var stateLabel: String {
    switch state {
    case .working: "工作中"
    case .needsPermission: "需要授权"
    case .needsInput: "等待输入"
    case .done where unread: "已完成"
    case .done, .idle: "空闲"
    case .ended: "已结束"
    case .unknown: "未知状态"
    }
  }
  var stateColor: Color {
    switch state {
    case .needsPermission: Theme.orange
    case .needsInput: Theme.yellow
    case .done where unread: Theme.blue
    case .working: Theme.green
    default: Theme.idle
    }
  }
  var stateSymbol: String {
    switch state {
    case .needsPermission: "exclamationmark.circle.fill"
    case .needsInput: "questionmark.circle.fill"
    case .done where unread: "checkmark.circle.fill"
    case .done, .idle: "moon.circle.fill"
    case .working: "ellipsis.circle.fill"
    case .ended: "xmark.circle"
    case .unknown: "circle.dashed"
    }
  }
  var detail: String {
    switch state {
    case .working: currentTool ?? "正在处理"
    case .needsPermission, .needsInput: attentionMessage ?? stateLabel
    case .done: lastAssistantSnippet.map { "\(stateLabel)：\($0)" } ?? stateLabel
    default: stateLabel
    }
  }
  var agentLabel: String { agent == "codex" ? "Codex" : "Claude" }
  var agentColor: Color { agent == "codex" ? Theme.cyan : Theme.indigo }
}

/// Tinted capsule label, as on the Mac.
struct Tag: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 1.5)
      .foregroundStyle(color)
      .background(Capsule().fill(color.opacity(0.14)))
      .overlay(Capsule().strokeBorder(color.opacity(0.32), lineWidth: 0.75))
      .fixedSize()
  }
}

/// Short elapsed time ("3m", "1h5m"), like the Mac panel.
func elapsed(since date: Date, now: Date = Date()) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 60 { return "\(seconds)s" }
  let minutes = seconds / 60
  if minutes < 60 { return "\(minutes)m" }
  let hours = minutes / 60
  if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h\(minutes % 60)m" }
  return "\(hours / 24)d"
}
