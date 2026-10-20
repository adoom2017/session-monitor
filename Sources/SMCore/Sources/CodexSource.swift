import Foundation

/// Codex CLI (0.163) hooks, verified against real captures (docs/payload-samples/codex-*):
/// the payload shape matches Claude's; hooks run inside the terminal's own `codex` process.
public struct CodexSource: AgentSource {
  public let kind = AgentKind.codex
  /// Bundle id of the Codex desktop app (ChatGPT.app), used to jump to app-hosted threads.
  public static let desktopBundleID = "com.openai.codex"
  /// A turn with no hook activity for this long may have ended without a hook (Esc interrupts
  /// fire none); the rollout file is then checked.
  public static let quietTurnSeconds: TimeInterval = 8

  /// Running TUIs; injectable so tests do not depend on what runs on the machine.
  let discover: @Sendable () throws -> [CodexProcess]
  public init(discover: @escaping @Sendable () throws -> [CodexProcess] = CodexDiscovery.runningTUIs) {
    self.discover = discover
  }

  public func normalize(_ e: HookEnvelope) throws -> AgentEvent {
    var event = try normalizeHook(e)
    // Sub-agent threads (e.g. the "guardian" auto-reviewer behind approvals_reviewer =
    // "auto_review") have their own session id; only their rollout's session_meta names the
    // parent. Their events become sub-agent context of the parent session, like Claude's agent_id.
    if let path = event.transcriptPath,
      let parent = CodexThreadParents.shared.parent(of: event.sessionId, rollout: path)
    {
      event.agentId = event.sessionId
      event.sessionId = parent
      event.terminal = TerminalInfo()
    }
    return event
  }

  private func normalizeHook(_ e: HookEnvelope) throws -> AgentEvent {
    try HookNormalizer.normalize(
      e, kind: kind,
      override: { name, payload in
        switch name {
        case "PermissionRequest":
          // Codex puts the model's request text in tool_input.description.
          return .permissionRequested(
            tool: try payload.requiredString("tool_name"),
            message: try payload["tool_input"]?.optionalString("description"))
        case "PostCompact": return .notification(kind: "post_compact", message: nil)
        case "Interrupt": return .interrupted
        default: return nil
        }
      },
      // The desktop app runs every thread in one shared app-server without a tty: its pid would
      // merge threads into one row, so such threads are keyed by session id instead.
      agentPid: { Self.isDesktopHosted($0) ? nil : $0.agentPid },
      terminalProgram: {
        Self.isDesktopHosted($0) ? Self.desktopProgram : $0.env["TERM_PROGRAM"].flatMap { $0 }
      })
  }

  /// A codex process was found but has no tty: the desktop app's shared app-server. When no codex
  /// ancestor was found at all (e.g. `webrun` tool hooks run from the browser extension host), the
  /// origin is unknown: such events carry no terminal facts and attach to their row by session id.
  static func isDesktopHosted(_ e: HookEnvelope) -> Bool {
    e.agentPid != nil && e.env["TTY"].flatMap({ $0 }) == nil
  }

  /// TERM_PROGRAM-like marker for app-hosted threads; TerminalPolicy maps it to the desktop app.
  public static let desktopProgram = "codex-desktop"

  public func reconcile(store: SessionStore) async throws {
    // Like Claude's session files: every running Codex TUI gets a row, keyed by pid, so it stays
    // visible while the process lives even before (or without) any hook event.
    let known = Set(await store.sessions.filter { $0.kind == .codex }.compactMap(\.pid))
    for process in try discover() {
      let isNew = !known.contains(process.pid)
      let rollout = isNew ? CodexRolloutIndex.find(for: process) : nil
      let pane = isNew ? try await Jumper.tmuxPane(forTTY: process.tty) : nil
      await store.upsertScannedCodex(
        process, sessionID: rollout?.sessionID, rolloutPath: rollout?.path, tmuxPane: pane,
        running: try await scannedTurnRunning(store: store, pid: process.pid, rollout: rollout?.path),
        now: Date())
    }
    await store.mergeSessionIDDuplicates()
    let sessions = await store.sessions.filter { $0.kind == .codex }
    var liveness: [Int32: Bool] = [:]
    for pid in Set(sessions.compactMap(\.pid)) { liveness[pid] = try ProcessLiveness.isAlive(pid) }
    let now = Date()
    await store.reconcile(files: [], liveness: liveness, now: now)
    // Re-read: the liveness pass may have ended sessions, which must not be revived below.
    for session in await store.sessions
    where session.kind == .codex && [.working, .needsPermission].contains(session.state)
      && now.timeIntervalSince(session.lastEventAt) >= Self.quietTurnSeconds
    {
      guard let path = session.transcriptPath else { continue }
      guard let end = try CodexRolloutReader.lastTurnEnd(URL(fileURLWithPath: path)),
        end.at >= session.lastEventAt.addingTimeInterval(-1)
      else { continue }
      await store.applyExternalTurnEnd(id: session.id, aborted: end.aborted, at: now)
    }
  }

  /// For rows without hooks, the rollout tells whether a turn is running (nil: unknown).
  private func scannedTurnRunning(store: SessionStore, pid: Int32, rollout: String?) async throws
    -> Bool?
  {
    let row = await store.byID[Session.key(kind: .codex, pid: pid, sessionId: "")]
    guard row == nil || row?.source == .processScan,
      let path = rollout ?? row?.transcriptPath
    else { return nil }
    return try CodexRolloutReader.turnRunning(URL(fileURLWithPath: path))
  }

  /// Snippets come from Stop.last_assistant_message; there is no title to read.
  public func enrich(_ session: Session) async throws -> SessionEnrichment? { nil }
}

/// A running interactive Codex TUI (not the app-server daemon, sandbox helpers or subcommands).
public struct CodexProcess: Sendable, Equatable {
  public var pid: Int32
  public var tty: String
  public var cwd: String?
  public var startTime: Date?
  /// `codex resume <id>`: the thread id is known before any hook fires.
  public var resumeID: String?
}

public enum CodexDiscovery {
  static let nonSessionCommands: Set<String> = [
    "app-server", "exec-server", "sandbox", "mcp", "mcp-server", "agents", "login", "logout",
    "doctor", "update", "completion", "features", "debug", "apply", "cloud", "plugin", "archive",
    "unarchive", "delete", "migrate-rollouts", "help", "queue", "app", "remote-control",
  ]

  public static func runningTUIs() throws -> [CodexProcess] {
    try ProcessIdentity.listAll().compactMap { process in
      guard process.executable == "codex", let tty = process.tty else { return nil }
      return classify(
        pid: process.pid, tty: tty, arguments: ProcessIdentity.arguments(pid: process.pid) ?? [],
        cwd: ProcessIdentity.cwd(pid: process.pid), startTime: process.startTime)
    }
  }

  /// Pure part of discovery, unit-tested with real argv shapes.
  public static func classify(
    pid: Int32, tty: String, arguments: [String], cwd: String?, startTime: Date?
  ) -> CodexProcess? {
    let positional = arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if let command = positional.first, nonSessionCommands.contains(command) { return nil }
    var resumeID: String?
    if positional.first == "resume" || positional.first == "fork",
      let id = positional.dropFirst().first
    {
      resumeID = id
    }
    return CodexProcess(pid: pid, tty: tty, cwd: cwd, startTime: startTime, resumeID: resumeID)
  }
}

public enum CodexRolloutIndex {
  public struct Match: Sendable, Equatable {
    public var sessionID: String
    public var path: String
  }

  /// The rollout of a TUI: by `resume <id>`, else the newest rollout in the same directory that
  /// was written after the process started. Nil for a fresh TUI before its first prompt.
  public static func find(
    for process: CodexProcess,
    root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".codex/sessions")
  ) -> Match? {
    let files = recentRollouts(root: root, since: process.startTime)
    if let id = process.resumeID {
      return files.first { $0.lastPathComponent.contains(id) }.map {
        Match(sessionID: id, path: $0.path)
      }
    }
    guard let cwd = process.cwd else { return nil }
    for file in files {
      guard let meta = sessionMeta(file), meta.cwd == cwd else { continue }
      return Match(sessionID: meta.id, path: file.path)
    }
    return nil
  }

  /// Rollouts under YYYY/MM/DD folders modified since `since`, newest first.
  static func recentRollouts(root: URL, since: Date?) -> [URL] {
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    var found: [(URL, Date)] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" {
      guard url.lastPathComponent.hasPrefix("rollout-"),
        let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
        since.map({ modified >= $0 }) ?? true
      else { continue }
      found.append((url, modified))
    }
    return found.sorted { $0.1 > $1.1 }.map(\.0)
  }

  /// First line of a rollout: `session_meta` with the thread id and working directory.
  static func sessionMeta(_ url: URL) -> (id: String, cwd: String)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { handle.closeFile() }
    guard let head = try? handle.read(upToCount: 64 * 1024),
      let line = head.split(separator: 10).first,
      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
      json["type"]?.string == "session_meta",
      let id = json["payload"]?["id"]?.string ?? json["payload"]?["session_id"]?.string,
      let cwd = json["payload"]?["cwd"]?.string
    else { return nil }
    return (id, cwd)
  }
}

public enum CodexRolloutReader {
  /// Whether the latest turn in the rollout is still running (task_started without an end).
  public static func turnRunning(_ url: URL) throws -> Bool {
    try lastLifecycle(url) == "task_started"
  }

  static func lastLifecycle(_ url: URL) throws -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { handle.closeFile() }
    let size = try handle.seekToEnd()
    let limit: UInt64 = 256 * 1024
    try handle.seek(toOffset: size > limit ? size - limit : 0)
    guard let data = try handle.read(upToCount: Int(limit)) else { return nil }
    for line in data.split(separator: 10).reversed() {
      guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
        json["type"]?.string == "event_msg", let type = json["payload"]?["type"]?.string,
        ["task_started", "task_complete", "turn_aborted"].contains(type)
      else { continue }
      return type
    }
    return nil
  }

  public struct TurnEnd: Sendable, Equatable {
    public var aborted: Bool
    public var at: Date
  }

  /// The last turn lifecycle event in the rollout tail, if that event ended the turn.
  /// Reads at most the final 256KB; returns nil when the latest turn is still running.
  public static func lastTurnEnd(_ url: URL) throws -> TurnEnd? {
    guard url.pathExtension == "jsonl" else { throw MonitorError.invalid("rollout must be .jsonl") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    let size = try handle.seekToEnd()
    let limit: UInt64 = 256 * 1024
    let offset = size > limit ? size - limit : 0
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: Int(limit)) else { return nil }
    var lines = data.split(separator: 10)
    if offset > 0, !lines.isEmpty { lines.removeFirst() }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for (index, line) in lines.reversed().enumerated() {
      let json: JSONValue
      do { json = try JSONDecoder().decode(JSONValue.self, from: Data(line)) } catch {
        // Only the final line may be partially written while Codex appends; others must parse.
        if index == 0 && data.last != 10 { continue }
        throw error
      }
      guard json["type"]?.string == "event_msg", let type = json["payload"]?["type"]?.string
      else { continue }
      switch type {
      case "task_started": return nil
      case "task_complete", "turn_aborted":
        let at = json["timestamp"]?.string.flatMap(iso.date(from:)) ?? Date.distantPast
        return TurnEnd(aborted: type == "turn_aborted", at: at)
      default: continue
      }
    }
    return nil
  }
}

/// session id → parent thread id (nil for top-level threads), read once from the rollout's first
/// line (`session_meta.parent_thread_id`) and cached.
public final class CodexThreadParents: @unchecked Sendable {
  public static let shared = CodexThreadParents()
  private let lock = NSLock()
  private var cache: [String: String?] = [:]

  public func parent(of sessionID: String, rollout: String) -> String? {
    lock.lock()
    if let known = cache[sessionID] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let parent = Self.readParent(URL(fileURLWithPath: rollout))
    lock.lock()
    cache[sessionID] = parent
    lock.unlock()
    return parent
  }

  static func readParent(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { handle.closeFile() }
    guard let head = try? handle.read(upToCount: 256 * 1024),
      let line = head.split(separator: 10).first,
      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
      json["type"]?.string == "session_meta"
    else { return nil }
    return json["payload"]?["parent_thread_id"]?.string
  }
}
