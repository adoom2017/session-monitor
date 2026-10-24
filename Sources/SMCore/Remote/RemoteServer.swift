import Foundation
import Network
import SMProtocol

/// One phone connection. Sending is thread-safe.
public final class RemotePeer: @unchecked Sendable, Hashable {
  public let id = UUID()
  public let host: String
  private let connection: NWConnection

  init(connection: NWConnection, host: String) {
    self.connection = connection
    self.host = host
  }

  public func send(_ message: ServerMessage) {
    guard let data = try? RemoteProtocol.encoder().encode(message) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
  }

  public func close() { connection.cancel() }

  /// Sends the error, then closes once it is on the wire (closing right away dropped the message,
  /// so a revoked phone only saw a reset and kept retrying).
  public func reject(_ message: String) {
    guard let data = try? RemoteProtocol.encoder().encode(ServerMessage.error(message: message)) else {
      return close()
    }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "error", metadata: [metadata])
    connection.send(
      content: data, contentContext: context, isComplete: true,
      completion: .contentProcessed { [connection] _ in connection.cancel() })
  }

  public static func == (a: RemotePeer, b: RemotePeer) -> Bool { a.id == b.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// WebSocket-over-TLS listener for phone clients (DEV_SPEC §17.3). Transport only: address
/// filtering, framing and decoding; everything else is the handler's (RemoteHub).
public final class RemoteServer: @unchecked Sendable {
  public enum Event: Sendable {
    case connected(RemotePeer)
    case message(RemotePeer, ClientMessage)
    case disconnected(RemotePeer)
    case rejected(host: String, reason: String)
    case failed(String)
    case ready(port: UInt16)
  }

  private let queue = DispatchQueue(label: "sessionmonitor.remote")
  private var listener: NWListener?
  private var peers: [UUID: RemotePeer] = [:]
  private let handler: @Sendable (Event) -> Void

  public init(handler: @escaping @Sendable (Event) -> Void) {
    self.handler = handler
  }

  public func start(identity: RemoteIdentity, port: UInt16, serviceName: String?) throws {
    let tls = NWProtocolTLS.Options()
    guard let secIdentity = sec_identity_create(identity.identity) else {
      throw MonitorError.invalid("TLS identity")
    }
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    let websocket = NWProtocolWebSocket.Options()
    websocket.autoReplyPing = true
    websocket.maximumMessageSize = 1_048_576
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    parameters.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw MonitorError.invalid("port \(port)") }
    let listener = try NWListener(using: parameters, on: nwPort)
    if let serviceName {
      listener.service = NWListener.Service(name: serviceName, type: RemoteProtocol.serviceType)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      switch state {
      case .ready: self?.handler(.ready(port: listener?.port?.rawValue ?? port))
      case .failed(let error): self?.handler(.failed(error.localizedDescription))
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    self.listener = listener
    listener.start(queue: queue)
  }

  public func stop() {
    queue.sync {
      listener?.cancel()
      listener = nil
      for peer in peers.values { peer.close() }
      peers.removeAll()
    }
  }

  private func accept(_ connection: NWConnection) {
    let host: String
    switch connection.endpoint {
    case .hostPort(let value, _):
      switch value {
      case .ipv4(let address): host = "\(address)"
      case .ipv6(let address): host = "\(address)"
      case .name(let name, _): host = name
      @unknown default: host = "\(value)"
      }
    default: host = "\(connection.endpoint)"
    }
    guard RemoteAddressPolicy.isAllowed(host) else {
      connection.cancel()
      handler(.rejected(host: host, reason: "来源地址不在局域网或 Tailscale 范围内"))
      return
    }
    let peer = RemotePeer(connection: connection, host: host)
    peers[peer.id] = peer
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready: handler(.connected(peer))
      case .failed, .cancelled:
        if peers.removeValue(forKey: peer.id) != nil { handler(.disconnected(peer)) }
      default: break
      }
    }
    receive(connection, peer: peer)
    connection.start(queue: queue)
  }

  private func receive(_ connection: NWConnection, peer: RemotePeer) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        return
      }
      if let data, !data.isEmpty,
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
          as? NWProtocolWebSocket.Metadata
      {
        switch metadata.opcode {
        case .text, .binary:
          do { handler(.message(peer, try RemoteProtocol.decoder().decode(ClientMessage.self, from: data))) } catch {
            peer.send(.error(message: "无法解析的消息"))
          }
        case .close:
          connection.cancel()
          return
        default: break
        }
      }
      receive(connection, peer: peer)
    }
  }
}
