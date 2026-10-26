import Foundation
import SMProtocol

/// Keeps each row's `SessionUsage` current by reading its transcript's new lines (a few seconds
/// apart; transcripts are only appended to). A new thread or transcript starts a new count.
public actor UsageTracker {
  struct Meter {
    var thread: String
    var path: String
    var reader: UsageReader
    var total = TokenUsage()
  }

  private var meters: [String: Meter] = [:]
  private let home: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

  /// Usage of each session whose transcript exists, keyed by session id.
  public func update(_ sessions: [Session]) -> [String: SessionUsage] {
    var result: [String: SessionUsage] = [:]
    meters = meters.filter { id, _ in sessions.contains { $0.id == id } }
    for session in sessions {
      let located =
        session.kind == .claude
        ? try? ClaudeSource.transcript(of: session, home: home)
        : session.transcriptPath.map { URL(fileURLWithPath: $0) }
      guard let url = located, FileManager.default.fileExists(atPath: url.path) else {
        meters.removeValue(forKey: session.id)
        continue
      }
      var meter = meters[session.id]
      if meter == nil || meter?.thread != session.currentSessionId || meter?.path != url.path {
        meter = Meter(thread: session.currentSessionId, path: url.path, reader: UsageReader(kind: session.kind))
      }
      guard var current = meter else { continue }
      var added = TokenUsage()
      do {
        if try !current.reader.read(url, { added += $0.usage }) {
          current = Meter(thread: session.currentSessionId, path: url.path, reader: UsageReader(kind: session.kind))
          _ = try current.reader.read(url) { added += $0.usage }
        }
      } catch {
        continue  // unreadable for now; keep the previous count and try again next time
      }
      current.total += added
      meters[session.id] = current
      guard !current.total.isZero || current.reader.contextTokens != nil else { continue }
      result[session.id] = SessionUsage(
        total: current.total, model: current.reader.model, contextTokens: current.reader.contextTokens,
        contextWindow: current.reader.contextWindow)
    }
    return result
  }
}
