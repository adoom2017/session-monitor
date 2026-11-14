import Foundation

/// Pi (pi-coding-agent) has no hooks configuration: `PiExtension` (installed under
/// ~/.pi/agent/extensions) forwards its lifecycle events through sm-hook in the same payload
/// shape Claude and Codex use. Running Pi TUIs are discovered by process scan so rows survive
/// an app restart before the next event, and session files feed titles, transcripts and usage.
public struct PiSource: AgentSource {
  public let kind = AgentKind.pi
  let home: URL
  /// Running TUIs; injectable so tests do not depend on what runs on the machine.
  let discover: @Sendable () throws -> [PiProcess]

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    discover: @escaping @Sendable () throws -> [PiProcess] = PiDiscovery.runningTUIs
  ) {
    self.home = home
    self.discover = discover
  }

  public func normalize(_ e: HookEnvelope) throws -> AgentEvent {
    try HookNormalizer.normalize(e, kind: kind, override: Self.override)
  }

  /// The extension sends Claude's event names with Pi's lowercase tool names.
  static func override(_ name: String, _ payload: JSONValue) throws -> EventType? {
    switch name {
    case "PreToolUse":
      let tool = try payload.requiredString("tool_name")
      return .toolStart(name: tool, summary: summary(tool: tool, input: payload["tool_input"]))
    case "PermissionRequest":
      return .permissionRequested(
        tool: try payload.requiredString("tool_name"),
        message: try payload.optionalString("message"))
    case "PreCompact": return .toolStart(name: "压缩上下文", summary: nil)
    case "Interrupt": return .interrupted
    case "PromptEnded", "PostCompact":
      switch try payload.requiredString("state") {
      case "idle": return .interrupted
      case "working": return .toolEnd(name: "prompt")
      default: throw MonitorError.invalid("Pi state must be idle or working")
      }
    default: return nil
    }
  }

  static func summary(tool: String, input: JSONValue?) -> String? {
    guard let input else { return nil }
    for key in ["command", "path", "file_path", "pattern", "query", "url", "description", "prompt"] {
      if let value = input[key]?.string, !value.isEmpty { return singleLine(value, limit: 80) }
    }
    return nil
  }

  public func reconcile(store: SessionStore) async throws {
    let rows = await store.sessions.filter { $0.kind == .pi }
    let known = Set(rows.compactMap(\.pid))
    // pid → since when the row waits for its first session file.
    let pending = Dictionary(
      rows.filter { $0.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) }
        .compactMap { row in row.pid.map { ($0, row.stateSince) } },
      uniquingKeysWith: max)
    let processes = try discover()
    let unresolved = processes.filter { !known.contains($0.pid) || pending[$0.pid] != nil }
    let assigned = Set(rows.filter {
      !$0.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix)
    }.map(\.currentSessionId))
    let matches = PiSessionIndex.matches(
      for: unresolved, after: pending, excluding: assigned,
      root: home.appendingPathComponent(".pi/agent/sessions"))
    for process in processes {
      let isNew = !known.contains(process.pid)
      let pane = isNew ? try await Jumper.tmuxPane(forTTY: process.tty) : nil
      await store.upsertScannedPi(process, session: matches[process.pid], tmuxPane: pane, now: Date())
    }
    await store.mergeSessionIDDuplicates()
    let sessions = await store.sessions.filter { $0.kind == .pi }
    var liveness: [Int32: Bool] = [:]
    for pid in Set(sessions.compactMap(\.pid)) { liveness[pid] = try ProcessLiveness.isAlive(pid) }
    await store.reconcile(files: [], liveness: liveness, now: Date())
  }

  public func enrich(_ session: Session) async throws -> SessionEnrichment? {
    guard !session.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) else { return nil }
    guard let path = try Self.transcript(of: session, home: home) else {
      return SessionEnrichment.pendingTranscript(session.id)
    }
    do {
      var enrichment = try PiSessionReader.read(path)
      // Hook-driven rows use this run's Stop payload; the file may still contain an older reply.
      if session.source == .hooks { enrichment.snippet = nil }
      return enrichment
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
    {
      return SessionEnrichment.pendingTranscript(session.id)
    }
  }

  /// From the hook payload, else by session id under ~/.pi/agent/sessions.
  public static func transcript(
    of session: Session, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> URL? {
    if let transcript = session.transcriptPath { return URL(fileURLWithPath: transcript) }
    guard !session.currentSessionId.hasPrefix(SessionStore.pendingSessionPrefix) else { return nil }
    guard let path = PiSessionIndex.find(
      sessionID: session.currentSessionId, root: home.appendingPathComponent(".pi/agent/sessions")
    )?.path else { return nil }
    return URL(fileURLWithPath: path)
  }
}

/// A running interactive Pi TUI.
public struct PiProcess: Sendable, Equatable {
  public var pid: Int32
  public var tty: String
  public var cwd: String?
  public var startTime: Date?
}

public enum PiDiscovery {
  public static func runningTUIs() throws -> [PiProcess] {
    try ProcessIdentity.listAll().compactMap { process in
      guard let tty = process.tty, isPi(process) else { return nil }
      return PiProcess(
        pid: process.pid, tty: tty, cwd: ProcessIdentity.cwd(pid: process.pid),
        startTime: process.startTime)
    }
  }

  /// Pi sets its process title to `pi`; a test harness may launch the Node bundle directly.
  static func isPi(_ process: ProcessIdentity) -> Bool {
    if process.executable == "pi" { return true }
    guard process.executable == "node" else { return false }
    return (ProcessIdentity.arguments(pid: process.pid) ?? []).contains {
      $0.contains("pi-coding-agent")
    }
  }
}

public enum PiSessionIndex {
  public struct Match: Sendable, Equatable {
    public var sessionID: String
    public var path: String
  }

  /// Session files have no PID: same-directory processes must wait for hooks when ambiguous.
  static func matches(
    for processes: [PiProcess], after: [Int32: Date], excluding assigned: Set<String>, root: URL
  ) -> [Int32: Match] {
    let groups = Dictionary(grouping: processes, by: \.cwd)
    var result: [Int32: Match] = [:]
    for group in groups.values where group.count == 1 {
      let process = group[0]
      result[process.pid] = find(
        for: process, after: after[process.pid], excluding: assigned, root: root)
    }
    return result
  }

  /// Only a unique, unassigned file is eligible. Modification time bounds candidates,
  /// but cannot prove which process owns the newest file.
  public static func find(
    for process: PiProcess, after: Date? = nil, excluding assigned: Set<String> = [],
    root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".pi/agent/sessions")
  ) -> Match? {
    guard let cwd = process.cwd else { return nil }
    let since = [process.startTime, after].compactMap { $0 }.max()
    var match: Match?
    for file in recentSessions(root: root, since: since) {
      guard let meta = header(file), meta.cwd == cwd, !assigned.contains(meta.id) else { continue }
      guard match == nil else { return nil }
      match = Match(sessionID: meta.id, path: file.path)
    }
    return match
  }

  public static func find(sessionID: String, root: URL) -> Match? {
    guard !sessionID.isEmpty else { return nil }
    let name = sessionID + ".jsonl"
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return nil }
    for case let url as URL in walker where url.lastPathComponent.hasSuffix("_" + name) {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        return Match(sessionID: sessionID, path: url.path)
      }
    }
    return nil
  }

  /// Session files modified since `since`, newest first.
  static func recentSessions(root: URL, since: Date?) -> [URL] {
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    var found: [(URL, Date)] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" {
      guard let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
        since.map({ modified >= $0 }) ?? true
      else { continue }
      found.append((url, modified))
    }
    return found.sorted { $0.1 > $1.1 }.map(\.0)
  }

  /// First line of a session file: `{"type":"session","id":…,"cwd":…}`.
  static func header(_ url: URL) -> (id: String, cwd: String)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { handle.closeFile() }
    guard let head = try? handle.read(upToCount: 64 * 1024),
      let line = head.split(separator: 10).first,
      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
      json["type"]?.string == "session",
      let id = json["id"]?.string, let cwd = json["cwd"]?.string
    else { return nil }
    return (id, cwd)
  }
}

/// Title, model and reply snippet from a Pi session file's tail (plus its head for a session
/// name written early). Same rules as TranscriptTailReader: bounded reads, tolerant of a final
/// line still being appended, everything else is an error.
public enum PiSessionReader {
  public static let tailLimit = 256 * 1024
  public static let headLimit = 64 * 1024

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
    var result = try parse(data, dropFirstLine: offset > 0)
    if result.title == nil, offset > 0 {
      try handle.seek(toOffset: 0)
      guard let head = try handle.read(upToCount: headLimit) else {
        throw MonitorError.invalid("unexpected EOF reading transcript header")
      }
      var lines = head.split(separator: 10, omittingEmptySubsequences: false)
      if size > UInt64(headLimit), head.last != 10 { lines.removeLast() }
      result.title = try parse(
        Data(lines.map { Data($0) }.joined(separator: Data([10]))), dropFirstLine: false
      ).title
    }
    return result
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
        guard isIncompleteFinalLine(error, index: index, last: lines.count - 1, data: data) else {
          throw error
        }
        result.diagnostics.append(Diagnostic(.info, "transcript 最后一行尚未写完，已跳过。"))
        continue
      }
      let type = json["type"]?.string
      if result.title == nil, type == "session_info",
        let name = json["name"]?.string, !name.isEmpty
      {
        result.title = singleLine(name, limit: 120)
      }
      let message = json["message"]
      if !foundModel {
        if type == "model_change", let model = json["modelId"]?.string {
          result.model = model
          foundModel = true
        } else if type == "message", message?["role"]?.string == "assistant",
          let model = message?["model"]?.string
        {
          result.model = model
          foundModel = true
        }
      }
      if !foundSnippet, type == "message", message?["role"]?.string == "assistant",
        let content = message?["content"]?.array,
        let text = content.last(where: { $0["type"]?.string == "text" })?["text"]?.string,
        !text.isEmpty
      {
        result.snippet = singleLine(plainText(text), limit: 120)
        foundSnippet = true
      }
    }
    return result
  }

  /// A writer may still be appending the final physical line at EOF.
  static func isIncompleteFinalLine(
    _ error: Error, index: Int, last: Int, data: Data
  ) -> Bool {
    guard index == last, data.last != 10,
      case DecodingError.dataCorrupted(let context) = error,
      let underlying = context.underlyingError as NSError?,
      underlying.domain == NSCocoaErrorDomain,
      underlying.code == CocoaError.propertyListReadCorrupt.rawValue,
      underlying.userInfo[NSDebugDescriptionErrorKey] as? String == "Unexpected end of file"
    else { return false }
    return true
  }
}
