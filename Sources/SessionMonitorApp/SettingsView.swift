import AppKit
import SMCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppInfo {
  static var shortVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }
  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  }
  /// e.g. "1.1.0 (202610200526)"
  static var version: String { "\(shortVersion) (\(build))" }
}

/// What the settings window can ask the app to do.
struct SettingsActions {
  let installHooks: (HookInstaller.Agent) async throws -> URL
  let uninstallHooks: (HookInstaller.Agent) async throws -> URL
  let requestNotifications: () async -> Void
  let showLog: () -> Void
  let openDataDirectory: () -> Void
  let report: (any Error, String) -> Void
}

/// One settings tab, shown in the window's toolbar (see AppDelegate.makeSettingsWindow).
enum SettingsTab: String, CaseIterable {
  case integration, notifications, general, about

  var title: String {
    switch self {
    case .integration: "集成"
    case .notifications: "通知"
    case .general: "通用"
    case .about: "关于"
    }
  }
  var symbol: String {
    switch self {
    case .integration: "puzzlepiece.extension"
    case .notifications: "bell.badge"
    case .general: "gearshape"
    case .about: "info.circle"
    }
  }

  @MainActor func view(actions: SettingsActions) -> AnyView {
    switch self {
    case .integration: AnyView(IntegrationSettings(actions: actions))
    case .notifications: AnyView(NotificationSettings(actions: actions))
    case .general: AnyView(GeneralSettings(actions: actions))
    case .about: AnyView(AboutSettings())
    }
  }
}

private let settingsWidth: CGFloat = 520

/// Title with a secondary explanation line, used by every row.
private func labeled(_ title: String, _ detail: String) -> some View {
  VStack(alignment: .leading, spacing: 2) {
    Text(title)
    Text(detail).font(.caption).foregroundStyle(.secondary)
  }
}

private extension View {
  func settingsPage() -> some View {
    formStyle(.grouped).frame(width: settingsWidth).fixedSize(horizontal: false, vertical: true)
  }
  /// Re-read external state when the window comes back (e.g. after System Settings or Codex /hooks).
  func onWindowFocus(_ action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      action()
    }
  }
}

// MARK: - 集成

struct IntegrationSettings: View {
  let actions: SettingsActions
  /// Read synchronously at creation (small files) so the tab never flashes "未安装".
  @State private var hookStatus: [HookInstaller.Agent: HookInstaller.Status] = Dictionary(
    uniqueKeysWithValues: HookInstaller.Agent.allCases.map { ($0, HookInstaller(agent: $0).status()) })
  @State private var hookMessage: String?
  @State private var busyAgent: HookInstaller.Agent?
  @State private var confirmUninstall: HookInstaller.Agent?

  var body: some View {
    Form {
      Section {
        hookRow(.claude, name: "Claude Code", folder: ".claude")
        hookRow(.codex, name: "Codex", folder: ".codex")
      } header: {
        Text("Hook")
      } footer: {
        Text(
          hookMessage
            ?? "安装会在配置中加入 SessionMonitor 的 hook，保留你已有的其他 hook；修改前自动备份到 ~/.session-monitor/backups。"
        )
        .font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section {
        comparison
      } header: {
        Text("安装与不安装的区别")
      } footer: {
        Label(
          "不安装时最大的问题：会话停下来等你批准权限或回答问题时，面板不会变色，也不会通知，看起来还在工作或空闲。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption).foregroundStyle(.orange)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .settingsPage()
    .onWindowFocus(refresh)
    .confirmationDialog(
      "卸载 \(confirmUninstall == .codex ? "Codex" : "Claude Code") 的 hook？",
      isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })
    ) {
      Button("卸载", role: .destructive) {
        if let agent = confirmUninstall { run(agent, install: false) }
      }
    } message: {
      Text("只移除 SessionMonitor 自己的条目，其他 hook 不受影响。卸载后该工具的会话只能显示忙/闲。")
    }
  }

  /// What the hooks add (rows: feature, with hook, without hook).
  private var comparison: some View {
    let rows: [(String, String, String)] = [
      ("会话列表、点击跳转", "✓", "✓"),
      ("工作中 / 空闲", "实时", "约 2 秒延迟"),
      ("需要授权、等待输入的提醒", "✓ 变色并通知", "✗ 看不到"),
      ("完成提醒和回复摘要", "✓", "Claude 稍有延迟；Codex 无摘要"),
      ("正在执行的命令", "✓", "✗ 只显示“正在处理”"),
      ("Codex 桌面 App 的会话", "✓", "✗ 看不到"),
    ]
    return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
      GridRow {
        Text("").gridColumnAlignment(.leading)
        Text("已安装").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text("未安装").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(rows, id: \.0) { row in
        GridRow {
          Text(row.0).font(.callout)
          Text(row.1).font(.callout).foregroundStyle(.green)
          Text(row.2).font(.callout).foregroundStyle(row.2.hasPrefix("✗") ? .orange : .secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func hookRow(_ agent: HookInstaller.Agent, name: String, folder: String) -> some View {
    let status = hookStatus[agent] ?? .notInstalled
    let toolPresent = FileManager.default.fileExists(
      atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder).path)
    let (symbol, color, detail): (String, Color, String) = {
      switch status {
      case .installed: return ("checkmark.circle.fill", .green, "已安装，会话状态实时更新")
      case .awaitingTrust(let count):
        return (
          "exclamationmark.circle.fill", .orange,
          "已安装，还有 \(count) 项需要在 Codex 中批准：在任意 Codex 会话输入 /hooks 批准；已打开的 Codex 会话需重启"
        )
      case .notInstalled:
        return (
          "circle.dashed", .secondary,
          toolPresent ? "未安装：只能显示忙/闲，无法提示授权和等待输入" : "未检测到 \(name)（~/\(folder) 不存在）"
        )
      case .unreadable(let message): return ("xmark.octagon.fill", .red, "配置文件无法读取：\(message)")
      }
    }()
    LabeledContent {
      if busyAgent == agent {
        ProgressView().controlSize(.small)
      } else if status == .notInstalled {
        Button("安装") { run(agent, install: true) }.disabled(!toolPresent)
      } else if case .unreadable = status {
        EmptyView()
      } else {
        Button("卸载") { confirmUninstall = agent }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol).foregroundStyle(color)
        labeled(name, detail)
      }
    }
  }

  private func refresh() {
    for agent in HookInstaller.Agent.allCases { hookStatus[agent] = HookInstaller(agent: agent).status() }
  }

  private func run(_ agent: HookInstaller.Agent, install: Bool) {
    busyAgent = agent
    Task {
      do {
        let backup = try await (install ? actions.installHooks(agent) : actions.uninstallHooks(agent))
        hookMessage = "\(install ? "已安装" : "已卸载")。原配置已备份：\(backup.path)"
      } catch {
        hookMessage = "\(install ? "安装" : "卸载")失败：\(error.localizedDescription)（配置未改动）"
        actions.report(error, install ? "安装 hook 失败" : "卸载 hook 失败")
      }
      busyAgent = nil
      refresh()
    }
  }
}

// MARK: - 通知

struct NotificationSettings: View {
  let actions: SettingsActions
  @AppStorage("notify.needsPermission") private var notifyPermission = true
  @AppStorage("notify.needsInput") private var notifyInput = true
  @AppStorage("notify.done") private var notifyDone = true
  @State private var authorization: UNAuthorizationStatus?

  var body: some View {
    Form {
      Section {
        statusRow
      } header: {
        Text("系统权限")
      }
      Section {
        Toggle(isOn: $notifyPermission) { labeled("需要授权", "Claude / Codex 请求权限时提醒，有声音") }
        Toggle(isOn: $notifyInput) { labeled("等待输入", "需要你回答问题或确认计划时提醒，有声音") }
        Toggle(isOn: $notifyDone) { labeled("已完成", "一轮任务结束时提醒，附最后一句回复，无声音") }
      } header: {
        Text("提醒哪些状态")
      } footer: {
        Text("Codex 的自动审核通常 2 秒内就会批准，所以 Codex 的“需要授权”会等 5 秒，仍未处理才提醒。")
          .font(.caption).foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .settingsPage()
    .task { await refreshAuthorization() }
    .onWindowFocus { Task { await refreshAuthorization() } }
  }

  @ViewBuilder private var statusRow: some View {
    let allowed = authorization == .authorized || authorization == .provisional
    LabeledContent {
      if authorization == .notDetermined {
        Button("请求权限") {
          Task {
            await actions.requestNotifications()
            await refreshAuthorization()
          }
        }
      } else {
        Button("打开系统设置…", action: openSystemNotificationSettings)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(allowed ? Color.green : Color.orange)
        labeled(
          allowed ? "系统通知已允许" : (authorization == nil ? "正在检查系统通知权限…" : "系统通知未允许"),
          allowed ? "通知样式和声音可在系统设置中调整" : "未允许时下面的开关不会生效")
      }
    }
  }

  private func refreshAuthorization() async {
    authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  private func openSystemNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? ""
    let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
    if !NSWorkspace.shared.open(url) {
      actions.report(MonitorError.invalid("无法打开系统通知设置"), "打开系统设置失败")
    }
  }
}

// MARK: - 通用

struct GeneralSettings: View {
  let actions: SettingsActions
  @AppStorage(AppDelegate.detachedActionKey) private var detachedAction = ""
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    Form {
      Section {
        Picker(selection: $detachedAction) {
          Text("每次询问").tag("")
          Text("切换最近活动的 tmux 窗口").tag(DetachedTmuxAction.switchRecent.rawValue)
          Text("新开标签页").tag(DetachedTmuxAction.newTab.rawValue)
        } label: {
          labeled("会话未在任何窗口打开时", "点击的 tmux session 没有标签页在显示它")
        }
      } header: {
        Text("跳转")
      }
      Section {
        Toggle(isOn: $launchAtLogin) { labeled("登录时启动", "开机后自动在后台运行") }
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        LabeledContent {
          Text("⌥⌘S").font(.body.monospaced()).foregroundStyle(.secondary)
        } label: {
          labeled("显示 / 隐藏悬浮窗", "全局快捷键")
        }
      } header: {
        Text("启动与快捷键")
      }
      Section {
        HStack {
          Button("查看日志", action: actions.showLog)
          Button("打开数据目录", action: actions.openDataDirectory)
          Spacer()
        }
      } header: {
        Text("数据")
      } footer: {
        Text("数据目录 ~/.session-monitor 保存日志、hook 程序和配置备份。")
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .settingsPage()
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      actions.report(error, "开机启动设置失败")
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

// MARK: - 关于

struct AboutSettings: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
      Text("SessionMonitor").font(.title.weight(.semibold))
      Text("版本 \(AppInfo.version)").font(.callout).foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text("集中查看 Claude Code / Codex 会话状态：哪个在工作、哪个已完成、哪个在等你。")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .frame(maxWidth: 380)
    }
    .padding(.vertical, 32)
    .frame(width: settingsWidth)
  }
}
