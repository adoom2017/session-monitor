import AppKit
import SMCore
import SwiftUI

@MainActor @Observable final class PanelPreferences {
  var expanded: Bool { didSet { UserDefaults.standard.set(expanded, forKey: "panelExpanded") } }
  /// Tip of the row under the mouse, shown in the panel's tip bar (tooltips never appear in this
  /// non-activating panel, so hover tips are drawn by the panel itself).
  var hoverTip: (owner: String, text: String)?
  init() { expanded = UserDefaults.standard.object(forKey: "panelExpanded") as? Bool ?? true }

  func hover(_ owner: String, tip: String?) {
    if let tip {
      hoverTip = (owner, tip)
    } else if hoverTip?.owner == owner {
      hoverTip = nil  // only the row that set it may clear it (exit/enter order is not guaranteed)
    }
  }
}

/// Mouse enter/exit that works while the app is inactive and the panel is not key: SwiftUI's
/// hover and `.help` tooltips depend on an active window, which this panel never is. The view
/// never takes clicks (hitTest → nil).
struct HoverReporter: NSViewRepresentable {
  let onChange: (Bool) -> Void
  func makeNSView(context: Context) -> TrackingView { TrackingView(onChange: onChange) }
  func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

  final class TrackingView: NSView {
    var onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
  }
}

/// Amber marker for sessions outside tmux; the explanation appears in the tip bar on hover.
struct OutsideTmuxBadge: View {
  var body: some View {
    Label("非 tmux", systemImage: "lightbulb.fill")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 1)
      .foregroundStyle(Color.orange)
      .background(Capsule().fill(Color.orange.opacity(0.16)))
      .fixedSize()
      .accessibilityLabel("提示：未在 tmux 中运行")
  }
}

struct TipBar: View {
  let text: String
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
      Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Solid, not a material: the rows underneath must not show through the text.
    .background(
      RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45)))
    .padding(8)
    .allowsHitTesting(false)
  }
}

extension Session {
  var stateLabel: String {
    switch state {
    case .working: "工作中"
    case .needsPermission: "需要授权"
    case .needsInput: "等待输入"
    case .done where unread: "已完成"
    case .done, .idle: "空闲"
    case .ended: "已结束"
    case .unknown: "未知状态：\(rawStatus ?? "unknown")"
    }
  }
  var stateColor: Color {
    switch state {
    case .needsPermission: .orange
    case .needsInput: .yellow
    case .done where unread: .blue
    case .working: .green
    default: .gray
    }
  }
  var detail: String {
    switch state {
    case .working: currentTool ?? "正在处理"
    case .needsPermission, .needsInput: attentionMessage ?? stateLabel
    case .done:
      if runningSubagents > 0 {
        "已完成（后台子代理 \(runningSubagents) 个运行中）"
      } else {
        "\(stateLabel)：\(lastAssistantSnippet ?? "")"
      }
    default: stateLabel
    }
  }
}

extension Session {
  /// A terminal session without a tmux pane: jumps rely on tty/directory matching, and closing
  /// its tab ends it for good. Codex desktop threads are not terminal sessions.
  var outsideTmux: Bool {
    state != .ended && terminal.tmuxPane == nil
      && terminal.termProgram != CodexSource.desktopProgram
  }

  /// Notes shown in the tip bar when hovering this row.
  func tips(hooksInstalled: Bool?) -> String {
    var notes: [String] = []
    if source == .sessionFileOnly {
      notes.append(
        hooksInstalled == true
          ? "hook 已安装；这个会话自 SessionMonitor 启动后还没有新事件，暂按会话文件显示忙/闲，下一次活动后改由 hook 驱动。"
          : "未接入 hook：仅根据会话文件显示忙/闲，无法判断权限等待。")
    }
    if source == .processScan {
      notes.append("从运行中的 Codex 进程发现，尚未收到它的 hook 事件；忙/闲来自 Codex 会话记录。")
    }
    if state == .needsPermission { notes.append("若已在终端拒绝权限，状态会在下一次输入后更新。") }
    if outsideTmux { notes.append(Self.outsideTmuxTip) }
    return notes.joined(separator: "\n")
  }

  static let outsideTmuxTip =
    "未在 tmux 中运行：跳转只能按终端/目录匹配，可能不精确；关闭这个标签页或窗口后会话就结束了，"
    + "无法像 tmux 那样重新打开（tmux 会话关掉标签页后仍在后台，可新开标签页接回）。建议用 tmux 启动。"
}

extension Session {
  /// Shape encodes state as well as color, so states stay distinguishable at a glance.
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
}

struct StateDot: View {
  let session: Session
  var size: CGFloat = 20
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false
  private var animated: Bool {
    !reduceMotion && [.working, .needsPermission].contains(session.state)
  }
  var body: some View {
    Image(systemName: session.stateSymbol)
      .font(.system(size: size, weight: .semibold))
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, session.stateColor)
      .frame(width: size + 2, height: size + 2)
      .opacity(session.state == .ended ? 0.45 : (animated && pulse ? 0.5 : 1))
      .animation(
        animated ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : nil, value: pulse
      )
      .onAppear { pulse = animated }
      .onChange(of: animated) { _, enabled in pulse = enabled }
      .accessibilityHidden(true)
  }
}

/// Distinguishes Claude and Codex sessions in a mixed list.
struct AgentBadge: View {
  let kind: AgentKind
  var body: some View {
    let codex = kind == .codex
    Text(codex ? "Codex" : "Claude")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 5).padding(.vertical, 1)
      .foregroundStyle(codex ? Color.teal : Color.brown)
      .background(Capsule().fill((codex ? Color.teal : Color.brown).opacity(0.15)))
      .fixedSize()
  }
}

struct SessionRow: View {
  let session: Session
  let now: Date
  let store: SessionStore
  let jump: (Session) -> Void
  let copy: (String) -> Void
  let preferences: PanelPreferences
  @State private var shake = 0.0
  static let height: CGFloat = 58

  private var rowHelp: String { session.tips(hooksInstalled: store.claudeHooksInstalled) }



  private var duration: String {
    let minutes = max(0, Int(now.timeIntervalSince(session.stateSince) / 60))
    if minutes == 0 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h\(minutes % 60)m"
  }

  var body: some View {
    Button {
      jump(session)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        StateDot(session: session).padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(session.displayName).font(.system(.body, design: .default, weight: .semibold))
              .lineLimit(1)
            AgentBadge(kind: session.kind)
            if session.outsideTmux { OutsideTmuxBadge() }
            Spacer(minLength: 6)
            Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
          Text("\(session.projectName) · \(session.detail)").font(.caption).foregroundStyle(
            .secondary
          ).lineLimit(1)
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .frame(height: SessionRow.height)
      .background(
        HoverReporter { hovering in
          preferences.hover(session.id, tip: hovering && !rowHelp.isEmpty ? rowHelp : nil)
        })
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(RowShake(progress: shake))
    .onChange(of: store.jumpFailureToken) { _, _ in
      if store.failedJump == session.id { withAnimation(.linear(duration: 0.35)) { shake += 1 } }
    }
    .contextMenu {
      Button("跳转") { jump(session) }
      Button("标为已读") { store.markRead(session.id) }
      Button("复制 cwd") { if let cwd = session.cwd { copy(cwd) } }.disabled(session.cwd == nil)
      Button("复制 session id") { copy(session.currentSessionId) }
      Divider()
      Button("从列表移除", role: .destructive) { store.remove(session.id) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(session.displayName)，\(session.stateLabel)，\(session.detail)，\(duration)"
    )
    .accessibilityHint("跳转到此会话")
  }
}

private struct RowShake: GeometryEffect {
  var progress: Double
  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }
  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: 5 * sin(progress * .pi * 8), y: 0))
  }
}

extension SessionStore {
  /// Collapsed-capsule groups, in priority order. Shared with PanelController for sizing.
  var capsuleCounts: [(String, Int, Color)] {
    let sessions = self.sessions
    return [
      (
        "需要介入", sessions.filter { [.needsPermission, .needsInput].contains($0.state) }.count,
        .orange
      ),
      ("完成未读", sessions.filter { $0.state == .done && $0.unread }.count, .blue),
      ("工作中", sessions.filter { $0.state == .working }.count, .green),
      (
        "空闲",
        sessions.filter {
          $0.state == .idle || $0.state == .unknown || ($0.state == .done && !$0.unread)
        }.count, .gray
      ),
    ]
  }
}

struct PanelContent: View {
  let store: SessionStore
  @Bindable var preferences: PanelPreferences
  let resize: () -> Void
  let jump: (Session) -> Void
  let copy: (String) -> Void
  let showLog: () -> Void
  let openSettings: () -> Void
  /// Expands unless the press ended a drag of the panel.
  let expand: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var counts: [(String, Int, Color)] { store.capsuleCounts }

  /// Only when the hooks are really missing; quiet sessions after a restart are expected.
  private var fileOnlyCount: Int {
    guard store.claudeHooksInstalled == false else { return 0 }
    return store.sessions.filter { $0.source == .sessionFileOnly }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      if preferences.expanded {
        HStack {
          Text("Sessions").font(.headline)
          Spacer()
          Button("全部已读") { store.markAllRead() }.font(.caption)
          Button {
            preferences.expanded = false
          } label: {
            Image(systemName: "chevron.up").accessibilityLabel("收起")
          }
        }.buttonStyle(.plain).padding(14)
        if fileOnlyCount > 0 {
          Button(action: openSettings) {
            Label("Claude hook 未安装：\(fileOnlyCount) 个会话仅显示忙/闲 · 点此安装", systemImage: "info.circle")
              .font(.caption2).foregroundStyle(.orange).lineLimit(1)
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 14).padding(.bottom, 8)
        }
        Divider().padding(.horizontal, 12)
        if store.sessions.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.secondary)
            Text("暂无会话").font(.body)
            Text("安装 hook 后，新的会话事件会显示在这里。")
              .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.frame(maxWidth: .infinity).padding(24)
        } else {
          TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(store.sessions) { session in
                  SessionRow(
                    session: session, now: timeline.date, store: store, jump: jump, copy: copy,
                    preferences: preferences)
                }
              }
            }.frame(maxHeight: 8 * SessionRow.height)
          }
        }
        if let error = store.lastError {
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            Label("发生错误", systemImage: "exclamationmark.triangle.fill").font(.caption.bold())
              .foregroundStyle(.red)
            Text(error).font(.caption2).lineLimit(3).textSelection(.disabled)
            HStack {
              Button("查看日志", action: showLog)
              Spacer()
              Button("关闭提示") { store.clearError() }
            }.font(.caption2).buttonStyle(.plain)
          }.padding(12)
        }
      } else {
        // Not a button: dragging the capsule only moves the panel. Only the chevron expands it.
        HStack(spacing: 12) {
          if store.lastError != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          }
          ForEach(counts.indices, id: \.self) { index in
            if counts[index].1 > 0 {
              HStack(spacing: 5) {
                Circle().fill(counts[index].2).frame(width: 11, height: 11)
                Text("\(counts[index].1)").font(.body.weight(.semibold)).monospacedDigit()
                  .lineLimit(1).fixedSize()
              }.accessibilityLabel("\(counts[index].0) \(counts[index].1)")
            }
          }
          if counts.allSatisfy({ $0.1 == 0 }) { Text("—").foregroundStyle(.secondary) }
          Button(action: expand) {
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
              .frame(width: 26, height: 26)
              .background(Circle().fill(.primary.opacity(0.08)))
              .contentShape(Circle())
          }.buttonStyle(.plain).help("展开").accessibilityLabel("展开会话列表")
        }.padding(.leading, 16).padding(.trailing, 6).frame(height: 36)
          .fixedSize()  // the capsule is exactly as wide as its content (PanelController measures it)
      }
    }
    .overlay(alignment: .bottom) {
      if preferences.expanded, let tip = preferences.hoverTip {
        TipBar(text: tip.text).transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.12), value: preferences.hoverTip?.text)
    .frame(width: preferences.expanded ? 360 : nil)
    .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.ultraThinMaterial))
    .clipShape(.rect(cornerRadius: preferences.expanded ? 12 : 18))
    .overlay(
      RoundedRectangle(cornerRadius: preferences.expanded ? 12 : 18).strokeBorder(
        .primary.opacity(0.12))
    )
    .onChange(of: preferences.expanded) { resize() }
    .onChange(of: store.sessions.count) { resize() }
    .onChange(of: store.lastError) { resize() }
    .onChange(of: store.capsuleCounts.map(\.1)) { resize() }
    .onChange(of: fileOnlyCount > 0) { resize() }
  }
}
