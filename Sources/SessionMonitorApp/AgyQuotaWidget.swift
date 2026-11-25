import AppKit
import SMCore
import SwiftUI

@MainActor @Observable final class AgyQuotaWidgetPreferences {
  var visible: Bool {
    didSet { UserDefaults.standard.set(visible, forKey: "agyQuotaWidget.visible") }
  }
  var pinnedToDesktop: Bool {
    didSet { UserDefaults.standard.set(pinnedToDesktop, forKey: "agyQuotaWidget.pinnedToDesktop") }
  }
  var compact: Bool {
    didSet { UserDefaults.standard.set(compact, forKey: "agyQuotaWidget.compact") }
  }
  var hoverTip: (owner: String, text: String)?

  init() {
    visible = UserDefaults.standard.object(forKey: "agyQuotaWidget.visible") as? Bool ?? true
    pinnedToDesktop = UserDefaults.standard.bool(forKey: "agyQuotaWidget.pinnedToDesktop")
    compact = UserDefaults.standard.bool(forKey: "agyQuotaWidget.compact")
  }

  func hover(_ owner: String, tip: String?) {
    if let tip {
      hoverTip = (owner, tip)
    } else if hoverTip?.owner == owner {
      hoverTip = nil
    }
  }
}

struct AgyQuotaWidgetView: View {
  let state: AgyQuotaState
  @Bindable var preferences: AgyQuotaWidgetPreferences
  let refresh: () -> Void
  let resize: () -> Void
  let toggleLevel: () -> Void
  let hide: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let cardWidth: CGFloat = 272

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { timeline in
      Group {
        if preferences.compact {
          compactBody(now: timeline.date)
        } else {
          cardBody(now: timeline.date)
        }
      }
    }
    .overlay(alignment: .bottom) {
      if !preferences.compact, let tip = preferences.hoverTip {
        TipBar(text: tip.text, symbol: "info.circle.fill").transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.12), value: preferences.hoverTip?.text)
    .frame(width: preferences.compact ? nil : Self.cardWidth)
    .glassSurface(
      cornerRadius: preferences.compact ? 18 : Theme.radiusLarge,
      reduceTransparency: reduceTransparency)
    .contextMenu {
      Button("刷新额度", action: refresh)
      Button(preferences.compact ? "展开卡片" : "切换紧凑模式") {
        preferences.compact.toggle()
      }
      Button(preferences.pinnedToDesktop ? "置顶悬浮" : "贴在桌面", action: toggleLevel)
      Divider()
      Button("隐藏小组件", action: hide)
    }
    .onChange(of: preferences.compact) { resize() }
    .onChange(of: state.snapshot) { resize() }
    .onChange(of: state.lastError) { resize() }
    .onChange(of: state.refreshing) { resize() }
  }

  private func cardBody(now: Date) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        GlowDot(color: Theme.green, size: 8)
        Text("Antigravity 额度").font(.subheadline.weight(.semibold)).lineLimit(1)
        if let tier = state.snapshot?.planTier {
          Tag(text: tier, color: Theme.green)
        }
        Spacer(minLength: 4)
        HStack(spacing: 4) {
          headerButton(
            systemName: preferences.pinnedToDesktop ? "pin.slash" : "pin.fill",
            label: preferences.pinnedToDesktop ? "置顶悬浮" : "贴在桌面",
            tipID: "pin",
            tipText: preferences.pinnedToDesktop ? "当前贴在桌面，点击切换为置顶悬浮" : "当前置顶悬浮，点击贴在桌面背景上",
            action: toggleLevel)
          Button(action: refresh) {
            if state.refreshing {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "arrow.clockwise").accessibilityLabel("刷新额度")
            }
          }
          .buttonStyle(GlassCircleButtonStyle(size: 22))
          .disabled(state.refreshing)
          .background(
            HoverReporter { inside in
              preferences.hover("refresh", tip: inside ? "立即刷新 Antigravity 额度" : nil)
            })
          headerButton(
            systemName: "rectangle.compress.vertical",
            label: "紧凑模式",
            tipID: "compact",
            tipText: "收起为紧凑胶囊",
            action: { preferences.compact = true })
          headerButton(
            systemName: "xmark",
            label: "隐藏小组件",
            tipID: "close",
            tipText: "隐藏小组件（可在菜单栏或设置中重新开启）",
            action: hide)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)

      Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 10)

      if let snapshot = state.snapshot, !snapshot.activeBuckets.isEmpty {
        VStack(spacing: 10) {
          ForEach(snapshot.activeBuckets) { bucket in
            bucketRow(bucket, now: now)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
      } else {
        VStack(spacing: 8) {
          if state.refreshing {
            ProgressView().controlSize(.small)
            Text("正在获取额度…").font(.caption).foregroundStyle(Theme.textSecondary)
          } else {
            Text("暂无额度数据").font(.caption.weight(.medium))
            Text("点刷新获取，或打开 agy 自动同步")
              .font(.caption2).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("获取额度", action: refresh).buttonStyle(.glassPillCompact)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 16)
      }

      if let error = state.lastError {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 10)
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2).foregroundStyle(Theme.pink)
          Text(error).font(.caption2).foregroundStyle(Theme.pink).lineLimit(2)
          Spacer(minLength: 4)
          Button("重试", action: refresh).buttonStyle(.glassPillCompact)
            .disabled(state.refreshing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
      }

      Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 10)
      HStack {
        if let updated = state.snapshot?.updatedAt {
          Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))")
        } else {
          Text("等待同步")
        }
        Spacer()
        Text(preferences.pinnedToDesktop ? "贴桌面" : "置顶")
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(Theme.textSecondary)
      .padding(.horizontal, 12).padding(.vertical, 7)
    }
  }

  private func headerButton(
    systemName: String, label: String, tipID: String, tipText: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName).accessibilityLabel(label)
    }
    .buttonStyle(GlassCircleButtonStyle(size: 22))
    .background(
      HoverReporter { inside in
        preferences.hover(tipID, tip: inside ? tipText : nil)
      })
  }

  private func bucketRow(_ bucket: AgyQuotaBucket, now: Date) -> some View {
    let fraction = bucket.remainingFraction ?? 0
    let tint = healthColor(fraction: bucket.remainingFraction)
    let valueTint: Color = (bucket.remainingFraction ?? 1) < 0.50 ? tint : .primary
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(bucket.displayName).font(.caption.weight(.medium)).lineLimit(1)
        Spacer(minLength: 4)
        Text(bucket.valueText)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(valueTint)
      }
      HStack(spacing: 8) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(Theme.fill)
            Capsule().fill(tint)
              .frame(width: max(fraction > 0 ? 4 : 0, geometry.size.width * min(1, max(0, fraction))))
          }
        }
        .frame(height: 5)
        Text(bucket.resetText(now: now))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(Theme.textSecondary)
          .fixedSize()
      }
    }
  }

  private func compactBody(now: Date) -> some View {
    let primary = primaryBuckets(from: state.snapshot?.activeBuckets ?? [])
    return HStack(spacing: 10) {
      HStack(spacing: 5) {
        GlowDot(color: Theme.green, size: 8)
        Text("AGY").font(.caption.weight(.semibold))
      }
      if primary.isEmpty {
        Text(state.refreshing ? "…" : "—")
          .font(.caption.monospacedDigit())
          .foregroundStyle(Theme.textSecondary)
      } else {
        ForEach(primary) { bucket in
          let reset = bucket.compactResetText(now: now)
          HStack(spacing: 4) {
            Text(bucket.shortName).foregroundStyle(Theme.textSecondary)
            Text(bucket.valueText)
              .fontWeight(.semibold)
              .foregroundStyle(
                (bucket.remainingFraction ?? 1) < 0.50
                  ? healthColor(fraction: bucket.remainingFraction) : .primary)
            if !reset.isEmpty {
              Text(reset).foregroundStyle(Theme.textSecondary)
            }
          }
          .font(.caption.monospacedDigit())
          .lineLimit(1).fixedSize()
        }
      }
      if state.refreshing {
        ProgressView().controlSize(.mini)
      }
      Button {
        preferences.compact = false
      } label: {
        Image(systemName: "chevron.down").accessibilityLabel("展开额度卡片")
      }
      .buttonStyle(GlassCircleButtonStyle(size: 24))
    }
    .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
    .fixedSize()
  }

  private func primaryBuckets(from buckets: [AgyQuotaBucket]) -> [AgyQuotaBucket] {
    let preferred = ["gemini-5h", "gemini-weekly"].compactMap { id in
      buckets.first { $0.id == id }
    }
    return preferred.isEmpty ? Array(buckets.prefix(2)) : preferred
  }

  private func healthColor(fraction: Double?) -> Color {
    guard let fraction else { return Theme.textSecondary }
    if fraction > 0.50 { return Theme.green }
    if fraction >= 0.20 { return Theme.orange }
    return Theme.pink
  }
}

private final class QuotaWidgetPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class QuotaHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AgyQuotaWidgetController: NSObject, NSWindowDelegate {
  let panel: NSPanel
  let preferences = AgyQuotaWidgetPreferences()
  private let state: AgyQuotaState
  private let refreshAction: () -> Void
  private var pressMonitor: Any?
  private var pressEvent: NSEvent?
  private var dragged = false
  private static let dragThreshold: CGFloat = 4
  private static let originKey = "agyQuotaWidget.origin"

  init(state: AgyQuotaState, refresh: @escaping () -> Void) {
    self.state = state
    self.refreshAction = refresh
    panel = QuotaWidgetPanel(
      contentRect: NSRect(x: 0, y: 0, width: 272, height: 220),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    super.init()
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.title = "Antigravity 额度"
    panel.contentView = QuotaHostingView(
      rootView: AgyQuotaWidgetView(
        state: state,
        preferences: preferences,
        refresh: refresh,
        resize: { [weak self] in self?.resize() },
        toggleLevel: { [weak self] in self?.preferences.pinnedToDesktop.toggle() },
        hide: { [weak self] in self?.preferences.visible = false }))
    applyWindowLevel()
    resize()
    if let origin = UserDefaults.standard.string(forKey: Self.originKey) {
      panel.setFrameOrigin(NSPointFromString(origin))
    } else if let screen = NSScreen.main {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - panel.frame.width - 20,
          y: screen.visibleFrame.maxY - panel.frame.height - 76))
    }
    ensureVisible()
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    pressMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.handlePress(event) ?? false }
      return consumed ? nil : event
    }
    observePreferences()
  }

  private func observePreferences() {
    withObservationTracking {
      _ = preferences.visible
      _ = preferences.pinnedToDesktop
      _ = preferences.compact
      applyWindowLevel()
      syncVisibility()
      resize()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observePreferences() }
    }
  }

  private func handlePress(_ event: NSEvent) -> Bool {
    guard event.window === panel else { return false }
    if event.type == .leftMouseDown {
      dragged = false
      let hit = panel.contentView?.hitTest(
        panel.contentView?.convert(event.locationInWindow, from: nil) ?? .zero)
      pressEvent = hit is NSScroller ? nil : event
      return false
    }
    if event.type == .leftMouseUp {
      return false
    }
    guard !dragged, let down = pressEvent else { return false }
    let start = down.locationInWindow, now = event.locationInWindow
    guard hypot(now.x - start.x, now.y - start.y) > Self.dragThreshold else { return false }
    dragged = true
    panel.performDrag(with: down)
    return true
  }

  func applyWindowLevel() {
    if preferences.pinnedToDesktop {
      panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    } else {
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
  }

  func syncVisibility() {
    if preferences.visible {
      panel.orderFrontRegardless()
    } else {
      panel.orderOut(nil)
    }
  }

  func toggle() {
    preferences.visible.toggle()
  }

  func resize() {
    guard let content = panel.contentView else { return }
    content.layoutSubtreeIfNeeded()
    let fitting = content.fittingSize
    let width = max(80, ceil(fitting.width))
    let height = max(36, ceil(fitting.height))
    let top = panel.frame.maxY
    panel.setFrame(
      NSRect(x: panel.frame.minX, y: top - height, width: width, height: height),
      display: true)
    ensureVisible()
  }

  @objc private func screensChanged() { ensureVisible() }

  func ensureVisible() {
    let visible = NSScreen.screens.contains {
      $0.visibleFrame.intersection(panel.frame).width >= min(80, panel.frame.width)
        && $0.visibleFrame.intersection(panel.frame).height >= 24
    }
    if !visible, let screen = NSScreen.main ?? NSScreen.screens.first {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - panel.frame.width - 20,
          y: screen.visibleFrame.maxY - panel.frame.height - 76))
    }
  }

  func windowDidMove(_ notification: Notification) {
    UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
  }

  /// Debug aid (SM_SNAPSHOT_DIR): renders card and compact widget states to PNG.
  func writeSnapshots(to directory: URL) {
    let wasVisible = preferences.visible
    let wasCompact = preferences.compact
    preferences.visible = true
    for compact in [false, true] {
      preferences.compact = compact
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      resize()
      guard let view = panel.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { continue }
      view.cacheDisplay(in: view.bounds, to: rep)
      let name = compact ? "agy-quota-compact.png" : "agy-quota-card.png"
      try? rep.representation(using: .png, properties: [:])?.write(
        to: directory.appendingPathComponent(name))
    }
    preferences.compact = wasCompact
    preferences.visible = wasVisible
    syncVisibility()
    resize()
  }
}
