import Foundation
import Observation

@MainActor @Observable public final class SessionStore {
  public private(set) var byID: [String: Session] = [:]
  public private(set) var lastError: String?
  /// Whether ~/.claude/settings.json contains SessionMonitor's hooks (nil until first checked).
  /// File-only rows are normal right after launch even with hooks installed, so the
  /// "not connected" hint depends on this, not on the rows alone.
  public private(set) var claudeHooksInstalled: Bool?
  public func setClaudeHooksInstalled(_ installed: Bool) {
    if claudeHooksInstalled != installed { claudeHooksInstalled = installed }
  }
  public private(set) var failedJump: String?
  public private(set) var jumpFailureToken = UUID()
  @ObservationIgnored private var pendingDiagnostics: [Diagnostic] = []
  public var sessions: [Session] { byID.values.sorted(by: Session.ordered) }
  public init() {}

  public func resolveIdentity(_ original: AgentEvent) throws -> AgentEvent {
    var event = original
    if event.agentPid == nil {
      let matches = byID.values.filter {
        $0.kind == event.kind && $0.currentSessionId == event.sessionId && $0.pid != nil
      }
      guard matches.count <= 1 else {
        throw MonitorError.invalid("ambiguous session_id for missing agentPid")
      }
      if let known = matches.first {
        event.agentPid = known.pid
        // The hook ran outside that session's process (daemon, browser host…): its terminal facts
        // describe some other process and must not overwrite the row's (it broke jumps before).
        event.terminal = TerminalInfo()
        recordDiagnostic("hook 缺少 PID，已通过唯一 sessionId 关联到既有会话 \(known.id)。")
      }
    } else if byID[event.key] == nil {
      let sidKey = Session.key(kind: event.kind, pid: nil, sessionId: event.sessionId)
      if var known = byID.removeValue(forKey: sidKey) {
        guard event.at >= known.lastEventAt.addingTimeInterval(-2) else {
          byID[sidKey] = known
          throw MonitorError.staleEvent(known.id)
        }
        known.id = event.key
        known.pid = event.agentPid
        byID[event.key] = known
        recordDiagnostic("sessionId 会话已获得真实 PID，合并为 \(event.key)。")
      }
    }
    return event
  }

  @discardableResult public func apply(_ original: AgentEvent) throws -> Session {
    let event = try resolveIdentity(original)
    let previous = byID[event.key]
    let session = try SessionReducer.reduce(previous, event)
    if case .notification(kind: "permission_prompt", message: _) = event.type,
      event.agentId == nil, previous?.state != .needsPermission, previous?.state != .needsInput
    {
      recordDiagnostic("忽略迟到的 permission_prompt：会话当前不在等待授权或输入。")
    }
    byID[event.key] = session
    return session
  }

  public func report(_ error: any Error, context: String) {
    record(Diagnostic(.error, singleLine("\(context): \(error.localizedDescription)", limit: 240)))
  }
  private func recordDiagnostic(_ text: String) {
    record(Diagnostic(.info, text))
  }
  public func record(_ diagnostic: Diagnostic) {
    if diagnostic.level == .error { lastError = diagnostic.message }
    pendingDiagnostics.append(diagnostic)
  }
  public func drainDiagnostics() -> [Diagnostic] {
    let result = pendingDiagnostics
    pendingDiagnostics.removeAll(keepingCapacity: true)
    return result
  }
  public func clearError() { lastError = nil }
  public func markRead(_ id: String) { byID[id]?.unread = false }
  public func markAllRead() { for id in byID.keys { byID[id]?.unread = false } }
  public func remove(_ id: String) { byID.removeValue(forKey: id) }
  public func jumpFailed(_ id: String) {
    failedJump = id
    jumpFailureToken = UUID()
  }

  public func applyEnrichment(_ enrichment: SessionEnrichment, id: String, sessionID: String) {
    guard var s = byID[id], s.currentSessionId == sessionID else { return }  // A superseded async read is not current data.
    for diagnostic in enrichment.diagnostics { record(diagnostic) }
    guard enrichment.hasTranscript else { return }
    // Missing fields keep what events already provided (e.g. Stop.last_assistant_message).
    s.title = enrichment.title ?? s.title
    s.lastAssistantSnippet = enrichment.snippet ?? s.lastAssistantSnippet
    s.model = enrichment.model ?? s.model
    s.gitBranch = enrichment.gitBranch ?? s.gitBranch
    byID[id] = s
  }

  /// Folds rows keyed by session id into the pid row of the same session. They arise when events
  /// without a usable pid arrive before the process row knows its session id (e.g. a Codex TUI
  /// whose hooks run in the shared app-server daemon). The newer state wins; terminal facts and
  /// identity always come from the pid row; a stale ended row (quit, then resume) is dropped.
  public func mergeSessionIDDuplicates() {
    for pidRow in byID.values where pidRow.pid != nil {
      let sidKey = Session.key(kind: pidRow.kind, pid: nil, sessionId: pidRow.currentSessionId)
      guard let sidRow = byID[sidKey], var merged = byID[pidRow.id] else { continue }
      byID.removeValue(forKey: sidKey)
      if sidRow.state != .ended, sidRow.lastEventAt > merged.lastEventAt {
        merged.state = sidRow.state
        merged.stateSince = sidRow.stateSince
        merged.unread = sidRow.unread
        merged.currentTool = sidRow.currentTool
        merged.attentionMessage = sidRow.attentionMessage
        merged.lastAssistantSnippet = sidRow.lastAssistantSnippet ?? merged.lastAssistantSnippet
        merged.runningSubagents = sidRow.runningSubagents
        merged.lastEventAt = sidRow.lastEventAt
        merged.transcriptPath = sidRow.transcriptPath ?? merged.transcriptPath
        merged.source = .hooks
      }
      byID[pidRow.id] = merged
      recordDiagnostic("合并重复会话：\(sidKey) 并入 \(pidRow.id)。")
    }
  }

  /// A running Codex TUI found by process scan. Hook-driven rows are authoritative: only missing
  /// terminal facts are filled in. Scan-only rows take their busy/idle state from the rollout.
  public func upsertScannedCodex(
    _ process: CodexProcess, sessionID: String?, rolloutPath: String?, tmuxPane: String?,
    running: Bool?, now: Date
  ) {
    let id = Session.key(kind: .codex, pid: process.pid, sessionId: "")
    guard var s = byID[id] else {
      var created = Session(
        event: AgentEvent(
          kind: .codex, sessionId: sessionID ?? "pending-\(process.pid)", agentPid: process.pid,
          cwd: process.cwd, transcriptPath: rolloutPath, at: now, type: .sessionStart(reason: nil),
          terminal: TerminalInfo(tmuxPane: tmuxPane, tty: process.tty)))
      created.source = .processScan
      created.state = running == true ? .working : .idle
      byID[id] = created
      recordDiagnostic("发现运行中的 Codex 会话 \(process.pid)（\(created.projectName)），等待其 hook 事件。")
      return
    }
    if s.terminal.tty == nil { s.terminal.tty = process.tty }
    if s.terminal.tmuxPane == nil, let tmuxPane { s.terminal.tmuxPane = tmuxPane }
    if s.source == .processScan, let running {
      if running, s.state != .working {
        s.state = .working
        s.stateSince = now
      } else if !running, s.state == .working {
        s.state = .done
        s.unread = true
        s.stateSince = now
      }
    }
    byID[id] = s
  }

  /// A turn ended without a hook (Codex Esc interrupt) or its Stop was missed; the rollout says so.
  public func applyExternalTurnEnd(id: String, aborted: Bool, at: Date) {
    guard let s = byID[id] else { return }
    let event = AgentEvent(
      kind: s.kind, sessionId: s.currentSessionId, agentPid: s.pid, at: at,
      type: aborted ? .interrupted : .stop)
    do {
      byID[id] = try SessionReducer.reduce(s, event)
      recordDiagnostic("会话 \(id) 的回合已\(aborted ? "被中断" : "结束")但没有 hook 事件，已按 rollout 修正。")
    } catch { report(error, context: "按 rollout 修正会话状态失败") }
  }

  public func reconcile(files: [ClaudeSessionFile], liveness: [Int32: Bool], now: Date) {
    for file in files {
      guard liveness[file.pid] == true else { continue }
      let id = Session.key(kind: .claude, pid: file.pid, sessionId: file.sessionID)
      if byID[id] == nil {
        let event = AgentEvent(
          sessionId: file.sessionID, agentPid: file.pid, cwd: file.cwd, at: now,
          type: .sessionStart(reason: nil))
        var created = Session(event: event)
        created.source = .sessionFileOnly
        created.state =
          file.status == "busy" ? .working : (file.status == "idle" ? .idle : .unknown)
        byID[id] = created
        recordDiagnostic("会话 \(file.pid) 尚无 hook 事件，已使用会话文件补建；权限等待状态无法由文件判断。")
      }
      guard var s = byID[id] else { preconditionFailure("session must exist after creation") }
      if s.source == .sessionFileOnly, s.currentSessionId != file.sessionID {
        s.currentSessionId = file.sessionID
        s.title = nil
        s.lastAssistantSnippet = nil
        s.currentTool = nil
        s.runningSubagents = 0
        s.transcriptPath = nil
        recordDiagnostic("文件补建会话 \(file.pid) 的 sessionId 已变化，已清除旧摘要。")
      }
      s.explicitName = file.name
      if let cwd = file.cwd {
        s.cwd = cwd
        s.projectName = Session.projectName(cwd: cwd)
      }
      if let tmux = file.tmux { s.terminal.tmuxPane = tmux }
      s.terminal.entrypoint = file.entrypoint
      s.rawStatus = file.status
      if let updatedAt = file.statusUpdatedAt, updatedAt > s.lastEventAt.addingTimeInterval(3) {
        if file.status == "idle", s.state == .working {
          s.state = .done
          s.unread = true
          s.stateSince = now
          s.currentTool = nil
          recordDiagnostic("会话 \(file.pid) 的 hook 状态已过期；根据较新的会话文件修正为完成。")
        } else if file.status == "busy", s.state == .idle || s.state == .done {
          s.state = .working
          s.stateSince = now
          s.attentionMessage = nil
          recordDiagnostic("会话 \(file.pid) 的 hook 状态已过期；根据较新的会话文件修正为工作中。")
        }
      }
      byID[id] = s
    }
    for (id, var s) in byID {
      if let pid = s.pid, liveness[pid] == false, s.state != .ended {
        s.state = .ended
        s.stateSince = now
        s.endedAt = now
        s.currentTool = nil
        s.attentionMessage = nil
        byID[id] = s
      }
      if let ended = s.endedAt, now.timeIntervalSince(ended) >= 30 {
        byID.removeValue(forKey: id)
      } else if s.pid == nil, s.state != .working, now.timeIntervalSince(s.lastEventAt) > 1800 {
        byID.removeValue(forKey: id)
      }
    }
  }
}
