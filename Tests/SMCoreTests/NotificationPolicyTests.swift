import AppKit
import Foundation
import Testing

@testable import SMCore

@Suite struct NotificationPolicyTests {
  @Test func debouncePerSessionAndStateAndPreference() throws {
    let epoch = Date(timeIntervalSince1970: 1000)
    var policy = NotificationPolicy()
    let event = AgentEvent(sessionId: "id", agentPid: 42, at: epoch, type: .stop)
    var session = try SessionReducer.reduce(nil, event)
    let disabled = policy.reserve(session, enabled: false, now: epoch)
    #expect(!disabled)
    let first = policy.reserve(session, enabled: true, now: epoch)
    #expect(first)
    let duplicate = policy.reserve(session, enabled: true, now: epoch.addingTimeInterval(9.99))
    #expect(!duplicate)
    let afterDebounce = policy.reserve(session, enabled: true, now: epoch.addingTimeInterval(10))
    #expect(afterDebounce)
    session.state = .needsInput
    let differentState = policy.reserve(session, enabled: true, now: epoch.addingTimeInterval(10))
    #expect(differentState)
    session.state = .working
    let working = policy.reserve(session, enabled: true, now: epoch.addingTimeInterval(10))
    #expect(!working)
  }

  /// Regression: "rectangle.stack.badge.exclamationmark" does not exist; the icon went blank.
  @Test func statusIconSymbolsExist() {
    for name in StatusIconPolicy.all {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
    #expect(NSImage(systemSymbolName: "rectangle.stack.badge.exclamationmark", accessibilityDescription: nil) == nil)
  }
}
