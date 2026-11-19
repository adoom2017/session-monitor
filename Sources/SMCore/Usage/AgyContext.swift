import Foundation

public struct AgyContext: Codable, Equatable, Sendable {
  let conversationID: String
  let tokens: Int
  let window: Int

  private struct StatusLine: Decodable {
    struct Window: Decodable {
      let total_input_tokens: Int
      let context_window_size: Int
    }

    let conversation_id: String?
    let context_window: Window?
  }

  /// The status line can render repeatedly with the same input. Persist only the context
  /// snapshot, and replace it only when the context or conversation has changed.
  public static func record(_ input: Data, home: URL, pid: Int32) throws {
    let status = try JSONDecoder().decode(StatusLine.self, from: input)
    guard let id = status.conversation_id, !id.isEmpty,
      let context = status.context_window, context.context_window_size > 0, context.total_input_tokens >= 0
    else { return }
    let snapshot = AgyContext(conversationID: id, tokens: context.total_input_tokens, window: context.context_window_size)
    let url = snapshotURL(home: home, pid: pid)
    if read(url) == snapshot { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
  }

  static func current(for session: Session, home: URL) -> AgyContext? {
    guard let pid = session.pid, let snapshot = read(snapshotURL(home: home, pid: pid)),
      snapshot.conversationID == session.currentSessionId
    else { return nil }
    return snapshot
  }

  static func conversationID(home: URL, pid: Int32, startedAt: Date?) -> String? {
    let url = snapshotURL(home: home, pid: pid)
    guard let startedAt,
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modified >= startedAt
    else { return nil }
    return read(url)?.conversationID
  }

  private static func snapshotURL(home: URL, pid: Int32) -> URL {
    home.appendingPathComponent(".session-monitor/agy-context/\(pid).json")
  }

  private static func read(_ url: URL) -> AgyContext? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(AgyContext.self, from: data)
  }
}
