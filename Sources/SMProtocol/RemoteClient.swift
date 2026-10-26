import CryptoKit
import Foundation
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
public final class RemoteConnection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

  private let fingerprint: String
  private var session: URLSession!
  private var task: URLSessionWebSocketTask!
  private let lock = NSLock()
  private var pinMismatch = false

  private init(fingerprint: String) {
    self.fingerprint = fingerprint.lowercased()
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 6
    configuration.waitsForConnectivity = false
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  /// Tries `hosts` in order and returns the first connection that completes the handshake.
  public static func connect(
    hosts: [String], port: UInt16, fingerprint: String, hello: Hello
  ) async throws -> (RemoteConnection, Welcome) {
    var errors: [String] = []
    for host in hosts {
      let connection = RemoteConnection(fingerprint: fingerprint)
      do {
        let welcome = try await connection.handshake(host: host, port: port, hello: hello)
        return (connection, welcome)
      } catch let error as RemoteClientError {
        connection.close()
        // A wrong certificate or a refused token will not get better on another address.
        switch error {
        case .fingerprintMismatch, .rejected: throw error
        default: errors.append("\(host)：\(error.localizedDescription)")
        }
      } catch {
        connection.close()
        errors.append("\(host)：\(error.localizedDescription)")
      }
    }
    throw RemoteClientError.unreachable(errors)
  }

  private func handshake(host: String, port: UInt16, hello: Hello) async throws -> Welcome {
    let address = host.contains(":") ? "[\(host)]" : host
    guard let url = URL(string: "wss://\(address):\(port)/") else {
      throw RemoteClientError.rejected("地址无效：\(host)")
    }
    task = session.webSocketTask(with: url)
    task.maximumMessageSize = 8 * 1024 * 1024
    task.resume()
    do {
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
      if lock.withLock({ pinMismatch }) { throw RemoteClientError.fingerprintMismatch }
      throw error
    }
  }

  public func send(_ message: ClientMessage) async throws {
    let data = try RemoteProtocol.encoder().encode(message)
    try await task.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private func receive() async throws -> ServerMessage {
    let data: Data
    switch try await task.receive() {
    case .string(let text): data = Data(text.utf8)
    case .data(let value): data = value
    @unknown default: throw RemoteClientError.unexpectedMessage
    }
    return try RemoteProtocol.decoder().decode(ServerMessage.self, from: data)
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

  public func close() {
    task?.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else { return (.performDefaultHandling, nil) }
    // The self-signed certificate is trusted only by its pinned fingerprint, never by a CA.
    guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
      RemoteFingerprint.sha256Hex(SecCertificateCopyData(leaf) as Data) == fingerprint
    else {
      lock.withLock { pinMismatch = true }
      return (.cancelAuthenticationChallenge, nil)
    }
    return (.useCredential, URLCredential(trust: trust))
  }
}
