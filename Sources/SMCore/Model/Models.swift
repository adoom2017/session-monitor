import Foundation
import SMProtocol

public enum MonitorError: Error, LocalizedError, Sendable, Equatable {
  case invalid(String)
  case system(String, Int32)
  case unsupported(String)
  case staleEvent(String)
  case command(String, Int32)
  case timeout(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let context): "Invalid data: \(context)"
    case .system(let operation, let code): "\(operation): errno \(code)"
    case .unsupported(let feature): "Unsupported: \(feature)"
    case .staleEvent(let session): "Rejected stale event for \(session)"
    case .command(let command, let status): "\(command) exited with status \(status)"
    case .timeout(let operation): "Timed out: \(operation)"
    }
  }
}

public enum DiagnosticLevel: String, Codable, Sendable { case info, warning, error }

public struct Diagnostic: Sendable, Equatable {
  public var level: DiagnosticLevel
  public var message: String
  public init(_ level: DiagnosticLevel, _ message: String) {
    self.level = level
    self.message = message
  }
  public var logLine: String { "[\(level.rawValue)] \(message)" }
}

public enum JSONValue: Codable, Sendable, Equatable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    // These probes dispatch JSON scalar/container types. The final decode
    // still throws for invalid data; no transport or domain error is ignored.
    if c.decodeNil() {
      self = .null
    } else if let value = try? c.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? c.decode(Double.self) {
      self = .number(value)
    } else if let value = try? c.decode(String.self) {
      self = .string(value)
    } else if let value = try? c.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let value): try c.encode(value)
    case .array(let value): try c.encode(value)
    case .string(let value): try c.encode(value)
    case .number(let value): try c.encode(value)
    case .bool(let value): try c.encode(value)
    case .null: try c.encodeNil()
    }
  }

  public subscript(_ key: String) -> JSONValue? { object?[key] }
  public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  public var number: Double? { if case .number(let v) = self { v } else { nil } }
  public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }

  public func requiredString(_ key: String) throws -> String {
    guard let value = self[key]?.string, !value.isEmpty else {
      throw MonitorError.invalid("missing/invalid \(key)")
    }
    return value
  }
  public func optionalString(_ key: String) throws -> String? {
    guard let value = self[key], value != .null else { return nil }
    guard let text = value.string else { throw MonitorError.invalid("invalid type for \(key)") }
    return text
  }
}

public enum AgentKind: String, Codable, Sendable { case claude, codex }
public enum SessionState: String, Codable, Sendable {
  case working, needsPermission, needsInput, done, idle, ended, unknown
}
public enum DataSource: String, Codable, Sendable {
  case hooks, sessionFileOnly
  /// Codex has no per-process state file; the row comes from scanning running `codex` TUIs.
  case processScan
}

public struct HookEnvelope: Codable, Sendable, Equatable {
  public var v: Int
  public var source: String
  public var receivedAt: Double
  public var agentPid: Int32?
  public var env: [String: String?]
  public var payload: JSONValue
  public var diagnostics: [String]?
  public var diagnosticLevel: DiagnosticLevel?
  private enum CodingKeys: String, CodingKey {
    case v, source, receivedAt, agentPid, env, payload, diagnostics, diagnosticLevel
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(v, forKey: .v)
    try c.encode(source, forKey: .source)
    try c.encode(receivedAt, forKey: .receivedAt)
    try c.encode(agentPid, forKey: .agentPid)
    try c.encode(env, forKey: .env)
    try c.encode(payload, forKey: .payload)
    try c.encodeIfPresent(diagnostics, forKey: .diagnostics)
    try c.encodeIfPresent(diagnosticLevel, forKey: .diagnosticLevel)
  }

  public init(
    source: String, receivedAt: Double = Date().timeIntervalSince1970 * 1000, agentPid: Int32?,
    env: [String: String?] = [:], payload: JSONValue
  ) {
    self.v = 1
    self.source = source
    self.receivedAt = receivedAt
    self.agentPid = agentPid
    self.env = env
    self.payload = payload
    self.diagnostics = nil
    self.diagnosticLevel = nil
  }
}

public struct TerminalInfo: Codable, Sendable, Equatable {
  public var tmuxPane: String?
  public var tmuxSocket: String?
  public var termProgram: String?
  public var itermSessionId: String?
  public var tty: String?
  public var entrypoint: String?

  public init(
    tmuxPane: String? = nil, tmuxSocket: String? = nil, termProgram: String? = nil,
    itermSessionId: String? = nil, tty: String? = nil, entrypoint: String? = nil
  ) {
    self.tmuxPane = tmuxPane
    self.tmuxSocket = tmuxSocket
    self.termProgram = termProgram
    self.itermSessionId = itermSessionId
    self.tty = tty
    self.entrypoint = entrypoint
  }

  public mutating func merge(_ newer: TerminalInfo) {
    if let v = newer.tmuxPane { tmuxPane = v }
    if let v = newer.tmuxSocket { tmuxSocket = v }
    if let v = newer.termProgram { termProgram = v }
    if let v = newer.itermSessionId { itermSessionId = v }
    if let v = newer.tty { tty = v }
    if let v = newer.entrypoint { entrypoint = v }
  }
}

public enum EventType: Equatable, Sendable {
  case sessionStart(reason: String?)
  case promptSubmitted
  case toolStart(name: String, summary: String?)
  case toolEnd(name: String)
  case permissionRequested(tool: String?, message: String?)
  case notification(kind: String?, message: String?)
  case stop, subagentStart, subagentStop, compacting
  /// The user aborted the running turn (Codex: rollout `turn_aborted`); they are at the terminal.
  case interrupted
  case sessionEnd(reason: String?)

  public var logLabel: String {
    switch self {
    case .sessionStart: "sessionStart"
    case .promptSubmitted: "promptSubmitted"
    case .toolStart(let name, _): "toolStart(\(singleLine(name, limit: 80)))"
    case .toolEnd(let name): "toolEnd(\(singleLine(name, limit: 80)))"
    case .permissionRequested(let tool, _):
      "permissionRequested(\(singleLine(tool ?? "unknown", limit: 80)))"
    case .notification(let kind, _): "notification(\(singleLine(kind ?? "unknown", limit: 80)))"
    case .stop: "stop"
    case .subagentStart: "subagentStart"
    case .subagentStop: "subagentStop"
    case .compacting: "compacting"
    case .interrupted: "interrupted"
    case .sessionEnd: "sessionEnd"
    }
  }
}

public struct AgentEvent: Sendable, Equatable {
  public var kind: AgentKind
  public var sessionId: String
  public var agentPid: Int32?
  public var agentId: String?
  /// `Stop.last_assistant_message` (Claude and Codex): the reply snippet without reading transcripts.
  public var assistantMessage: String?
  public var cwd: String?
  public var transcriptPath: String?
  public var at: Date
  public var type: EventType
  public var terminal: TerminalInfo
  public var key: String { Session.key(kind: kind, pid: agentPid, sessionId: sessionId) }

  public init(
    kind: AgentKind = .claude, sessionId: String, agentPid: Int32?, cwd: String? = nil,
    transcriptPath: String? = nil, agentId: String? = nil, assistantMessage: String? = nil,
    at: Date = Date(), type: EventType,
    terminal: TerminalInfo = TerminalInfo()
  ) {
    self.kind = kind
    self.sessionId = sessionId
    self.agentPid = agentPid
    self.agentId = agentId
    self.assistantMessage = assistantMessage
    self.cwd = cwd
    self.transcriptPath = transcriptPath
    self.at = at
    self.type = type
    self.terminal = terminal
  }
}

public func singleLine(_ value: String, limit: Int) -> String {
  String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
}

public struct Session: Identifiable, Sendable, Equatable {
  public internal(set) var id: String
  public let kind: AgentKind
  public var pid: Int32?
  public var currentSessionId: String
  public var cwd: String?
  public var projectName: String
  public var explicitName: String?
  public var title: String?
  public var displayName: String { explicitName ?? title ?? projectName }
  public var state: SessionState = .unknown
  public var stateSince: Date
  public var unread = false
  public var currentTool: String?
  public var attentionMessage: String?
  public var lastAssistantSnippet: String?
  public var runningSubagents = 0
  public var model: String?
  public var gitBranch: String?
  public var terminal: TerminalInfo
  public var transcriptPath: String?
  public var lastEventAt: Date
  public var endedAt: Date?
  public var rawStatus: String?
  public var source: DataSource = .hooks
  /// Tokens of the current thread, read from its transcript (UsageTracker).
  public var usage: SessionUsage?

  public init(event: AgentEvent) {
    id = event.key
    kind = event.kind
    pid = event.agentPid
    currentSessionId = event.sessionId
    cwd = event.cwd
    projectName = Self.projectName(cwd: event.cwd)
    stateSince = event.at
    terminal = event.terminal
    transcriptPath = event.transcriptPath
    lastEventAt = event.at
  }

  public static func key(kind: AgentKind, pid: Int32?, sessionId: String) -> String {
    if let pid { return "\(kind.rawValue):\(pid)" }
    return "\(kind.rawValue):sid:\(sessionId)"
  }

  public static func projectName(cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "Unknown project" }
    for marker in ["/.claude/worktrees/", "/.worktrees/"] {
      if let range = cwd.range(of: marker) {
        return URL(fileURLWithPath: String(cwd[..<range.lowerBound])).lastPathComponent
      }
    }
    return URL(fileURLWithPath: cwd).lastPathComponent
  }

  /// Depends on state only, never on `unread`: clicking a row (mark read) must not move it.
  public var sortRank: Int {
    switch state {
    case .needsPermission: 0
    case .needsInput: 1
    case .done: 2
    case .working: 3
    default: 4
    }
  }

  public static func ordered(_ lhs: Session, _ rhs: Session) -> Bool {
    if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
    if lhs.stateSince != rhs.stateSince { return lhs.stateSince < rhs.stateSince }
    return lhs.id < rhs.id
  }
}
