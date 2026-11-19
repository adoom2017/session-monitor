import Foundation

public struct AgySource: AgentSource {
  public let kind = AgentKind.agy
  let discover: @Sendable () throws -> [ProcessIdentity]

  public init(discover: @escaping @Sendable () throws -> [ProcessIdentity] = ProcessIdentity.listAll) {
    self.discover = discover
  }

  public func normalize(_ envelope: HookEnvelope) throws -> AgentEvent {
    let payload = envelope.payload
    let name = try payload.requiredString("hookEventName")
    var mapped = envelope
    mapped.payload = .object([
      "session_id": .string(try payload.requiredString("conversationId")),
      "hook_event_name": .string(name),
      "cwd": payload["cwd"] ?? .null,
    ])
    return try HookNormalizer.normalize(mapped, kind: kind, override: { name, _ in
      switch name {
      case "SessionStart": return .sessionStart(reason: nil)
      case "PreInvocation": return .promptSubmitted
      case "Stop":
        let reason = try payload.requiredString("terminationReason")
        if reason == "USER_CANCELED" || reason == "ERROR" { return .interrupted }
        if payload["fullyIdle"]?.bool == false { return .notification(kind: nil, message: nil) }
        return .stop
      default: throw MonitorError.unsupported("agy hook \(singleLine(name, limit: 80))")
      }
    })
  }

  public func reconcile(store: SessionStore) async throws {
    let rows = await store.sessions.filter { $0.kind == .agy }
    let known = Set(rows.compactMap(\.pid))
    for process in try discover() where process.executable == "agy" && !known.contains(process.pid) {
      guard let tty = process.tty else { continue }
      let pane = try await Jumper.tmuxPane(forTTY: tty)
      await store.upsertScannedAgy(
        pid: process.pid, cwd: ProcessIdentity.cwd(pid: process.pid),
        terminal: TerminalInfo(tmuxPane: pane, tty: tty), now: Date())
    }
    var liveness: [Int32: Bool] = [:]
    for pid in known { liveness[pid] = try ProcessLiveness.isAlive(pid) }
    await store.reconcile(files: [], liveness: liveness, now: Date())
  }

  public func enrich(_ session: Session) async throws -> SessionEnrichment? { nil }
}
