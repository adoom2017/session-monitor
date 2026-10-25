import AppKit
import SMCore
import UserNotifications

@MainActor final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private var policy = NotificationPolicy()
  var jump: ((String) -> Void)?
  var report: ((any Error, String) -> Void)?
  var diagnose: ((String) -> Void)?
  var isCurrent: ((Session) -> Bool)?
  override init() {
    super.init()
    center.delegate = self
  }

  func requestAuthorization() async {
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      if !granted { report?(MonitorError.invalid("系统通知权限未开启"), "通知权限") }
    } catch { report?(error, "通知授权失败") }
  }

  func transition(previous: Session?, current: Session) {
    guard previous?.state != current.state, [.needsPermission, .needsInput].contains(current.state)
    else { return }
    if current.kind == .codex, current.state == .needsPermission {
      // Codex's auto-reviewer usually decides within ~2s (seen in captures); only a request still
      // pending afterwards needs the user. `send` re-checks that the state is still current.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.codexPermissionGrace))
        guard let self, self.isCurrent?(current) == true else { return }
        self.send(current)
      }
      return
    }
    send(current)
  }

  static let codexPermissionGrace: Double = 5

  func send(_ session: Session) {
    let preference = "notify.\(session.state.rawValue)"
    let enabled = UserDefaults.standard.object(forKey: preference) as? Bool ?? true
    let key = session.id + ":" + session.state.rawValue
    guard policy.reserve(session, enabled: enabled, now: Date()) else { return }
    Task {
      let settings = await center.notificationSettings()
      guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
        report?(MonitorError.invalid("通知已启用但系统未授权"), "通知未发送")
        return
      }
      do {
        if try await isForeground(session) { return }
      } catch { diagnose?("无法判断前台窗格，仍将发送通知：\(error.localizedDescription)") }
      guard isCurrent?(session) == true else { return }
      let content = UNMutableNotificationContent()
      switch session.state {
      case .needsPermission: content.title = "⚠️ \(singleLine(session.displayName, limit: 80)) 需要授权"
      case .needsInput: content.title = "💬 \(singleLine(session.displayName, limit: 80)) 等待输入"
      case .done: content.title = "🔵 \(singleLine(session.displayName, limit: 80)) 已完成"
      default: return
      }
      content.body = singleLine(
        session.state == .done
          ? (session.lastAssistantSnippet ?? "会话已完成")
          : (session.attentionMessage ?? session.stateLabel), limit: 80)
      content.userInfo = ["sessionID": session.id]
      if session.state != .done { content.sound = .default }
      do {
        try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
      } catch { report?(error, "发送通知失败") }
    }
  }

  private func isForeground(_ session: Session) async throws -> Bool {
    let program = session.terminal.termProgram
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if let program, program != "tmux", let bundle = TerminalPolicy.bundleID(program) {
      guard frontmost == bundle else { return false }
    } else {
      guard let frontmost, TerminalPolicy.preferredBundles.contains(frontmost) else { return false }
    }
    if let pane = session.terminal.tmuxPane {
      return try await Jumper.activeTmuxPane(socket: session.terminal.tmuxSocket) == pane
    }
    // Frontmost app alone cannot identify an iTerm tab; send rather than suppress without evidence.
    throw MonitorError.invalid("前台终端没有可核对的 tmux pane，无法确认目标会话")
  }

  /// Debug aid (SM_TEST_NOTIFICATION=1): one notification to check icon and delivery.
  func sendTest() async {
    let content = UNMutableNotificationContent()
    content.title = "\(AppInfo.name) 测试通知"
    content.body = "如果左侧显示 \(AppInfo.name) 图标，通知图标已正常。"
    do {
      try await center.add(UNNotificationRequest(identifier: "sm-test", content: content, trigger: nil))
    } catch { report?(error, "测试通知发送失败") }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = response.notification.request.content.userInfo["sessionID"] as? String else {
      return
    }
    await MainActor.run { jump?(id) }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
