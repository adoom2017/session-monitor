import XCTest

/// Scrolls back through a long conversation (SM_UITEST_SESSION) and saves screenshots to
/// SM_UITEST_SHOTS, for checking history paging by eye.
final class HistoryUITests: XCTestCase {
  @MainActor func testScrollBackThroughHistory() throws {
    let env = ProcessInfo.processInfo.environment
    let session = try XCTUnwrap(env["SM_UITEST_SESSION"])
    let shots = try XCTUnwrap(env["SM_UITEST_SHOTS"])
    let app = XCUIApplication()
    app.launchArguments = ["-SMOpenSession", session, "-SMTab", "对话"]
    app.launch()
    sleep(8)
    for round in 1...3 {
      for _ in 0..<8 { app.swipeDown(velocity: .fast) }
      sleep(3)
      try XCUIScreen.main.screenshot().pngRepresentation
        .write(to: URL(fileURLWithPath: "\(shots)/history-\(round).png"))
    }
    XCTAssertEqual(app.state, .runningForeground)
  }
}
