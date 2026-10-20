import Foundation
import SMCore

@MainActor final class AppRuntime {
  let store: SessionStore
  let directory: URL
  let sources: [String: any AgentSource]
  private var server: SocketServer?
  private var log: AppLog?
  private var intake: Task<Void, Never>?
  private var reconciler: Task<Void, Never>?
  private var enrichment: [String: Task<Void, Never>] = [:]
  private var enrichmentGeneration: [String: UUID] = [:]
  private var completionDeadline: [String: Task<Void, Never>] = [:]
  var stateChanged: ((Session?, Session) -> Void)?
  var notifyDone: ((Session) -> Void)?

  init(store: SessionStore, directory: URL) {
    self.store = store
    self.directory = directory
    sources = ["claude": ClaudeSource(), "codex": CodexSource()]
  }

  func start() async {
    do {
      let directory = directory
      log = try await Task.detached { try AppLog(directory: directory) }.value
      let pair = AsyncStream<Result<Data, MonitorError>>.makeStream()
      let socket = SocketServer(directory: directory)
      try await Task.detached { try socket.start { pair.continuation.yield($0) } }.value
      server = socket
      intake = Task { [weak self] in
        for await result in pair.stream {
          guard let self, !Task.isCancelled else { break }
          do { try await ingest(JSONDecoder().decode(HookEnvelope.self, from: result.get())) } catch
          { await report(error, context: "事件接收失败") }
        }
      }
      let replayer = SpoolReplayer(directory: directory)
      do {
        try await replayer.replay { [weak self] envelope in
          guard let self else { throw CancellationError() }
          try await self.ingest(envelope)
        }
      } catch { await report(error, context: "spool 回放失败，未处理记录已保留") }
      reconciler = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { break }
          for source in sources.values {
            let before = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
            do {
              let store = self.store
              try await Task.detached(priority: .utility) {
                try await source.reconcile(store: store)
              }.value
              for current in store.sessions {
                if before[current.id] == nil { enrich(current, delay: .zero, notify: false) }
                if let previous = before[current.id], previous.state != current.state {
                  stateChanged?(previous, current)
                  if current.state == .done {
                    enrich(current, delay: .milliseconds(300), notify: true)
                  }
                }
              }
              await flushDiagnostics()
            } catch { await report(error, context: "会话对账失败") }
          }
          do { try await Task.sleep(for: .seconds(2)) } catch is CancellationError { break } catch {
            await report(error, context: "对账定时器失败")
            break
          }
        }
      }
      await writeLog("SessionMonitor started")
    } catch { await report(error, context: "启动失败") }
  }

  func ingest(_ envelope: HookEnvelope) async throws {
    guard let source = sources[envelope.source] else {
      if envelope.source == AgentKind.codex.rawValue {
        // Hooks may be installed before CodexSource lands; receiving them is expected, not an error.
        await diagnose(
          .info, "Codex 事件已接收（\(envelope.payload["hook_event_name"]?.string ?? "?")），CodexSource 尚未启用")
        return
      }
      throw MonitorError.unsupported(
        "source \(singleLine(envelope.source, limit: 80)); Codex requires phase-two payload validation"
      )
    }
    let event = try store.resolveIdentity(source.normalize(envelope))
    await flushDiagnostics()
    for warning in envelope.diagnostics ?? [] {
      await diagnose(envelope.diagnosticLevel ?? .error, "hook 诊断：" + warning)
    }
    let previous = store.byID[event.key]
    let current: Session
    do { current = try store.apply(event) } catch let error as MonitorError {
      if case .staleEvent = error {
        await report(error, context: "旧事件已明确拒绝")
        return
      }
      throw error
    }
    await writeLog(
      "EVENT \(event.kind.rawValue) \(current.id) \(previous?.state.rawValue ?? "new") -> \(current.state.rawValue) [\(event.type.logLabel)]"
    )
    if previous?.state != current.state { stateChanged?(previous, current) }
    await flushDiagnostics()
    let stopped = event.type == .stop && event.agentId == nil
    if stopped || previous == nil || previous?.currentSessionId != current.currentSessionId {
      enrich(current, delay: stopped ? .milliseconds(300) : .zero, notify: stopped)
    }
    if stopped {
      completionDeadline[current.id]?.cancel()
      completionDeadline[current.id] = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(1)) } catch is CancellationError { return } catch {
          await self?.report(error, context: "完成通知定时器失败")
          return
        }
        guard let self else { return }
        if let latest = store.byID[current.id], latest.currentSessionId == current.currentSessionId,
          latest.state == .done
        {
          notifyDone?(latest)
        }
        completionDeadline.removeValue(forKey: current.id)
      }
    }
  }

  private func enrich(_ session: Session, delay: Duration, notify: Bool) {
    guard let source = sources[session.kind.rawValue] else { return }
    // Coalesce pending work by replacing it, so a new Stop always reads after its flush delay.
    enrichment[session.id]?.cancel()
    let token = UUID()
    enrichmentGeneration[session.id] = token
    enrichment[session.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        if enrichmentGeneration[session.id] == token {
          enrichment.removeValue(forKey: session.id)
          enrichmentGeneration.removeValue(forKey: session.id)
        }
      }
      do {
        try await Task.sleep(for: delay)
        let info = try await Task.detached(priority: .utility) {
          try await source.enrich(session)
        }.value
        try Task.checkCancellation()
        if let info {
          store.applyEnrichment(info, id: session.id, sessionID: session.currentSessionId)
          await flushDiagnostics()
        }
      } catch is CancellationError { return } catch { await report(error, context: "会话摘要读取失败") }
      if notify, let latest = store.byID[session.id],
        latest.currentSessionId == session.currentSessionId, latest.state == .done
      {
        notifyDone?(latest)
      }
    }
  }

  func report(_ error: any Error, context: String) async {
    store.report(error, context: context)
    await flushDiagnostics()
  }

  func diagnose(_ level: DiagnosticLevel, _ message: String) async {
    store.record(Diagnostic(level, message))
    await flushDiagnostics()
  }

  private func flushDiagnostics() async {
    for diagnostic in store.drainDiagnostics() {
      await writeLog("DIAGNOSTIC " + diagnostic.logLine)
    }
  }

  private func writeLog(_ text: String) async {
    guard let log else {
      FileHandle.standardError.write(Data((text + "\n").utf8))
      return
    }
    do { try await Task.detached { try log.write(text) }.value } catch {
      let text = "日志写入失败：\(error.localizedDescription)"
      store.report(error, context: "日志写入失败")
      FileHandle.standardError.write(Data((text + "\n").utf8))
    }
  }

  func stop() {
    intake?.cancel()
    reconciler?.cancel()
    for task in enrichment.values { task.cancel() }
    server?.stop()
    for task in completionDeadline.values { task.cancel() }
  }
}
