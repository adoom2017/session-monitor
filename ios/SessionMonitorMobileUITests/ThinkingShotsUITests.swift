import XCTest

/// Scrolls up a little through a conversation (SM_UITEST_SESSION) and saves screenshots to
/// SM_UITEST_SHOTS, for checking how thinking entries look.
final class ThinkingShotsUITests: XCTestCase {
  @MainActor func testScreenshotsWhileScrollingUp() throws {
    let env = ProcessInfo.processInfo.environment
    let session = try XCTUnwrap(env["SM_UITEST_SESSION"])
    let shots = try XCTUnwrap(env["SM_UITEST_SHOTS"])
    let app = XCUIApplication()
    app.launchArguments = ["-SMOpenSession", session, "-SMTab", "对话"]
    app.launch()
    sleep(8)
    for round in 1...4 {
      app.swipeDown(velocity: .slow)
      sleep(1)
      try XCUIScreen.main.screenshot().pngRepresentation
        .write(to: URL(fileURLWithPath: "\(shots)/thinking-\(round).png"))
    }
  }
}
