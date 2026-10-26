import AppKit
import Carbon
import Observation
import SMCore
import ServiceManagement
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = SessionStore()
  private var runtime: AppRuntime!
  private var remote: RemoteAccess!
  private var panel: PanelController!
  private var status: NSStatusItem!
  private var notifications: NotificationManager!
  private var settingsWindow: NSWindow?
  private var usageWindow: NSWindow?
  private var hotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var menuSessions: [String: Session] = [:]

  func applicationDidFinishLaunching(_ notification: Notification) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    runtime = AppRuntime(store: store, directory: home.appendingPathComponent(".session-monitor"))
    remote = RemoteAccess(store: store, directory: runtime.directory) { [weak self] text in
      Task { await self?.runtime.writeLog(text) }
    }
    let usage = runtime.usage
    remote.usageRows = { usage.rows }
    panel = PanelController(
      store: store, jump: { [weak self] in self?.jump($0) },
      copy: { [weak self] in self?.copy($0) }, showLog: { [weak self] in self?.showLog() },
      openSettings: { [weak self] in self?.showSettings() })
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    notifications = NotificationManager()
    notifications.jump = { [weak self] id in
      if let session = self?.store.byID[id] { self?.jump(session) }
    }
    notifications.report = { [weak self] error, context in self?.report(error, context) }
    notifications.diagnose = { [weak self] message in
      Task { await self?.runtime.diagnose(.info, message) }
    }
    notifications.isCurrent = { [weak self] session in
      guard let current = self?.store.byID[session.id] else { return false }
      return current.currentSessionId == session.currentSessionId && current.state == session.state
    }
    runtime.stateChanged = { [weak self] previous, current in
      self?.notifications.transition(previous: previous, current: current)
    }
    runtime.notifyDone = { [weak self] session in self?.notifications.send(session) }
    observeStore()
    do { try registerHotKey() } catch { report(error, "全局快捷键注册失败") }
    panel.show()
    syncInstalledHook()
    showSettingsOnFirstLaunch()
    if let directory = ProcessInfo.processInfo.environment["SM_SNAPSHOT_DIR"] {
      if let appearance = ProcessInfo.processInfo.environment["SM_SNAPSHOT_APPEARANCE"] {
        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(4))  // first reconcile has populated sessions
        self?.panel.writeSnapshots(to: URL(fileURLWithPath: directory))
        self?.writeSettingsSnapshot(to: URL(fileURLWithPath: directory))
        await self?.writeUsageSnapshot(to: URL(fileURLWithPath: directory))
      }
    }
    Task {
      await runtime.start()
      await remote.resume()
      await notifications.requestAuthorization()
      if ProcessInfo.processInfo.environment["SM_TEST_NOTIFICATION"] == "1" {
        await notifications.sendTest()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    runtime?.stop()
    remote?.stop()
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
  }

  private func observeStore() {
    withObservationTracking {
      _ = store.sessions
      _ = store.lastError
      rebuildMenu()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeStore() }
    }
  }

  private func rebuildMenu() {
    let attention = store.sessions.filter { [.needsPermission, .needsInput].contains($0.state) }
      .count
    let image = NSImage(
      systemSymbolName: StatusIconPolicy.symbolName(attention: attention),
      accessibilityDescription: AppInfo.name)
    image?.isTemplate = true
    status.button?.image = image
    status.button?.contentTintColor =
      attention > 0 ? .systemOrange : (store.lastError != nil ? .systemRed : nil)
    // Never let the item go blank: a missing symbol once made it invisible while keeping its slot.
    status.button?.title =
      attention > 0 ? " \(attention)" : (image == nil ? "SM" : "")
    let menu = NSMenu()
    let versionItem = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.shortVersion)", action: nil, keyEquivalent: "")
    versionItem.isEnabled = false
    menu.addItem(versionItem)
    menu.addItem(.separator())
    menuSessions = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
    if store.sessions.isEmpty {
      let item = NSMenuItem(title: "暂无会话", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    for session in store.sessions {
      let item = NSMenuItem(
        title: "\(session.stateLabel) · [\(session.kind == .codex ? "Codex" : "Claude")] \(session.displayName)",
        action: #selector(menuJump(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = session.id
      menu.addItem(item)
    }
    menu.addItem(.separator())
    add(menu, "显示/隐藏悬浮窗", #selector(togglePanel), key: "s", modifiers: [.option, .command])
    add(menu, "全部标为已读", #selector(markRead))
    let login = add(menu, "开机启动", #selector(toggleLogin))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    add(menu, "用量统计…", #selector(showUsage))
    add(menu, "设置…", #selector(showSettings), key: ",")
    add(menu, "查看日志", #selector(showLog))
    if store.lastError != nil { add(menu, "查看当前错误", #selector(showError)) }
    menu.addItem(.separator())
    add(menu, "退出", #selector(quit), key: "q")
    status.menu = menu
  }

  @discardableResult private func add(
    _ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = [.command]
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    item.keyEquivalentModifierMask = modifiers
    menu.addItem(item)
    return item
  }
  @objc private func togglePanel() { panel.toggle() }
  @objc private func markRead() { store.markAllRead() }
  @objc private func quit() { NSApp.terminate(nil) }
  @objc private func menuJump(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String, let session = menuSessions[id] {
      jump(session)
    }
  }
  @objc private func toggleLogin() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
      rebuildMenu()
    } catch { report(error, "开机启动设置失败") }
  }
  @objc private func showError() {
    panel.preferences.expanded = true
    panel.show()
  }
  @objc private func showLog() {
    let path = runtime.directory.appendingPathComponent("app.log")
    if !NSWorkspace.shared.open(path) { report(MonitorError.invalid("无法打开 app.log"), "查看日志失败") }
  }
  /// The sm-hook shipped inside the app bundle; copied to ~/.session-monitor/bin on install.
  private var bundledHook: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sm-hook")
  }

  private var settingsActions: SettingsActions {
    let hook = bundledHook
    return SettingsActions(
      installHooks: { agent in
        try await Task.detached { try HookInstaller(agent: agent).install(bundledHook: hook) }.value
      },
      uninstallHooks: { agent in
        try await Task.detached { try HookInstaller(agent: agent).uninstall() }.value
      },
      requestNotifications: { [weak self] in await self?.notifications.requestAuthorization() },
      showLog: { [weak self] in self?.showLog() },
      openDataDirectory: { [weak self] in
        guard let self else { return }
        if !NSWorkspace.shared.open(self.runtime.directory) {
          self.report(MonitorError.invalid("无法打开数据目录"), "打开数据目录失败")
        }
      },
      report: { [weak self] error, context in self?.report(error, context) },
      remote: remote)
  }

  @objc private func showSettings() {
    if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  @objc private func showUsage() {
    if usageWindow == nil {
      let runtime = runtime!
      let view = UsageView(stats: runtime.usage) { Task { await runtime.refreshLedger() } }
      let window = NSWindow(contentViewController: NSHostingController(rootView: view))
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      window.title = "\(AppInfo.name) 用量统计"
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 680, height: 760))
      window.center()
      usageWindow = window
    }
    usageWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    Task { await runtime.refreshLedger() }
  }

  /// Native preferences window: toolbar tabs, each sized to its content.
  private func makeSettingsWindow() -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    for tab in SettingsTab.allCases {
      let controller = NSHostingController(rootView: tab.view(actions: settingsActions))
      controller.sizingOptions = .preferredContentSize
      // Toolbar-style tabs propagate the selected tab's title to the window (macOS preferences
      // convention); without one the window read "Untitled".
      controller.title = tab.title
      let item = NSTabViewItem(viewController: controller)
      item.label = tab.title
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
      tabs.addTabViewItem(item)
    }
    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.title = "\(AppInfo.name) 设置"
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }

  /// After an app update the installed hook program must match the bundled one.
  private func syncInstalledHook() {
    let hook = bundledHook
    Task {
      do {
        let replaced = try await Task.detached { () throws -> Bool in
          var replaced = false
          for agent in HookInstaller.Agent.allCases where HookInstaller(agent: agent).status() != .notInstalled {
            replaced = try HookInstaller(agent: agent).syncBinary(from: hook) || replaced
          }
          return replaced
        }.value
        if replaced { await runtime.diagnose(.info, "已将 hook 程序更新为当前 App 版本。") }
      } catch { report(error, "更新 hook 程序失败") }
    }
  }

  /// Users only install the app: open Settings once so they can connect Claude Code / Codex.
  private func showSettingsOnFirstLaunch() {
    let key = "onboardingShown"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    let anyInstalled = HookInstaller.Agent.allCases.contains {
      HookInstaller(agent: $0).status() != .notInstalled
    }
    if !anyInstalled { showSettings() }
  }

  @objc func openSettingsFromPanel() { showSettings() }

  /// Debug aid (SM_SNAPSHOT_DIR): the usage window once the ledger has been read, to usage.png.
  func writeUsageSnapshot(to directory: URL) async {
    while runtime.usage.scanning || runtime.usage.updatedAt == nil { try? await Task.sleep(for: .milliseconds(500)) }
    let hosting = NSHostingView(rootView: UsageView(stats: runtime.usage) {})
    hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 900)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    try? await Task.sleep(for: .milliseconds(800))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("usage.png"))
    _ = window
  }

  /// Debug aid (SM_SNAPSHOT_DIR): renders each settings tab offscreen to settings-<tab>.png.
  func writeSettingsSnapshot(to directory: URL) {
    for tab in SettingsTab.allCases {
      let hosting = NSHostingView(rootView: tab.view(actions: settingsActions))
      hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
      let window = NSWindow(
        contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = hosting
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(
        to: directory.appendingPathComponent("settings-\(tab.rawValue).png"))
    }
  }



  private func registerHotKey() throws {
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let result = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in delegate.togglePanel() }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    guard result == noErr else { throw MonitorError.system("InstallEventHandler", result) }
    let id = EventHotKeyID(signature: 0x534D_4F4E, id: 1)
    let code = RegisterEventHotKey(
      UInt32(kVK_ANSI_S), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    guard code == noErr else { throw MonitorError.system("RegisterEventHotKey", code) }
  }

  private func jump(_ session: Session) {
    store.markRead(session.id)
    Task {
      await JumpCoordinator.jump(
        session,
        activate: { program, hint in
          try await self.activateTerminal(program, hint: hint)
        },
        whenDetached: { tmuxSession in try self.chooseDetachedAction(tmuxSession) },
        report: { error, context in
          await self.runtime.report(error, context: context)
        }, failed: { self.store.jumpFailed(session.id) }, copy: { self.copy($0) })
    }
  }
  private func activateTerminal(_ program: String?, hint: FocusHint) async throws {
    switch hint {
    case .tmux(let tmux):
      // Inside tmux TERM_PROGRAM is "tmux"; the tmux client's termtype names the real outer terminal.
      let bundle = try await bundle(
        forTermType: tmux.termType, fallback: program)
      if tmux.openInNewTab {
        try await Jumper.openTab(bundle: bundle, command: tmux.attachCommand)
        return
      }
      do {
        switch bundle {
        case "com.mitchellh.ghostty":
          // `set-titles-string "#S"` titles the Ghostty tab hosting the session by its name.
          if !(try await Jumper.focusGhostty(title: tmux.session)) { await reportGhosttyNotFront() }
          return
        case "com.googlecode.iterm2":
          try await Jumper.selectITerm(tty: tmux.clientTTY)
          return
        default: break
        }
      } catch {
        await runtime.diagnose(
          .info, "未能定位 tmux session \(tmux.session) 所在的标签页，仅激活终端：\(error.localizedDescription)")
      }
      try await TerminalActivator.activate(bundle: bundle)
    case .local(let cwd, let tty):
      // A known TERM_PROGRAM pins the app; otherwise (session-file-only) try iTerm2 first, where
      // the tty match is exact, then Ghostty by directory.
      let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      let known = program.flatMap(TerminalPolicy.bundleID(_:))
      let candidates =
        known.map { [$0] }
        ?? ["com.googlecode.iterm2", "com.mitchellh.ghostty"].filter(running.contains)
      for bundle in candidates where [
        "com.googlecode.iterm2", "com.mitchellh.ghostty",
      ].contains(bundle) {
        do {
          if try await focusLocal(bundle: bundle, cwd: cwd, tty: tty) { return }
        } catch {
          await runtime.diagnose(.info, "在 \(bundle) 中按目录定位失败：\(error.localizedDescription)")
        }
      }
      try await TerminalActivator.activate(
        bundle: known ?? candidates.first ?? TerminalActivator.bundle(for: program))
    case .none:
      try await TerminalActivator.activate(bundle: TerminalActivator.bundle(for: program))
    }
  }

  private func bundle(forTermType termType: String, fallback program: String?) async throws
    -> String
  {
    if let host = TerminalPolicy.bundleID(termType: termType) { return host }
    if program == nil || program == "tmux" {
      await runtime.diagnose(.info, "外层终端未知，按顺序激活正在运行的 Ghostty/iTerm2/Terminal。")
    }
    return try TerminalActivator.bundle(for: program)
  }

  static let detachedActionKey = "tmux.detachedAction"

  /// No tab shows the target tmux session: use the saved default, or ask (optionally saving it).
  private func chooseDetachedAction(_ tmuxSession: String) throws -> DetachedTmuxAction {
    if let saved = UserDefaults.standard.string(forKey: Self.detachedActionKey),
      let action = DetachedTmuxAction(rawValue: saved)
    {
      return action
    }
    let alert = NSAlert()
    alert.messageText = "tmux session “\(tmuxSession)” 没有在任何窗口中打开"
    alert.informativeText = "切换最近活动的 tmux 窗口会把那个标签页切到该 session；新开标签页会在终端中执行 tmux attach。"
    alert.addButton(withTitle: "新开标签页")
    alert.addButton(withTitle: "切换最近活动的 tmux 窗口")
    alert.addButton(withTitle: "取消")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "设为默认，不再询问（可在“设置”中修改）"
    NSApp.activate()
    let response = alert.runModal()
    let action: DetachedTmuxAction
    switch response {
    case .alertFirstButtonReturn: action = .newTab
    case .alertSecondButtonReturn: action = .switchRecent
    default: throw JumpCancelled()
    }
    if alert.suppressionButton?.state == .on {
      UserDefaults.standard.set(action.rawValue, forKey: Self.detachedActionKey)
    }
    return action
  }

  private func reportGhosttyNotFront() async {
    await runtime.diagnose(
      .info, "已选中目标 Ghostty 标签页，但 Ghostty 未把它设为前台（多显示器全屏时可能出现）。")
  }

  /// Returns true when the exact tab was focused; false when nothing (or several tabs) matched.
  private func focusLocal(bundle: String, cwd: String?, tty: String?) async throws -> Bool {
    let ghostty = bundle == "com.mitchellh.ghostty"
    let candidates = try await ghostty ? Jumper.ghosttyTerminals() : Jumper.iTermSessions()
    switch Jumper.pickLocal(candidates, cwd: cwd, tty: tty) {
    case .match(let id):
      if ghostty {
        if !(try await Jumper.focusGhostty(id: id)) { await reportGhosttyNotFront() }
      } else {
        try await Jumper.selectITerm(uuid: id)
      }
      return true
    case .ambiguous(let count):
      await runtime.diagnose(.info, "\(bundle) 中有 \(count) 个标签页目录相同，无法确定目标，仅激活终端。")
      return false
    case .none:
      return false
    }
  }
  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    if !NSPasteboard.general.setString(value, forType: .string) {
      report(MonitorError.invalid("剪贴板写入失败"), "复制失败")
    }
  }
  private func report(_ error: any Error, _ context: String) {
    Task { await runtime.report(error, context: context) }
  }
}
