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
    panel.isMovableByWindowBackground = true
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
        jump: jump, copy: copy, showLog: showLog, openSettings: openSettings,
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
    // Where the panel was when the current press began; a release elsewhere means a drag.
    pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated {
        if let self, event.window === self.panel { self.pressOrigin = self.panel.frame.origin }
      }
      return event
    }
  }

  private var outsideClickMonitor: Any?
  private var pressMonitor: Any?
  private var pressOrigin: NSPoint?

  private func collapseIfExpanded() {
    if preferences.expanded { preferences.expanded = false }
  }

  /// A drag moves the window under the cursor, so the mouse-up that ends it lands on the chevron
  /// and would count as a click. If the panel moved since the press began, it was a drag.
  func expandUnlessDragged() {
    if let start = pressOrigin, hypot(panel.frame.minX - start.x, panel.frame.minY - start.y) > 2 {
      return
    }
    preferences.expanded = true
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
