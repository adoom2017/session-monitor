import Foundation
import SMProtocol

/// Token usage of every local Claude and Codex session, by day, agent, model and project,
/// including sessions SessionMonitor never saw running. Scans `~/.claude/projects` and
/// `~/.codex/{sessions,archived_sessions}` incrementally (only what was appended since the last
/// scan) and keeps the result in `<directory>/usage/ledger.json`, so history survives the agents
/// deleting old transcripts. Thread-safe; `refresh` blocks, call it off the main actor.
public final class UsageLedger: @unchecked Sendable {
  struct FileEntry: Codable {
    var reader: UsageReader
    /// "day|model|project" → usage counted from this file.
    var buckets: [String: TokenUsage] = [:]
  }

  struct Stored: Codable {
    var version = UsageLedger.version
    /// Keyed by agent and file name, not path: Codex moves rollouts to archived_sessions.
    var files: [String: FileEntry] = [:]
    /// Claude message id → file key that counted it (resumed sessions copy earlier messages).
    var claudeMessages: [String: String] = [:]
  }

  static let version = 1
  private let lock = NSLock()
  private let cache: URL
  private let roots: [(AgentKind, URL)]
  private var stored = Stored()

  public init(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    cache = directory.appendingPathComponent("usage/ledger.json")
    roots = [
      (.claude, home.appendingPathComponent(".claude/projects")),
      (.codex, home.appendingPathComponent(".codex/sessions")),
      (.codex, home.appendingPathComponent(".codex/archived_sessions")),
    ]
    if let data = FileManager.default.contents(atPath: cache.path),
      let decoded = try? JSONDecoder().decode(Stored.self, from: data), decoded.version == Self.version
    {
      stored = decoded
    }
  }

  /// Reads what changed since the last refresh; true when the totals changed.
  @discardableResult public func refresh() throws -> Bool {
    try lock.withLock {
      var changed = false
      for (kind, root) in roots {
        for url in Self.transcripts(under: root) {
          changed = try scan(url, kind: kind) || changed
        }
      }
      if changed { try save() }
      return changed
    }
  }

  /// All days, aggregated over files.
  public func rows() -> [UsageRow] {
    lock.withLock {
      var totals: [String: TokenUsage] = [:]
      for (key, entry) in stored.files {
        let agent = key.hasPrefix("codex/") ? "codex" : "claude"
        for (bucket, usage) in entry.buckets { totals[agent + "|" + bucket, default: TokenUsage()] += usage }
      }
      return totals.compactMap { key, usage in
        let parts = key.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !usage.isZero else { return nil }
        return UsageRow(day: parts[1], agent: parts[0], model: parts[2], project: parts[3], usage: usage)
      }.sorted { ($0.day, $0.agent, $0.model, $0.project) < ($1.day, $1.agent, $1.model, $1.project) }
    }
  }

  private func scan(_ url: URL, kind: AgentKind) throws -> Bool {
    let key = "\(kind.rawValue)/\(url.lastPathComponent)"
    let previous = stored.files[key]
    if let previous, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      UInt64(size) == previous.reader.offset
    {
      return false
    }
    let fallbackDay = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      .map { UsageReport.dayKey($0) } ?? "unknown"
    // Separate from the reader: the callback runs while `read` mutates the reader.
    var reader = previous?.reader ?? UsageReader(kind: kind)
    var buckets = previous?.buckets ?? [:]
    var changed = false
    let add: (UsageContribution) -> Void = { contribution in
      if let id = contribution.messageId {
        // Counted from another file already: a resumed session's copy of an earlier message.
        if let owner = self.stored.claudeMessages[id], owner != key { return }
        self.stored.claudeMessages[id] = key
      }
      let day = contribution.at.map { UsageReport.dayKey($0) } ?? fallbackDay
      let project = Session.projectName(cwd: contribution.cwd)
      buckets["\(day)|\(contribution.model)|\(project)", default: TokenUsage()] += contribution.usage
      changed = true
    }
    if try !reader.read(url, add) {
      // Replaced by a shorter file: forget what the old one counted and read it again.
      stored.claudeMessages = stored.claudeMessages.filter { $0.value != key }
      reader = UsageReader(kind: kind)
      buckets = [:]
      _ = try reader.read(url, add)
      changed = true
    }
    if previous?.reader.offset != reader.offset { changed = true }
    stored.files[key] = FileEntry(reader: reader, buckets: buckets)
    return changed
  }

  static func transcripts(under root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      // Regular files only: never follow a symlink out of the agent's directory.
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.append(url) }
    }
    return result.sorted { $0.path < $1.path }
  }

  private func save() throws {
    try FileManager.default.createDirectory(
      at: cache.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(stored).write(to: cache, options: .atomic)
  }
}
