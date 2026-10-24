import SMProtocol
import SwiftUI

struct SessionListView: View {
  @Environment(MobileModel.self) private var model
  @State private var pairingAnother = false

  var body: some View {
    List {
      ConnectionBanner()
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
      if model.sessions.isEmpty, case .connected = model.connection {
        ContentUnavailableView(
          "没有会话", systemImage: "moon.zzz",
          description: Text("Mac 上没有运行中的 Claude Code 或 Codex 会话。"))
          .listRowBackground(Color.clear)
      }
      ForEach(model.orderedSessions) { session in
        NavigationLink(value: session.id) { SessionRow(session: session) }
          .listRowBackground(Theme.raised)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas.ignoresSafeArea())
    .navigationTitle(model.current?.serverName ?? "SessionMonitor")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
    .refreshable { model.connect() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if model.servers.count > 1 {
            Picker("Mac", selection: Binding(get: { model.current?.id ?? "" }, set: { model.select($0) })) {
              ForEach(model.servers) { Text($0.serverName).tag($0.id) }
            }
          }
          Button("配对另一台 Mac", systemImage: "plus") { pairingAnother = true }
          if let current = model.current {
            Button("移除「\(current.serverName)」", systemImage: "trash", role: .destructive) {
              model.remove(current)
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(isPresented: $pairingAnother) { PairingView(dismissible: true) }
    .onAppear { if model.connection == .idle { model.connect() } }
  }
}

/// Connection state, shown only when not simply connected.
struct ConnectionBanner: View {
  @Environment(MobileModel.self) private var model

  var body: some View {
    switch model.connection {
    case .connected:
      EmptyView()
    case .idle, .connecting:
      Label("正在连接 Mac…", systemImage: "antenna.radiowaves.left.and.right")
        .font(.footnote).foregroundStyle(Theme.textSecondary)
    case .failed(let message, let retrying):
      VStack(alignment: .leading, spacing: 6) {
        Label(message, systemImage: "wifi.exclamationmark")
          .font(.footnote.weight(.medium)).foregroundStyle(retrying ? Theme.orange : Theme.pink)
        if retrying {
          Text("将自动重试。请确认手机与 Mac 在同一局域网，或都已连接 Tailscale。")
            .font(.caption).foregroundStyle(Theme.textSecondary)
        } else {
          Button("重新连接") { model.connect() }.font(.caption.weight(.semibold))
        }
      }
    }
  }
}

struct SessionRow: View {
  let session: RemoteSession

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: session.stateSymbol)
        .font(.system(size: 22)).foregroundStyle(session.stateColor)
        .shadow(color: session.state == .ended ? .clear : session.stateColor.opacity(0.5), radius: 4)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(session.name).font(.body.weight(.semibold)).lineLimit(1)
          Tag(text: session.agentLabel, color: session.agentColor)
          if !session.remoteInput && session.state != .ended {
            Tag(text: "仅查看", color: Theme.idle)
          }
          Spacer(minLength: 4)
          TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(elapsed(since: session.stateSince, now: context.date))
              .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
          }
        }
        Text("\(session.projectName) · \(session.detail)")
          .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}
