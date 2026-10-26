import CryptoKit
import Foundation
import SMProtocol

/// Phone access (DEV_SPEC §17): authenticates peers, pushes session changes, serves transcripts
/// and pane pictures, and performs tmux input for paired devices. Off until `start`.
@MainActor public final class RemoteHub {
  public struct Status: Equatable, Sendable {
    public var running = false
    public var port: UInt16?
    public var connectedDevices: [String] = []
    public var lastError: String?
    public init() {}
  }

  private let store: SessionStore
  private let directory: URL
  public let devices: RemoteDevices
  private let audit: @MainActor (String) -> Void
  public private(set) var status = Status() { didSet { if status != oldValue { statusChanged?(status) } } }
  public var statusChanged: ((Status) -> Void)?
  /// All local sessions' usage (UsageLedger rows), for clients that ask.
  public var usageRows: (() -> [UsageRow])?

  private var server: RemoteServer?
  private var identity: RemoteIdentity?
  private var serverName = "Mac"
  private var port = RemoteProtocol.defaultPort
  private var clients: [UUID: Client] = [:]
  private var published: [String: RemoteSession] = [:]
  private var ticker: Task<Void, Never>?
  private var failures: [String: [Date]] = [:]

  /// Grace period for the hello; then the connection is dropped.
  static let helloTimeout: Duration = .seconds(10)
  static let confirmationWindow: TimeInterval = 5

  /// A conversation feed for one session, with the thread it reads (a new thread needs a new
  /// feed). Not `ready` while the history is still being parsed.
  final class TranscriptSubscription {
    let feed: TranscriptFeed?
    let thread: String
    var ready = false
    init(feed: TranscriptFeed?, thread: String) {
      self.feed = feed
      self.thread = thread
    }
  }

  final class Client {
    let peer: RemotePeer
    var device: RemoteDevice?
    var transcripts: [String: TranscriptSubscription] = [:]
    var panes: [String: String] = [:]
    init(peer: RemotePeer) { self.peer = peer }
  }

  public init(store: SessionStore, directory: URL, audit: @escaping @MainActor (String) -> Void) throws {
    self.store = store
    self.directory = directory
    self.audit = audit
    devices = try RemoteDevices(directory: directory)
  }

  public var fingerprint: String? { identity?.fingerprint }

  public func start(serverName: String, port: UInt16 = RemoteProtocol.defaultPort, advertise: Bool = true) async throws {
    guard server == nil else { return }
    self.serverName = serverName
    self.port = port
    let directory = directory
    let identity = try await Task.detached(priority: .utility) {
      try RemoteIdentity.loadOrCreate(directory: directory)
    }.value
    self.identity = identity
    let server = RemoteServer { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    try server.start(identity: identity, port: port, serviceName: advertise ? serverName : nil)
    self.server = server
    status.running = true
    status.lastError = nil
    ticker = Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        guard let self else { return }
        publishSessions()
        // Panes twice a second, so streaming output looks live; transcripts once a second.
        await refreshPanes()
        if tick % 2 == 0 { await refreshTranscripts() }
        tick += 1
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  public func stop() {
    ticker?.cancel()
    ticker = nil
    server?.stop()
    server = nil
    clients.removeAll()
    published.removeAll()
    devices.cancelPairingCode()
    status = Status()
  }

  /// A new one-time code with the addresses a phone can use; nil while stopped.
  public func pairingPayload() -> PairingPayload? {
    guard server != nil, let identity else { return nil }
    let addresses = RemoteAddressPolicy.localAddresses()
    return PairingPayload(
      serverName: serverName, hosts: addresses.lan + addresses.tailscale, port: status.port ?? port,
      fingerprint: identity.fingerprint, code: devices.newPairingCode())
  }

  public func revoke(deviceID: String) throws {
    try devices.revoke(id: deviceID)
    for client in clients.values where client.device?.id == deviceID {
      client.peer.reject("此设备已被 Mac 吊销")
    }
    audit("REMOTE 已吊销设备 \(deviceID)")
  }

  // MARK: Events

  private func handle(_ event: RemoteServer.Event) {
    switch event {
    case .ready(let port):
      status.port = port
    case .failed(let message):
      status.lastError = message
      audit("REMOTE 监听失败：\(message)")
    case .rejected(let host, let reason):
      audit("REMOTE 拒绝 \(host)：\(reason)")
    case .connected(let peer):
      clients[peer.id] = Client(peer: peer)
      Task { [weak self] in
        try? await Task.sleep(for: Self.helloTimeout)
        guard let self, let client = clients[peer.id], client.device == nil else { return }
        peer.reject("未在规定时间内完成认证")
      }
    case .disconnected(let peer):
      clients.removeValue(forKey: peer.id)
      updateConnected()
    case .message(let peer, let message):
      guard let client = clients[peer.id] else { return }
      if case .hello(let hello) = message {
        authenticate(client, hello)
      } else if client.device != nil {
        perform(message, for: client)
      } else {
        peer.reject("请先认证")
      }
    }
  }

  private func authenticate(_ client: Client, _ hello: Hello) {
    let peer = client.peer
    guard client.device == nil else { return }
    let now = Date()
    let recent = (failures[peer.host] ?? []).filter { now.timeIntervalSince($0) < 60 }
    failures[peer.host] = recent
    guard recent.count < 5 else {
      peer.reject("失败次数过多，请一分钟后再试")
      return
    }
    guard hello.version == RemoteProtocol.version else {
      peer.reject("协议版本不一致（Mac \(RemoteProtocol.version)，手机 \(hello.version)），请更新")
      return
    }
    var issued: String?
    if let token = hello.token, let device = devices.authenticate(token: token, clientId: hello.clientId) {
      client.device = device
    } else if let code = hello.pairingCode,
      let paired = try? devices.pair(
        code: code, name: hello.deviceName, clientId: hello.clientId, replacingToken: hello.replacingToken)
    {
      client.device = paired.device
      issued = paired.token
      // Pairing again (e.g. after changing networks) replaces this phone's earlier entry.
      for other in clients.values where other !== client && paired.replaced.contains(other.device?.id ?? "") {
        other.peer.reject("此设备已重新配对")
      }
      audit(
        "REMOTE 已配对设备「\(paired.device.name)」（\(peer.host)）"
          + (paired.replaced.isEmpty ? "" : "，替换了此前的 \(paired.replaced.count) 条配对"))
    } else {
      failures[peer.host, default: []].append(now)
      audit("REMOTE 认证失败（\(peer.host)，\(hello.token == nil ? "配对码" : "令牌")）")
      peer.reject(hello.token == nil ? "配对码无效或已过期" : "此设备未配对或已被吊销，请重新配对")
      return
    }
    guard let device = client.device else { return }
    let addresses = RemoteAddressPolicy.localAddresses()
    peer.send(
      .welcome(
        version: RemoteProtocol.version, serverName: serverName, deviceId: device.id, token: issued,
        hosts: addresses.lan + addresses.tailscale, features: RemoteProtocol.features))
    peer.send(.snapshot(sessions: store.sessions.map(Self.dto)))
    updateConnected()
  }

  private func updateConnected() {
    status.connectedDevices = clients.values.compactMap { $0.device?.name }.sorted()
  }

  // MARK: Sessions

  /// Opaque, stable id: the store key contains the pid, which clients must not see.
  nonisolated static func publicID(_ sessionID: String) -> String {
    SHA256.hash(data: Data(sessionID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func dto(_ s: Session) -> RemoteSession {
    RemoteSession(
      id: publicID(s.id), agent: s.kind.rawValue, name: s.displayName, projectName: s.projectName,
      state: RemoteSessionState(rawValue: s.state.rawValue) ?? .unknown, stateSince: s.stateSince,
      unread: s.unread, currentTool: s.currentTool, attentionMessage: s.attentionMessage,
      lastAssistantSnippet: s.lastAssistantSnippet, model: s.model, gitBranch: s.gitBranch,
      remoteInput: TmuxRemote.canSend(s), lastEventAt: s.lastEventAt, usage: s.usage)
  }

  private func session(publicID: String) -> Session? {
    store.sessions.first { Self.publicID($0.id) == publicID }
  }

  private var authenticated: [Client] { clients.values.filter { $0.device != nil } }

  private func publishSessions() {
    var current: [String: RemoteSession] = [:]
    for session in store.sessions { current[Self.publicID(session.id)] = Self.dto(session) }
    let receivers = authenticated
    for (id, value) in current where published[id] != value {
      for client in receivers { client.peer.send(.sessionUpdated(value)) }
    }
    for id in published.keys where current[id] == nil {
      for client in receivers { client.peer.send(.sessionRemoved(sessionId: id)) }
    }
    published = current
  }

  // MARK: Subscriptions

  /// Entries per transcript batch (first screen, and each page further back).
  static let pageSize = 100

  private func refreshTranscripts() async {
    for client in authenticated {
      for (id, subscription) in client.transcripts where subscription.ready {
        // /clear or /new started another thread: start over from its transcript.
        if let session = session(publicID: id), session.currentSessionId != subscription.thread {
          openTranscript(id, for: client)
          continue
        }
        guard let feed = subscription.feed else { continue }
        do {
          let (entries, reset) = try await Task.detached(priority: .utility) { try feed.poll() }.value
          guard client.transcripts[id] === subscription else { continue }
          if reset {
            let latest = feed.latest(Self.pageSize)
            client.peer.send(.transcript(sessionId: id, entries: latest.entries, reset: true, hasOlder: latest.hasOlder))
          } else if !entries.isEmpty {
            client.peer.send(.transcript(sessionId: id, entries: entries, reset: false, hasOlder: false))
          }
        } catch {
          client.transcripts.removeValue(forKey: id)
          client.peer.send(.error(message: "对话读取失败：\(error.localizedDescription)"))
        }
      }
    }
  }

  private func refreshPanes() async {
    for client in authenticated {
      for (id, previous) in client.panes {
        guard let session = session(publicID: id) else { continue }
        guard let screen = try? await TmuxRemote.screen(session) else { continue }
        // The client may have unsubscribed while capturing.
        guard client.panes[id] != nil, screen.styled != previous else { continue }
        client.panes[id] = screen.styled
        client.peer.send(.pane(Self.pane(id: id, screen: screen)))
      }
    }
  }

  nonisolated static func pane(id: String, screen: TmuxRemote.Screen) -> PaneSnapshot {
    PaneSnapshot(
      sessionId: id,
      text: screen.styled.components(separatedBy: "\n").suffix(TmuxRemote.scrollback + 60).joined(separator: "\n"),
      menu: PaneMenuParser.parse(screen.plain), columns: screen.columns, styled: true)
  }

  /// Starts (or restarts) a conversation feed: parses the history off the main actor, then sends
  /// the newest page as a reset batch.
  private func openTranscript(_ id: String, for client: Client) {
    let peer = client.peer
    guard let session = session(publicID: id) else { return peer.send(.error(message: "会话不存在")) }
    let located = session.kind == .claude
      ? try? ClaudeSource.transcript(of: session)
      : session.transcriptPath.map { URL(fileURLWithPath: $0) }
    // A new session's hooks name the transcript before its first prompt creates the file.
    guard let url = located, FileManager.default.fileExists(atPath: url.path) else {
      // Not written yet; keep the subscription so the thread check retries (announced once).
      let announced = client.transcripts[id].map { $0.feed == nil } ?? false
      let waiting = TranscriptSubscription(feed: nil, thread: "")
      waiting.ready = true
      client.transcripts[id] = waiting
      if !announced { peer.send(.transcript(sessionId: id, entries: [], reset: true, hasOlder: false)) }
      return
    }
    let feed = TranscriptFeed(url: url, kind: session.kind)
    let subscription = TranscriptSubscription(feed: feed, thread: session.currentSessionId)
    client.transcripts[id] = subscription
    Task { [weak self] in
      do {
        try await Task.detached(priority: .userInitiated) { try feed.load() }.value
      } catch {
        if client.transcripts[id] === subscription { client.transcripts.removeValue(forKey: id) }
        return peer.send(.error(message: "对话读取失败：\(error.localizedDescription)"))
      }
      // Superseded by a newer subscription (thread change, resubscribe) while parsing.
      guard self != nil, client.transcripts[id] === subscription else { return }
      subscription.ready = true
      let latest = feed.latest(Self.pageSize)
      peer.send(.transcript(sessionId: id, entries: latest.entries, reset: true, hasOlder: latest.hasOlder))
    }
  }

  // MARK: Actions

  private func perform(_ message: ClientMessage, for client: Client) {
    let peer = client.peer
    switch message {
    case .hello: break
    case .subscribeTranscript(let id):
      openTranscript(id, for: client)
    case .loadOlderTranscript(let id, let beforeId):
      guard let feed = client.transcripts[id]?.feed else { return }
      let page = feed.page(before: beforeId, count: Self.pageSize)
      peer.send(.transcriptOlder(sessionId: id, entries: page.entries, hasOlder: page.hasOlder))
    case .unsubscribeTranscript(let id):
      client.transcripts.removeValue(forKey: id)
    case .subscribePane(let id):
      guard let session = session(publicID: id) else { return peer.send(.error(message: "会话不存在")) }
      guard TmuxRemote.canSend(session) else {
        return peer.send(.error(message: "该会话不在 tmux 中，没有终端画面"))
      }
      client.panes[id] = ""
    case .unsubscribePane(let id):
      client.panes.removeValue(forKey: id)
    case .markRead(let id):
      if let session = session(publicID: id) { store.markRead(session.id) }
    case .requestUsage(let days):
      let first = UsageReport.lastDays(max(1, min(days, 366))).first ?? ""
      peer.send(.usage(rows: (usageRows?() ?? []).filter { $0.day >= first }))
    case .sendMessage(let requestId, let id, let text):
      act(
        requestId: requestId, sessionID: id, client: client, summary: "发送「\(singleLine(text, limit: 80))」",
        confirmed: { before, latest in latest.state == .working && latest.lastEventAt > before.lastEventAt }
      ) { [weak self] session, isConfirmed in
        try await TmuxRemote.sendText(text, to: session) {
          await MainActor.run { self?.store.byID[session.id].map(isConfirmed) ?? false }
        }
      }
    case .sendKey(let requestId, let id, let key):
      act(
        requestId: requestId, sessionID: id, client: client, summary: "按键 \(key.rawValue)",
        confirmed: { before, latest in
          key == .escape
            ? before.state == .working && latest.state != .working
            : latest.state != before.state || latest.lastEventAt > before.lastEventAt
        }
      ) { session, _ in
        try await TmuxRemote.sendKey(key, to: session)
      }
    }
  }

  /// Runs a tmux action, audits it, then reports delivered once `confirmed(before, latest)` holds
  /// within the confirmation window (a message: the agent started working; Escape: it stopped;
  /// unconfirmed otherwise, e.g. Codex Esc fires no hook).
  private func act(
    requestId: String, sessionID: String, client: Client, summary: String,
    confirmed: @escaping @Sendable (Session, Session) -> Bool,
    _ action: @escaping @Sendable (Session, @escaping @Sendable (Session) -> Bool) async throws -> Void
  ) {
    let peer = client.peer
    let device = client.device?.name ?? "?"
    guard let session = session(publicID: sessionID) else {
      return peer.send(.actionResult(requestId: requestId, status: .rejected, message: "会话不存在"))
    }
    let isConfirmed: @Sendable (Session) -> Bool = { confirmed(session, $0) }
    Task { [weak self] in
      guard let self else { return }
      do {
        try await action(session, isConfirmed)
      } catch {
        let message = (error as? RemoteRejection)?.message ?? "发送失败：\(error.localizedDescription)"
        audit("REMOTE 「\(device)」→ \(session.displayName)：\(summary) 被拒绝（\(message)）")
        return peer.send(.actionResult(requestId: requestId, status: .rejected, message: message))
      }
      audit("REMOTE 「\(device)」→ \(session.displayName)：\(summary)")
      let deadline = Date().addingTimeInterval(Self.confirmationWindow)
      while Date() < deadline {
        if let latest = store.byID[session.id], isConfirmed(latest) {
          return peer.send(.actionResult(requestId: requestId, status: .delivered, message: nil))
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
      peer.send(.actionResult(requestId: requestId, status: .unconfirmed, message: "已输入终端，暂未看到会话响应"))
    }
  }
}
