import Foundation

public struct NotificationPolicy: Sendable {
  private var sent: [String: Date] = [:]
  public init() {}
  public mutating func reserve(_ session: Session, enabled: Bool, now: Date) -> Bool {
    guard enabled, [.needsPermission, .needsInput, .done].contains(session.state) else {
      return false
    }
    let key = session.id + ":" + session.state.rawValue
    if let previous = sent[key], now.timeIntervalSince(previous) < 10 { return false }
    sent[key] = now
    // Ended sessions do not require unbounded debounce history.
    if sent.count > 1024 { sent = sent.filter { now.timeIntervalSince($0.value) < 10 } }
    return true
  }
}

/// Menu bar icon. Only symbols that exist in SF Symbols (verified by a test): an invalid name
/// yields a nil image and an invisible status item.
public enum StatusIconPolicy {
  public static let normal = "rectangle.stack"
  public static let attention = "rectangle.stack.fill"
  public static let all = [normal, attention]
  public static func symbolName(attention count: Int) -> String { count > 0 ? attention : normal }
}
