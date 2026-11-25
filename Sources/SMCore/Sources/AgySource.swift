import Foundation

public struct AgySource: AgentSource {
  public let kind = AgentKind.agy
  /// A turn with no hook activity for this long may be waiting on a permission prompt or have
  /// ended via Esc / permission denial (none of which fire hooks); its tmux pane is then checked.
  public static let quietTurnSeconds: TimeInterval = 8

  public enum QuietPaneState: Sendable, Equatable {
    case needsPermission(message: String)
    case working
    case idle
  }

  let discover: @Sendable () throws -> [AgyProcess]
  let lookupPane: @Sendable (String) async throws -> String?
  let capturePane: @Sendable (Session) async throws -> String
  let home: URL

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    discover: @escaping @Sendable () throws -> [AgyProcess] = AgyDiscovery.runningTUIs,
    lookupPane: @escaping @Sendable (String) async throws -> String? = Jumper.tmuxPane(forTTY:),
    capturePane: @escaping @Sendable (Session) async throws -> String = TmuxRemote.capture
  ) {
    self.home = home
    self.discover = discover
    self.lookupPane = lookupPane
    self.capturePane = capturePane
  }

  public func normalize(_ envelope: HookEnvelope) throws -> AgentEvent {
    let payload = envelope.payload
    let name = try payload.requiredString("hookEventName")
    var mapped = envelope
    mapped.payload = .object([
      "session_id": .string(try payload.requiredString("conversationId")),
      "hook_event_name": .string(name),
      "cwd": payload["cwd"] ?? .null,
      "transcript_path": payload["transcriptPath"] ?? .null,
    ])
    return try HookNormalizer.normalize(mapped, kind: kind, override: { name, _ in
      switch name {
      case "SessionStart": return .sessionStart(reason: nil)
      case "PreInvocation": return .promptSubmitted
      case "PreToolUse":
        guard let toolCall = payload["toolCall"] else {
          throw MonitorError.invalid("missing/invalid toolCall")
        }
        let tool = try toolCall.requiredString("name")
        let args = toolCall["args"]
        if let args, args != .null, args.object == nil {
          throw MonitorError.invalid("toolCall.args must be an object")
        }
        return .toolStart(name: tool, summary: Self.toolSummary(tool: tool, args: args))
      case "PostToolUse":
        guard let toolCall = payload["toolCall"] else {
          throw MonitorError.invalid("missing/invalid toolCall")
        }
        return .toolEnd(name: try toolCall.requiredString("name"))
      case "Stop":
        let reason = try payload.requiredString("terminationReason")
        if reason == "USER_CANCELED" || reason == "ERROR" { return .interrupted }
        if payload["fullyIdle"]?.bool == false { return .notification(kind: nil, message: nil) }
        return .stop
      default: throw MonitorError.unsupported("agy hook \(singleLine(name, limit: 80))")
      }
    })
  }

  static func toolSummary(tool: String, args: JSONValue?) -> String? {
    guard let args else { return nil }
    if tool == "ask_question" {
      if let question = args["questions"]?.array?.first?["question"]?.string {
        let trimmed = singleLine(question, limit: 80)
        return trimmed.isEmpty ? nil : trimmed
      }
      return nil
    }
    for key in ["CommandLine", "command", "toolSummary"] {
      if let value = args[key]?.string, !value.isEmpty { return singleLine(value, limit: 80) }
    }
    for key in ["Path", "file_path", "path", "TargetFile", "AbsolutePath"] {
      if let value = args[key]?.string, !value.isEmpty {
        return URL(fileURLWithPath: value).lastPathComponent
      }
    }
    for key in ["pattern", "query", "url", "description", "Role", "prompt", "Prompt", "title", "brief"] {
      if let value = args[key]?.string, !value.isEmpty { return singleLine(value, limit: 80) }
    }
    return nil
  }

  static func brainDirectory(home: URL) -> URL {
    home.appendingPathComponent(".gemini/antigravity-cli/brain")
  }

  static func transcript(in conversation: URL) -> URL {
    conversation.appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
  }

  public static func transcript(
    of session: Session, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL? {
    if let path = session.transcriptPath, !path.isEmpty { return URL(fileURLWithPath: path) }
    guard !session.currentSessionId.isEmpty,
      !session.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix)
    else { return nil }
    return transcript(in: brainDirectory(home: home).appendingPathComponent(session.currentSessionId))
  }

  static func conversationArgument(from arguments: [String]) -> String? {
    for (index, arg) in arguments.dropFirst().enumerated() {
      if arg.hasPrefix("--conversation=") {
        let value = String(arg.dropFirst("--conversation=".count))
        return value.isEmpty || value.hasPrefix("-") ? nil : value
      }
      if arg == "--conversation" {
        let next = index + 2
        if next < arguments.count {
          let value = arguments[next]
          return value.isEmpty || value.hasPrefix("-") ? nil : value
        }
        return nil
      }
    }
    return nil
  }

  private func conversationID(for process: AgyProcess, after: Date?, allowArgument: Bool) -> String? {
    let since = [process.startTime, after].compactMap { $0 }.max()
    if let contextID = AgyContext.conversationID(home: home, pid: process.pid, startedAt: since) {
      return contextID
    }
    return allowArgument ? process.conversationID : nil
  }

  public static func classifyQuietPane(_ plain: String) -> QuietPaneState? {
    let menu = PaneMenuParser.parse(plain)
    let tail = Array(plain.components(separatedBy: "\n").suffix(20))
    if !menu.isEmpty,
      let header = tail.lastIndex(where: { $0.contains("Requesting permission for:") })
    {
      let detail = tail[(header + 1)...]
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first {
          !$0.isEmpty && !$0.hasPrefix("Run this ") && !$0.hasPrefix("> ") && !$0.hasPrefix("1. ")
        }
      let message = detail.map { singleLine($0, limit: 80) } ?? "请求权限"
      return .needsPermission(message: message.isEmpty ? "请求权限" : message)
    }
    if menu.isEmpty {
      let footer = tail.suffix(3).joined(separator: "\n")
      if footer.contains("? for shortcuts") && !footer.contains("esc to cancel") {
        return .idle
      }
      if footer.contains("esc to cancel"),
        !tail.contains(where: { $0.contains("Requesting permission for:") })
      {
        return .working
      }
    }
    return nil
  }

  public func reconcile(store: SessionStore) async throws {
    let rows = await store.sessions.filter { $0.kind == .agy }
    let byPID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.pid.map { ($0, row) } })
    let pending = Dictionary(
      rows.filter { $0.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) }
        .compactMap { row in row.pid.map { ($0, row.stateSince) } },
      uniquingKeysWith: max)
    for process in try discover() {
      let existing = byPID[process.pid]
      let needsPane = existing == nil || existing?.terminal.tmuxPane == nil || existing?.state == .ended
      let pane = needsPane ? try await lookupPane(process.tty) : nil
      await store.upsertScannedAgy(
        pid: process.pid, cwd: process.cwd,
        terminal: TerminalInfo(tmuxPane: pane, tty: process.tty), now: Date())
      if existing == nil, let id = conversationID(for: process, after: nil, allowArgument: true) {
        await store.adoptScannedAgyConversation(pid: process.pid, conversationID: id)
      } else if let pendingSince = pending[process.pid], existing?.state != .ended,
        let id = conversationID(for: process, after: pendingSince, allowArgument: false)
      {
        await store.adoptScannedAgyConversation(pid: process.pid, conversationID: id)
      }
    }
    await store.mergeSessionIDDuplicates()
    let sessions = await store.sessions.filter { $0.kind == .agy }
    var liveness: [Int32: Bool] = [:]
    for pid in Set(sessions.compactMap(\.pid)) { liveness[pid] = try ProcessLiveness.isAlive(pid) }
    let now = Date()
    await store.reconcile(files: [], liveness: liveness, now: now)
    // Re-read: the liveness pass may have ended sessions, which must not be revived below.
    for session in await store.sessions
    where session.kind == .agy && session.terminal.tmuxPane != nil
      && (session.state == .needsPermission
        || ([.working, .needsInput].contains(session.state)
          && now.timeIntervalSince(session.lastEventAt) >= Self.quietTurnSeconds))
    {
      guard let plain = try? await capturePane(session) else { continue }
      switch Self.classifyQuietPane(plain) {
      case .needsPermission(let message):
        if session.state == .working {
          await store.applyExternalPermission(id: session.id, message: message, at: now)
        }
      case .working:
        if session.state == .needsPermission {
          await store.applyExternalPermissionApproved(id: session.id, at: now)
        }
      case .idle:
        await store.applyExternalTurnEnd(id: session.id, aborted: true, at: now)
      case nil:
        break
      }
    }
  }

  public func enrich(_ session: Session) async throws -> SessionEnrichment? {
    guard !session.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) else { return nil }
    guard let path = Self.transcript(of: session, home: home) else {
      return SessionEnrichment.pendingTranscript(session.id)
    }
    do {
      return try AgyTranscriptReader.read(path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return SessionEnrichment.pendingTranscript(session.id)
    }
  }
}

/// A running interactive Antigravity CLI TUI (not `--hub`, `-p`/`--print`, or utility subcommands).
public struct AgyProcess: Sendable, Equatable {
  public var pid: Int32
  public var tty: String
  public var cwd: String?
  public var startTime: Date?
  /// `agy --conversation <id>`: the thread id is known before any hook fires.
  public var conversationID: String?
  public init(
    pid: Int32, tty: String, cwd: String? = nil, startTime: Date? = nil, conversationID: String? = nil
  ) {
    self.pid = pid
    self.tty = tty
    self.cwd = cwd
    self.startTime = startTime
    self.conversationID = conversationID
  }
}

public enum AgyDiscovery {
  static let nonSessionCommands: Set<String> = [
    "acp", "agent", "agents", "changelog", "help", "install", "mcp", "mic-serve",
    "models", "plugin", "plugins", "remote-control", "update",
  ]
  static let nonSessionFlags: Set<String> = [
    "--hub", "-p", "--print", "--prompt", "-h", "--help", "-v", "--version",
  ]

  public static func runningTUIs() throws -> [AgyProcess] {
    try ProcessIdentity.listAll().compactMap { process in
      guard process.executable == "agy", let tty = process.tty else { return nil }
      return classify(
        pid: process.pid, tty: tty, arguments: ProcessIdentity.arguments(pid: process.pid) ?? [],
        cwd: ProcessIdentity.cwd(pid: process.pid), startTime: process.startTime)
    }
  }

  /// Pure part of discovery, unit-tested with real argv shapes.
  public static func classify(
    pid: Int32, tty: String, arguments: [String], cwd: String?, startTime: Date?
  ) -> AgyProcess? {
    let args = Array(arguments.dropFirst())
    if args.contains(where: { $0.contains(AgyQuotaProbe.probeMarker) }) { return nil }
    for arg in args {
      let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
      if nonSessionFlags.contains(flag) { return nil }
    }
    var index = 0
    while index < args.count {
      let arg = args[index]
      if arg == "--" { break }
      if arg.hasPrefix("-") {
        if !arg.contains("="), takesValue(arg) { index += 2 } else { index += 1 }
        continue
      }
      if nonSessionCommands.contains(arg) { return nil }
      break
    }
    return AgyProcess(
      pid: pid, tty: tty, cwd: cwd, startTime: startTime,
      conversationID: AgySource.conversationArgument(from: arguments))
  }

  private static func takesValue(_ flag: String) -> Bool {
    [
      "--agent", "--effort", "--mode", "--project", "--log-file",
      "--conversation", "--model", "-m", "--settings", "--add-dir", "--permission-mode",
      "-i", "--prompt-interactive",
    ].contains(flag)
  }
}

public enum AgyTranscriptReader {
  public static let tailLimit = 256 * 1024

  public static func read(_ url: URL) throws -> SessionEnrichment {
    guard url.pathExtension == "jsonl" else {
      throw MonitorError.invalid("transcript must be a .jsonl file")
    }
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw MonitorError.invalid("refusing symlink transcript")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    let size = try handle.seekToEnd()
    let offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: tailLimit) else { return SessionEnrichment() }
    return try parse(data, dropFirstLine: offset > 0)
  }

  public static func parse(_ data: Data, dropFirstLine: Bool) throws -> SessionEnrichment {
    var lines = data.split(separator: 10, omittingEmptySubsequences: false)
    if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
    var result = SessionEnrichment()
    var foundModel = false
    var foundSnippet = false
    for (index, line) in lines.enumerated().reversed() where !line.isEmpty {
      let json: JSONValue
      do { json = try JSONDecoder().decode(JSONValue.self, from: Data(line)) } catch {
        guard TranscriptTailReader.isIncompleteFinalLine(
          error, index: index, last: lines.count - 1, data: data)
        else { throw error }
        result.diagnostics.append(Diagnostic(.info, "transcript 最后一行尚未写完，已跳过。"))
        continue
      }
      guard json["type"]?.string == "PLANNER_RESPONSE" else { continue }
      if !foundModel, let model = json["model"]?.string, !model.isEmpty {
        result.model = model
        foundModel = true
      }
      if !foundSnippet, let content = json["content"]?.string {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          let snippet = singleLine(plainText(trimmed), limit: 120)
          if !snippet.isEmpty {
            result.snippet = snippet
            foundSnippet = true
          }
        }
      }
    }
    return result
  }
}
