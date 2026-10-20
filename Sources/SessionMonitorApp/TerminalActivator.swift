import AppKit
import SMCore

@MainActor enum TerminalActivator {
  static func bundle(for program: String?) throws -> String {
    try TerminalPolicy.activationBundle(
      program: program,
      running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
  }

  static func activate(bundle: String) async throws {
    guard
      let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundle
      }), let url = app.bundleURL
    else { throw MonitorError.invalid("terminal \(bundle) is not running") }
    // macOS 14 cooperative activation may silently ignore NSRunningApplication.activate() from an
    // accessory app that is not frontmost; openApplication(activates:) brings the running app forward.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }
}
