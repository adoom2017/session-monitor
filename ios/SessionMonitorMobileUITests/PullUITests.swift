import XCTest

/// Scrolls a long conversation slowly toward its top, then stops and waits: the history spinner
/// must not stay on screen (it used to turn forever, R4). Saves screenshots to SM_UITEST_SHOTS.
final class PullUITests: XCTestCase {
  @MainActor func testSpinnerAtTopLoadsAndGoesAway() throws {
    let env = ProcessInfo.processInfo.environment
    let shots = try XCTUnwrap(env["SM_UITEST_SHOTS"])
    let session = try XCTUnwrap(env["SM_UITEST_SESSION"])
    func shot(_ name: String) throws {
      try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/pull-\(name).png"))
    }
    let app = XCUIApplication()
    app.launchArguments = ["-SMOpenSession", session, "-SMTab", "对话"]
    app.launch()
    sleep(8)
    let spinner = app.activityIndicators.firstMatch
    var swipes = 0
    while !(spinner.exists && spinner.isHittable), swipes < 60 {
      app.swipeDown(velocity: .slow)
      swipes += 1
    }
    // A long history keeps loading page after page while scrolling; reaching the very top is
    // not required, only that a waiting spinner does not stay.
    try shot("1-reached-top")
    sleep(6)
    try shot("2-after-wait")
    XCTAssertFalse(spinner.exists && spinner.isHittable, "spinner still on screen after waiting")
  }
}
