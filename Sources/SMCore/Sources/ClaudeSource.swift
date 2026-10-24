import Foundation

public protocol AgentSource: Sendable {
  var kind: AgentKind { get }
  func normalize(_ envelope: HookEnvelope) throws -> AgentEvent
  func reconcile(store: SessionStore) async throws
  func enrich(_ session: Session) async throws -> SessionEnrichment?
}

public struct ClaudeSource: AgentSource {
  public let kind = AgentKind.claude
  public let home: URL
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

  public func normalize(_ e: HookEnvelope) throws -> AgentEvent {
    try HookNormalizer.normalize(e, kind: kind)
  }

  public func reconcile(store: SessionStore) async throws {
    await store.setClaudeHooksInstalled(
      HookInstaller(agent: .claude, home: home).status() == .installed)
    let report = try ClaudeSessionFileScanner.scanReport(
      directory: home.appendingPathComponent(".claude/sessions"))
    let files = report.files
    for issue in report.issues {
      await store.report(MonitorError.invalid(issue), context: "session file skipped")
    }
    for file in files where !file.diagnostics.isEmpty {
      await store.report(
        MonitorError.invalid(file.diagnostics.joined(separator: "; ")),
        context: "session \(file.pid)")
    }
    var liveness: [Int32: Bool] = [:]
    let existing = await store.sessions
    for pid in Set(files.map(\.pid) + existing.filter { $0.kind == .claude }.compactMap(\.pid)) {
      liveness[pid] = try ProcessLiveness.isAlive(pid)
    }
    await store.reconcile(files: files, liveness: liveness, now: Date())
  }

  public func enrich(_ session: Session) async throws -> SessionEnrichment? {
    guard let path = try Self.transcript(of: session, home: home) else {
      return SessionEnrichment.pendingTranscript(session.id)
    }
    do { return try TranscriptTailReader.read(path) } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
    {
      return SessionEnrichment.pendingTranscript(session.id)
    }
  }

  /// The session's transcript: from its hooks, else `~/.claude/projects/*/<session id>.jsonl`
  /// (rows rebuilt from session files after a restart have no path yet). Nil if not written yet.
  public static func transcript(
    of session: Session, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> URL? {
    if let transcript = session.transcriptPath { return URL(fileURLWithPath: transcript) }
    let projects = home.appendingPathComponent(".claude/projects")
    guard FileManager.default.fileExists(atPath: projects.path) else { return nil }
    let directories = try FileManager.default.contentsOfDirectory(
      at: projects, includingPropertiesForKeys: [.isDirectoryKey]
    ).sorted { $0.path < $1.path }
    return directories.map { $0.appendingPathComponent(session.currentSessionId + ".jsonl") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }
}

public enum HookNormalizer {
  /// Claude and Codex share the hook payload shape. `override` maps agent-specific events first;
  /// returning nil falls through to the common mapping.
  static func normalize(
    _ e: HookEnvelope, kind: AgentKind,
    override: (_ name: String, _ payload: JSONValue) throws -> EventType? = { _, _ in nil },
    agentPid: (HookEnvelope) -> Int32? = { $0.agentPid },
    terminalProgram: (HookEnvelope) -> String? = { $0.env["TERM_PROGRAM"].flatMap { $0 } }
  ) throws -> AgentEvent {
    guard e.v == 1, e.source == kind.rawValue, e.receivedAt.isFinite else {
      throw MonitorError.invalid("envelope version/source/time")
    }
    if let pid = e.agentPid, pid <= 0 { throw MonitorError.invalid("agentPid must be positive") }
    let p = e.payload
    let sid = try p.requiredString("session_id")
    let name = try p.requiredString("hook_event_name")
    let type: EventType
    if let custom = try override(name, p) {
      type = custom
    } else {
    switch name {
    case "SessionStart": type = .sessionStart(reason: try p.optionalString("source"))
    case "UserPromptSubmit": type = .promptSubmitted
    case "PreToolUse":
      let tool = try p.requiredString("tool_name")
      if let input = p["tool_input"], input.object == nil {
        throw MonitorError.invalid("tool_input must be an object")
      }
      var summary: String?
      if tool == "Bash", let input = p["tool_input"] {
        summary = singleLine(try input.requiredString("command"), limit: 80)
      }
      if ["Read", "Edit", "Write"].contains(tool), let input = p["tool_input"] {
        summary = URL(fileURLWithPath: try input.requiredString("file_path")).lastPathComponent
      }
      type = .toolStart(name: tool, summary: summary)
    case "PostToolUse": type = .toolEnd(name: try p.requiredString("tool_name"))
    case "PermissionRequest":
      type = .permissionRequested(
        tool: try p.requiredString("tool_name"), message: try p.optionalString("message"))
    case "Notification":
      type = .notification(
        kind: try p.optionalString("notification_type"),
        message: try p.optionalString("message").map { singleLine($0, limit: 80) })
    case "Stop": type = .stop
    case "SubagentStart": type = .subagentStart
    case "SubagentStop": type = .subagentStop
    case "PreCompact": type = .compacting
    case "SessionEnd": type = .sessionEnd(reason: try p.optionalString("reason"))
    default: throw MonitorError.unsupported("\(kind.rawValue) hook \(singleLine(name, limit: 80))")
    }
    }
    let tmux = e.env["TMUX"].flatMap { $0 }
    let socket: String?
    if let tmux {
      guard let first = tmux.split(separator: ",", maxSplits: 1).first, first.hasPrefix("/") else {
        throw MonitorError.invalid("TMUX environment socket path")
      }
      socket = String(first)
    } else {
      socket = nil
    }
    let terminal = TerminalInfo(
      tmuxPane: e.env["TMUX_PANE"].flatMap { $0 }, tmuxSocket: socket,
      termProgram: terminalProgram(e),
      itermSessionId: e.env["ITERM_SESSION_ID"].flatMap { $0 }, tty: e.env["TTY"].flatMap { $0 }
    )
    return AgentEvent(
      kind: kind, sessionId: sid, agentPid: agentPid(e), cwd: try p.optionalString("cwd"),
      transcriptPath: try p.optionalString("transcript_path"),
      agentId: try p.optionalString("agent_id"),
      assistantMessage: name == "Stop" ? try p.optionalString("last_assistant_message") : nil,
      at: Date(timeIntervalSince1970: e.receivedAt / 1000), type: type, terminal: terminal)
  }
}
