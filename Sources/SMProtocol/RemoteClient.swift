import CryptoKit
import Foundation
import Network
import Security

public enum RemoteClientError: Error, LocalizedError, Sendable, Equatable {
  case invalidPairingLink
  case fingerprintMismatch
  case unexpectedMessage
  case rejected(String)
  case unreachable([String])

  public var errorDescription: String? {
    switch self {
    case .invalidPairingLink: "不是有效的 SessionMonitor 配对链接"
    case .fingerprintMismatch: "服务器证书与配对时不一致，已拒绝连接"
    case .unexpectedMessage: "服务器返回了意外的消息"
    case .rejected(let message): message
    case .unreachable(let errors): "无法连接到 Mac：" + errors.joined(separator: "；")
    }
  }

  /// A wrong certificate or a refused token will not get better on another address.
  var isFinal: Bool {
    switch self {
    case .fingerprintMismatch, .rejected: true
    default: false
    }
  }
}

public enum RemoteFingerprint {
  /// SHA-256 of a certificate's DER bytes, lowercase hex.
  public static func sha256Hex(_ der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
  }
}

/// One WebSocket connection to a Mac, pinned to the certificate fingerprint from pairing.
/// Usage: `RemoteConnection.connect(...)` performs the hello handshake and returns the open
/// connection with the welcome; then iterate `messages` and call `send`.
///
/// Network.framework rather than URLSession: App Transport Security applies to URLSession even
/// when the delegate accepts the pinned certificate, and its NSAllowsLocalNetworking exemption
/// does not cover Tailscale's 100.64/10, so connections over Tailscale failed with -1200.
public final class RemoteConnection: @unchecked Sendable {
  public struct Welcome: Sendable, Equatable {
    public var serverName: String
    public var deviceId: String
    /// Set only when this connection paired with a code.
    public var token: String?
    /// The address that answered.
    public var host: String
    /// The Mac's current addresses, if it reports them.
    public var hosts: [String]?
    /// Optional abilities of the Mac (RemoteProtocol.features); empty for older Macs.
    public var features: [String] = []

    /// Addresses to store for next time: the one that answered, then what the Mac reports
    /// (replacing addresses from networks it has left), else the previous list.
    public func addresses(previous: [String]) -> [String] {
      var seen: Set<String> = []
      return ([host] + (hosts ?? previous)).filter { seen.insert($0).inserted }
    }
  }

  /// Checks the server certificate against the fingerprint from pairing, in the TLS verify block.
  private final class Pin: @unchecked Sendable {
    let fingerprint: String
    private let lock = NSLock()
    private var failed = false
    var mismatch: Bool { lock.withLock { failed } }

    init(_ fingerprint: String) { self.fingerprint = fingerprint.lowercased() }

    func check(_ trust: sec_trust_t) -> Bool {
      let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
      let matches = chain?.first.map { RemoteFingerprint.sha256Hex(SecCertificateCopyData($0) as Data) } == fingerprint
      if !matches { lock.withLock { failed = true } }
      return matches
    }
  }

  private let pin: Pin
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "sessionmonitor.remote.client")
  private let lock = NSLock()
  private var timedOut = false
  private var opening: CheckedContinuation<Void, any Error>?

  /// Connecting, TLS, hello and welcome together must finish within this.
  static let handshakeTimeout: TimeInterval = 6

  private init(host: String, port: UInt16, fingerprint: String) throws {
    let address = host.contains(":") ? "[\(host)]" : host
    guard let url = URL(string: "wss://\(address):\(port)/") else {
      throw RemoteClientError.rejected("地址无效：\(host)")
    }
    let pin = Pin(fingerprint)
    self.pin = pin
    let tls = NWProtocolTLS.Options()
    // The self-signed certificate is trusted only by its pinned fingerprint, never by a CA. Set
    // before building the parameters, which copy the options.
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions, { _, trust, complete in complete(pin.check(trust)) }, queue)
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = Int(Self.handshakeTimeout)
    let parameters = NWParameters(tls: tls, tcp: tcp)
    let websocket = NWProtocolWebSocket.Options()
    websocket.autoReplyPing = true
    websocket.maximumMessageSize = 8 * 1024 * 1024
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    // A URL endpoint: with a bare host and port the WebSocket upgrade has no request target and
    // the connection is aborted.
    connection = NWConnection(to: .url(url), using: parameters)
  }

  private enum Attempt: Sendable {
    case connected(RemoteConnection, Welcome)
    case failed(String, any Error)
  }

  /// Delay between starting attempts: the first address (the one that answered last time) usually
  /// wins before the others start, so the Mac does not see a burst of connections.
  static let stagger = Duration.milliseconds(300)

  /// Tries `hosts` concurrently, staggered in order with LAN addresses first, and returns the
  /// first connection that completes the handshake. Off the LAN, the stale LAN addresses no
  /// longer hold back the Tailscale one by their timeouts; on it, the LAN wins by its head start.
  public static func connect(
    hosts: [String], port: UInt16, fingerprint: String, hello: Hello
  ) async throws -> (RemoteConnection, Welcome) {
    let hosts = RemoteAddressRange.preferringLAN(hosts)
    let (results, sink) = AsyncStream.makeStream(of: Attempt.self)
    let attempts = hosts.enumerated().map { index, host in
      Task {
        do { try await Task.sleep(for: stagger * index) } catch {
          sink.yield(.failed(host, error))
          return
        }
        do {
          let connection = try RemoteConnection(host: host, port: port, fingerprint: fingerprint)
          do {
            sink.yield(.connected(connection, try await connection.handshake(host: host, hello: hello)))
          } catch {
            connection.close()
            throw error
          }
        } catch {
          sink.yield(.failed(host, error))
        }
      }
    }
    var finished = 0
    var errors: [String] = []
    // Handshakes still under way are not waited for; one that also succeeds is closed.
    func abandonRest() {
      for attempt in attempts { attempt.cancel() }
      let pending = hosts.count - finished
      Task {
        for await late in results.prefix(pending) {
          if case .connected(let extra, _) = late { extra.close() }
        }
      }
    }
    for await attempt in results.prefix(hosts.count) {
      finished += 1
      switch attempt {
      case .connected(let connection, let welcome):
        abandonRest()
        return (connection, welcome)
      case .failed(_, let error as RemoteClientError) where error.isFinal:
        abandonRest()
        throw error
      case .failed(let host, let error):
        errors.append("\(host)：\(error.localizedDescription)")
      }
    }
    throw RemoteClientError.unreachable(errors)
  }

  private func handshake(host: String, hello: Hello) async throws -> Welcome {
    let deadline = DispatchWorkItem { [self] in
      lock.withLock { timedOut = true }
      connection.cancel()
    }
    queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: deadline)
    defer { deadline.cancel() }
    do {
      try await open()
      try await send(.hello(hello))
      switch try await receive() {
      case .welcome(let version, let serverName, let deviceId, let token, let hosts, let features):
        guard version == RemoteProtocol.version else {
          throw RemoteClientError.rejected("协议版本不一致（Mac \(version)，本机 \(RemoteProtocol.version)），请更新")
        }
        return Welcome(
          serverName: serverName, deviceId: deviceId, token: token, host: host, hosts: hosts, features: features ?? [])
      case .error(let message): throw RemoteClientError.rejected(message)
      default: throw RemoteClientError.unexpectedMessage
      }
    } catch {
      if pin.mismatch { throw RemoteClientError.fingerprintMismatch }
      if lock.withLock({ timedOut }) { throw NWError.posix(.ETIMEDOUT) }
      throw error
    }
  }

  /// Starts the connection and waits until TCP, TLS and the WebSocket upgrade are done. No route
  /// (`waiting`) fails at once instead of waiting for the network to change.
  private func open() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { opening = continuation }
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        let result: Result<Void, any Error>
        switch state {
        case .ready: result = .success(())
        case .waiting(let error), .failed(let error): result = .failure(error)
        case .cancelled: result = .failure(NWError.posix(.ECANCELED))
        default: return
        }
        lock.withLock { () -> CheckedContinuation<Void, any Error>? in
          defer { opening = nil }
          return opening
        }?.resume(with: result)
      }
      connection.start(queue: queue)
    }
  }

  public func send(_ message: ClientMessage) async throws {
    let data = try RemoteProtocol.encoder().encode(message)
    let context = NWConnection.ContentContext(
      identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data, contentContext: context, isComplete: true,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }

  private func receive() async throws -> ServerMessage {
    while true {
      let (data, opcode) = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<(Data?, NWProtocolWebSocket.Opcode?), any Error>) in
        connection.receiveMessage { data, context, _, error in
          if let error { return continuation.resume(throwing: error) }
          let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
          continuation.resume(returning: (data, (metadata as? NWProtocolWebSocket.Metadata)?.opcode))
        }
      }
      switch opcode {
      case .text?, .binary?:
        guard let data, !data.isEmpty else { continue }
        return try RemoteProtocol.decoder().decode(ServerMessage.self, from: data)
      case .close?, nil:
        // nil: the connection ended without a close frame.
        throw NWError.posix(.ECONNRESET)
      default:
        continue  // ping and pong
      }
    }
  }

  /// Server messages after the welcome; finishes (throwing) when the connection drops.
  public var messages: AsyncThrowingStream<ServerMessage, any Error> {
    AsyncThrowingStream { continuation in
      let reader = Task {
        do {
          while !Task.isCancelled { continuation.yield(try await self.receive()) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in reader.cancel() }
    }
  }

  public func close() { connection.cancel() }
}
