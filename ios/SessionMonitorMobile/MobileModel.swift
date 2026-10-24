import Foundation
import Observation
import SMProtocol
import UIKit

/// App state: paired Macs, the live connection to the current one, and what it has sent.
/// Reconnects with backoff while the app is active (DEV_SPEC §17, R2).
@MainActor @Observable final class MobileModel {
  enum Connection: Equatable {
    case idle
    case connecting
    case connected(host: String)
    /// `retrying`: the loop will try again; false when it gave up (token refused, pin mismatch).
    case failed(String, retrying: Bool)
  }

  struct Feedback: Equatable {
    var status: ActionStatus?
    var message: String
    var at: Date
  }

  private(set) var servers: [PairedServer] = ServerStore.load()
  private(set) var currentID: String? = UserDefaults.standard.string(forKey: "currentServer")
  private(set) var connection: Connection = .idle
  private(set) var sessions: [String: RemoteSession] = [:]
  private(set) var transcripts: [String: [TranscriptEntry]] = [:]
  /// Sessions whose history goes further back than what is loaded.
  private(set) var hasOlder: Set<String> = []
  @ObservationIgnored private var loadingOlder: Set<String> = []
  private(set) var panes: [String: PaneSnapshot] = [:]
  /// Latest action result per session, shown under the input bar.
  private(set) var feedback: [String: Feedback] = [:]
  var pairingError: String?
  private(set) var pairing = false

  @ObservationIgnored private var link: RemoteConnection?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var transcriptSubscriptions: Set<String> = []
  @ObservationIgnored private var paneSubscriptions: Set<String> = []
  @ObservationIgnored private var pendingRequests: [String: String] = [:]

  var current: PairedServer? { servers.first { $0.id == currentID } ?? servers.first }

  /// Same order as the Mac panel: needs permission, needs input, finished, working, the rest.
  var orderedSessions: [RemoteSession] {
    sessions.values.sorted {
      if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
      if $0.stateSince != $1.stateSince { return $0.stateSince < $1.stateSince }
      return $0.id < $1.id
    }
  }

  // MARK: Pairing

  func pair(link url: URL) async {
    pairingError = nil
    pairing = true
    defer { pairing = false }
    do {
      let payload = try PairingPayload(url: url)
      let (connection, welcome) = try await RemoteConnection.connect(
        hosts: payload.hosts, port: payload.port, fingerprint: payload.fingerprint,
        hello: Hello(deviceName: Self.deviceName, token: nil, pairingCode: payload.code))
      connection.close()
      guard let token = welcome.token else { throw RemoteClientError.unexpectedMessage }
      let server = PairedServer(
        serverName: welcome.serverName, hosts: [welcome.host] + payload.hosts.filter { $0 != welcome.host },
        port: payload.port, fingerprint: payload.fingerprint, deviceId: welcome.deviceId, token: token)
      servers.removeAll { $0.fingerprint == server.fingerprint }
      servers.append(server)
      try ServerStore.save(servers)
      select(server.id)
    } catch {
      pairingError = error.localizedDescription
    }
  }

  func select(_ id: String) {
    currentID = id
    UserDefaults.standard.set(id, forKey: "currentServer")
    sessions = [:]
    transcripts = [:]
    panes = [:]
    connect()
  }

  func remove(_ server: PairedServer) {
    servers.removeAll { $0.id == server.id }
    try? ServerStore.save(servers)
    if currentID == server.id || current == nil {
      disconnect()
      sessions = [:]
      currentID = servers.first?.id
      if currentID != nil { connect() }
    }
  }

  // MARK: Connection

  func connect() {
    loop?.cancel()
    link?.close()
    guard let server = current else {
      connection = .idle
      return
    }
    loop = Task { [weak self] in
      var delay: Double = 1
      while !Task.isCancelled {
        guard let self else { return }
        connection = .connecting
        do {
          let (link, welcome) = try await RemoteConnection.connect(
            hosts: server.hosts, port: server.port, fingerprint: server.fingerprint,
            hello: Hello(deviceName: Self.deviceName, token: server.token, pairingCode: nil))
          if Task.isCancelled { link.close(); return }
          self.link = link
          // Requests sent on the previous connection got no answer; let them be asked again.
          loadingOlder.removeAll()
          connection = .connected(host: welcome.host)
          remember(host: welcome.host, of: server)
          delay = 1
          for id in transcriptSubscriptions { try await link.send(.subscribeTranscript(sessionId: id)) }
          for id in paneSubscriptions { try await link.send(.subscribePane(sessionId: id)) }
          for try await message in link.messages { handle(message) }
          if Task.isCancelled { return }
          connection = .failed("与 Mac 的连接已断开", retrying: true)
        } catch let error as RemoteClientError {
          if Task.isCancelled { return }
          switch error {
          case .fingerprintMismatch, .rejected:
            connection = .failed(error.localizedDescription, retrying: false)
            self.link = nil
            return
          default:
            connection = .failed(error.localizedDescription, retrying: true)
          }
        } catch {
          if Task.isCancelled { return }
          connection = .failed(error.localizedDescription, retrying: true)
        }
        self.link = nil
        try? await Task.sleep(for: .seconds(delay))
        delay = min(delay * 2, 15)
      }
    }
  }

  func disconnect() {
    loop?.cancel()
    loop = nil
    link?.close()
    link = nil
    connection = .idle
  }

  /// The address that answered goes first next time.
  private func remember(host: String, of server: PairedServer) {
    guard let index = servers.firstIndex(where: { $0.id == server.id }), servers[index].hosts.first != host
    else { return }
    servers[index].hosts = [host] + servers[index].hosts.filter { $0 != host }
    try? ServerStore.save(servers)
  }

  private func handle(_ message: ServerMessage) {
    switch message {
    case .welcome: break
    case .snapshot(let list):
      sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    case .sessionUpdated(let session):
      sessions[session.id] = session
    case .sessionRemoved(let id):
      sessions.removeValue(forKey: id)
    case .transcript(let id, let entries, let reset, let older):
      if reset {
        loadingOlder.remove(id)
        transcripts[id] = entries
        if older { hasOlder.insert(id) } else { hasOlder.remove(id) }
      } else {
        var list = transcripts[id] ?? []
        let known = Set(list.map(\.id))
        list += entries.filter { !known.contains($0.id) }
        transcripts[id] = list
      }
    case .transcriptOlder(let id, let entries, let older):
      loadingOlder.remove(id)
      let known = Set((transcripts[id] ?? []).map(\.id))
      transcripts[id] = entries.filter { !known.contains($0.id) } + (transcripts[id] ?? [])
      if older { hasOlder.insert(id) } else { hasOlder.remove(id) }
    case .pane(let pane):
      panes[pane.sessionId] = pane
    case .actionResult(let requestId, let status, let message):
      guard let id = pendingRequests.removeValue(forKey: requestId) else { return }
      feedback[id] = Feedback(status: status, message: message ?? Self.describe(status), at: Date())
    case .error(let message):
      pairingError = message
    }
  }

  static func describe(_ status: ActionStatus) -> String {
    switch status {
    case .delivered: "已送达"
    case .unconfirmed: "已输入终端，暂未看到会话响应"
    case .rejected: "未发送"
    }
  }

  // MARK: Subscriptions and actions

  func open(_ id: String) {
    transcriptSubscriptions.insert(id)
    let wantsPane = sessions[id]?.remoteInput == true
    if wantsPane { paneSubscriptions.insert(id) }
    Task {
      try? await link?.send(.subscribeTranscript(sessionId: id))
      if wantsPane { try? await link?.send(.subscribePane(sessionId: id)) }
      if sessions[id]?.unread == true { try? await link?.send(.markRead(sessionId: id)) }
    }
  }

  /// The page before the oldest loaded entry.
  func loadOlder(_ id: String) {
    guard hasOlder.contains(id), !loadingOlder.contains(id), let first = transcripts[id]?.first,
      let link
    else { return }
    loadingOlder.insert(id)
    Task {
      // A request lost to a dropped connection must not leave the page waiting forever.
      do { try await link.send(.loadOlderTranscript(sessionId: id, beforeId: first.id)) } catch {
        loadingOlder.remove(id)
      }
    }
  }

  func close(_ id: String) {
    transcriptSubscriptions.remove(id)
    paneSubscriptions.remove(id)
    Task {
      try? await link?.send(.unsubscribeTranscript(sessionId: id))
      try? await link?.send(.unsubscribePane(sessionId: id))
    }
  }

  func send(_ text: String, to id: String) {
    request(id, sending: "发送中…") { .sendMessage(requestId: $0, sessionId: id, text: text) }
  }

  func send(_ key: RemoteKey, to id: String) {
    request(id, sending: "已按下 \(key.rawValue)…") { .sendKey(requestId: $0, sessionId: id, key: key) }
  }

  private func request(_ id: String, sending: String, _ make: (String) -> ClientMessage) {
    guard let link else {
      feedback[id] = Feedback(status: .rejected, message: "未连接到 Mac", at: Date())
      return
    }
    let requestId = UUID().uuidString
    pendingRequests[requestId] = id
    feedback[id] = Feedback(status: nil, message: sending, at: Date())
    let message = make(requestId)
    Task {
      do { try await link.send(message) } catch {
        pendingRequests.removeValue(forKey: requestId)
        feedback[id] = Feedback(status: .rejected, message: "发送失败：\(error.localizedDescription)", at: Date())
      }
    }
  }

  static var deviceName: String {
    let name = UIDevice.current.name
    return name.isEmpty ? UIDevice.current.model : name
  }
}

extension RemoteSession {
  var sortRank: Int {
    switch state {
    case .needsPermission: 0
    case .needsInput: 1
    case .done: 2
    case .working: 3
    default: 4
    }
  }
}
