import AppKit
import SMCore
import SwiftUI

private final class SessionPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
  let panel: NSPanel
  let preferences = PanelPreferences()
  private let store: SessionStore
  init(
    store: SessionStore, jump: @escaping (Session) -> Void, copy: @escaping (String) -> Void,
    showLog: @escaping () -> Void, openSettings: @escaping () -> Void
  ) {
    self.store = store
    panel = SessionPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    super.init()
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    // Not movable by background: AppKit would move the window on the slightest jitter of a click,
    // which then read as a drag and swallowed the click. Dragging is started by hand (pressMonitor).
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.title = "SessionMonitor"
    panel.contentView = PassiveHostingView(
      rootView: PanelContent(
        store: store, preferences: preferences, resize: { [weak self] in self?.resize() },
        jump: { [weak self] session in if self?.dragged == false { jump(session) } },
        copy: copy, showLog: showLog, openSettings: openSettings,
        expand: { [weak self] in self?.expandUnlessDragged() }))
    resize()
    if let origin = UserDefaults.standard.string(forKey: "panelOrigin") {
      panel.setFrameOrigin(NSPointFromString(origin))
    } else if let screen = NSScreen.main {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - panel.frame.width - 20,
          y: screen.visibleFrame.maxY - panel.frame.height - 20))
    }
    ensureVisible()
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    // The panel never takes keyboard focus (it must not steal typing), so "losing focus" means a
    // click anywhere outside it: global monitors only see events aimed at other apps.
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.collapseIfExpanded() }
    }
    pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
      [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.handlePress(event) ?? false }
      return consumed ? nil : event
    }
  }

  private var outsideClickMonitor: Any?
  private var pressMonitor: Any?
  /// The mouse-down of the current press on the panel (nil when it began on a scroller).
  private var pressEvent: NSEvent?
  /// The current press turned into a window drag; its mouse-up must not click what it lands on.
  private var dragged = false
  /// Pointer travel that turns a press into a drag; below it the press stays a click.
  private static let dragThreshold: CGFloat = 4

  /// Whether a point (window coordinates) is on the collapsed capsule's chevron, with 3pt slack.
  private func chevronHit(_ point: NSPoint) -> Bool {
    let right = panel.frame.width - PanelContent.chevronTrailing
    return point.x >= right - PanelContent.chevronSize - 3 && point.x <= right + 3
  }

  /// Returns true when the event started a window drag (and is consumed).
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
      // SwiftUI buttons in this never-key panel can miss a click while the app is inactive (the
      // press arrives, the action never fires), so the chevron's click is recognized here.
      if !dragged, !preferences.expanded, let down = pressEvent,
        chevronHit(down.locationInWindow), chevronHit(event.locationInWindow)
      {
        preferences.expanded = true
      }
      return false
    }
    guard !dragged, let down = pressEvent else { return false }
    let start = down.locationInWindow, now = event.locationInWindow
    guard hypot(now.x - start.x, now.y - start.y) > Self.dragThreshold else { return false }
    dragged = true
    panel.performDrag(with: down)
    return true
  }

  private func collapseIfExpanded() {
    if preferences.expanded { preferences.expanded = false }
  }

  /// A drag moves the window under the cursor, so the mouse-up that ends it lands on the chevron
  /// and would count as a click.
  func expandUnlessDragged() {
    if !dragged { preferences.expanded = true }
  }
  func show() { panel.orderFrontRegardless() }
  func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show() } }
  func resize() {
    let top = panel.frame.maxY
    let rows = CGFloat(max(1, min(8, store.sessions.count)))
    let hookHint: CGFloat =
      store.claudeHooksInstalled == false
        && store.sessions.contains { $0.source == .sessionFileOnly } ? 22 : 0
    let preferredHeight: CGFloat =
      preferences.expanded
      ? 50 + hookHint + (store.sessions.isEmpty ? 132 : rows * SessionRow.height)
        + (store.lastError == nil ? 0 : 120) : 36
    let height = min(
      preferredHeight, max(100, (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40)
    let width: CGFloat = preferences.expanded ? 360 : collapsedWidth()
    panel.setFrame(
      NSRect(x: panel.frame.minX, y: top - height, width: width, height: height), display: true)
    ensureVisible()
  }
  /// Measured from the SwiftUI content (fixed-size capsule), so numbers never wrap.
  private func collapsedWidth() -> CGFloat {
    guard let content = panel.contentView else { return 196 }
    content.layoutSubtreeIfNeeded()
    return max(80, ceil(content.fittingSize.width))
  }

  /// Debug aid: renders the panel itself (no screen-recording permission needed) to
  /// `<directory>/panel-collapsed.png` and `panel-expanded.png`. Enabled by SM_SNAPSHOT_DIR.
  func writeSnapshots(to directory: URL) {
    // The rows behind the pictures, for checking badges and terminal facts.
    let rows = store.sessions.map { s in
      "\(s.id)\tpid=\(s.pid.map(String.init) ?? "-")\tsid=\(s.currentSessionId)\t\(s.state)\t\(s.source)"
        + "\tcwd=\(s.cwd ?? "-")\toutsideTmux=\(s.outsideTmux)\t\(s.terminal)"
    }
    try? (rows.joined(separator: "\n") + "\n").write(
      to: directory.appendingPathComponent("sessions.txt"), atomically: true, encoding: .utf8)
    let wasExpanded = preferences.expanded
    for expanded in [false, true] {
      preferences.expanded = expanded
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))  // let SwiftUI and resize() settle
      resize()
      guard let view = panel.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { continue }
      view.cacheDisplay(in: view.bounds, to: rep)
      let name = expanded ? "panel-expanded.png" : "panel-collapsed.png"
      try? rep.representation(using: .png, properties: [:])?.write(
        to: directory.appendingPathComponent(name))
    }
    // Hover state: the tip bar for the first session outside tmux.
    if let session = store.sessions.first(where: \.outsideTmux) {
      preferences.expanded = true
      preferences.hover(session.id, tip: session.tips(hooksInstalled: store.claudeHooksInstalled))
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(
          to: directory.appendingPathComponent("panel-tip.png"))
      }
      preferences.hover(session.id, tip: nil)
    }
    preferences.expanded = wasExpanded
    resize()
  }

  @objc private func screensChanged() { ensureVisible() }
  func ensureVisible() {
    let visible = NSScreen.screens.contains {
      $0.visibleFrame.intersection(panel.frame).width >= min(100, panel.frame.width)
        && $0.visibleFrame.intersection(panel.frame).height >= 30
    }
    if !visible, let screen = NSScreen.main ?? NSScreen.screens.first {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - panel.frame.width - 20,
          y: screen.visibleFrame.maxY - panel.frame.height - 20))
    }
  }
  func windowDidMove(_ notification: Notification) {
    UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin")
  }
}
