import XCTest

/// Tapping outside the message field puts the keyboard away (SM_UITEST_SESSION: a tmux session).
final class KeyboardUITests: XCTestCase {
  @MainActor func testTapOutsideDismissesKeyboard() throws {
    let session = try XCTUnwrap(ProcessInfo.processInfo.environment["SM_UITEST_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-SMOpenSession", session, "-SMTab", "对话"]
    app.launch()
    let field = app.textFields["发送消息到终端"].exists ? app.textFields["发送消息到终端"] : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    field.tap()
    // The simulator may use the Mac keyboard (no on-screen keyboard), so check input focus, which
    // is what shows or hides the keyboard on a phone.
    func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
    XCTAssertTrue(focused(), "field did not take focus")
    // Tap the conversation area, well above the input bar.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
    let deadline = Date().addingTimeInterval(5)
    while focused(), Date() < deadline { usleep(200_000) }
    XCTAssertFalse(focused(), "field kept focus after tapping outside")
  }
}
