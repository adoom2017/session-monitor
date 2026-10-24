import Foundation

/// Wire format between SessionMonitor on the Mac and its phone clients (DEV_SPEC §17.4): one JSON
/// object per WebSocket text frame. Bump `version` on any incompatible change.
public enum RemoteProtocol {
  public static let version = 1
  public static let serviceType = "_sessionmonitor._tcp"
  public static let defaultPort: UInt16 = 47821
  /// Longest message text accepted for one `sendMessage`.
  public static let maxMessageLength = 8000

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

/// Session state as shown to clients; mirrors SMCore's SessionState.
public enum RemoteSessionState: String, Codable, Sendable {
  case working, needsPermission, needsInput, done, idle, unknown, ended
}

/// One session row. Deliberately without pid, tty or paths: clients only display and address it.
public struct RemoteSession: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var agent: String
  public var name: String
  public var projectName: String
  public var state: RemoteSessionState
  public var stateSince: Date
  public var unread: Bool
  public var currentTool: String?
  public var attentionMessage: String?
  public var lastAssistantSnippet: String?
  public var model: String?
  public var gitBranch: String?
  /// Messages and keys can be sent (the session runs in a tmux pane and has not ended).
  public var remoteInput: Bool
  public var lastEventAt: Date

  public init(
    id: String, agent: String, name: String, projectName: String, state: RemoteSessionState,
    stateSince: Date, unread: Bool, currentTool: String?, attentionMessage: String?,
    lastAssistantSnippet: String?, model: String?, gitBranch: String?, remoteInput: Bool,
    lastEventAt: Date
  ) {
    self.id = id
    self.agent = agent
    self.name = name
    self.projectName = projectName
    self.state = state
    self.stateSince = stateSince
    self.unread = unread
    self.currentTool = currentTool
    self.attentionMessage = attentionMessage
    self.lastAssistantSnippet = lastAssistantSnippet
    self.model = model
    self.gitBranch = gitBranch
    self.remoteInput = remoteInput
    self.lastEventAt = lastEventAt
  }
}

public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable {
  public enum Role: String, Codable, Sendable { case user, assistant, tool }
  public var id: String
  public var role: Role
  public var text: String
  public var at: Date?

  public init(id: String, role: Role, text: String, at: Date?) {
    self.id = id
    self.role = role
    self.text = text
    self.at = at
  }
}

/// A numbered choice visible in the terminal (permission prompt, question, update notice…).
public struct MenuOption: Codable, Sendable, Equatable {
  public var number: Int
  public var label: String
  public var selected: Bool

  public init(number: Int, label: String, selected: Bool) {
    self.number = number
    self.label = label
    self.selected = selected
  }
}

public struct PaneSnapshot: Codable, Sendable, Equatable {
  public var sessionId: String
  public var text: String
  public var menu: [MenuOption]

  public init(sessionId: String, text: String, menu: [MenuOption]) {
    self.sessionId = sessionId
    self.text = text
    self.menu = menu
  }
}

/// Keys a client may send; anything else is rejected by the server.
public enum RemoteKey: String, Codable, Sendable, CaseIterable {
  case escape = "Escape", enter = "Enter", up = "Up", down = "Down", tab = "Tab"
  case digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4", digit5 = "5"
  case digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"

  public static func digit(_ n: Int) -> RemoteKey? { RemoteKey(rawValue: String(n)) }
}

public struct Hello: Codable, Sendable, Equatable {
  public var version: Int
  public var deviceName: String
  /// Either a device token from an earlier pairing, or a one-time pairing code.
  public var token: String?
  public var pairingCode: String?

  public init(version: Int = RemoteProtocol.version, deviceName: String, token: String?, pairingCode: String?) {
    self.version = version
    self.deviceName = deviceName
    self.token = token
    self.pairingCode = pairingCode
  }
}

public enum ClientMessage: Codable, Sendable, Equatable {
  case hello(Hello)
  case subscribeTranscript(sessionId: String)
  case unsubscribeTranscript(sessionId: String)
  case subscribePane(sessionId: String)
  case unsubscribePane(sessionId: String)
  case sendMessage(requestId: String, sessionId: String, text: String)
  case sendKey(requestId: String, sessionId: String, key: RemoteKey)
  case markRead(sessionId: String)
}

public enum ActionStatus: String, Codable, Sendable {
  /// Typed into the pane and the agent reacted (a hook event arrived).
  case delivered
  /// Typed into the pane; no reaction seen within the confirmation window.
  case unconfirmed
  /// Not sent (see message).
  case rejected
}

public enum ServerMessage: Codable, Sendable, Equatable {
  /// `token` is set only right after pairing; the client stores it for later connections.
  case welcome(version: Int, serverName: String, deviceId: String, token: String?)
  case snapshot(sessions: [RemoteSession])
  case sessionUpdated(RemoteSession)
  case sessionRemoved(sessionId: String)
  /// `reset`: replaces what the client holds for this session (first batch after subscribing).
  case transcript(sessionId: String, entries: [TranscriptEntry], reset: Bool)
  case pane(PaneSnapshot)
  case actionResult(requestId: String, status: ActionStatus, message: String?)
  case error(message: String)
}

/// What the pairing QR code carries.
public struct PairingPayload: Codable, Sendable, Equatable {
  public var serverName: String
  /// Addresses to try in order (LAN first, then Tailscale).
  public var hosts: [String]
  public var port: UInt16
  /// SHA-256 of the server certificate (DER), lowercase hex.
  public var fingerprint: String
  public var code: String

  public init(serverName: String, hosts: [String], port: UInt16, fingerprint: String, code: String) {
    self.serverName = serverName
    self.hosts = hosts
    self.port = port
    self.fingerprint = fingerprint
    self.code = code
  }

  /// `sessionmonitor://pair?d=<base64url JSON>`
  public var url: URL {
    let json = (try? JSONEncoder().encode(self)) ?? Data()
    var components = URLComponents()
    components.scheme = "sessionmonitor"
    components.host = "pair"
    components.queryItems = [URLQueryItem(name: "d", value: json.base64URLEncoded())]
    return components.url!
  }

  public init(url: URL) throws {
    guard url.scheme == "sessionmonitor", url.host == "pair",
      let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "d" })?.value,
      let data = Data(base64URLEncoded: value)
    else { throw RemoteClientError.invalidPairingLink }
    self = try JSONDecoder().decode(PairingPayload.self, from: data)
  }
}

/// A Mac the client has paired with.
public struct PairedServer: Codable, Sendable, Equatable, Identifiable {
  public var id: String { deviceId }
  public var serverName: String
  public var hosts: [String]
  public var port: UInt16
  public var fingerprint: String
  public var deviceId: String
  public var token: String

  public init(serverName: String, hosts: [String], port: UInt16, fingerprint: String, deviceId: String, token: String) {
    self.serverName = serverName
    self.hosts = hosts
    self.port = port
    self.fingerprint = fingerprint
    self.deviceId = deviceId
    self.token = token
  }
}

extension Data {
  func base64URLEncoded() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  init?(base64URLEncoded text: String) {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    self.init(base64Encoded: value)
  }
}
