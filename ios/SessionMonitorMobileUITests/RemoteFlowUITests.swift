import XCTest

/// Drives the real app against a running Mac (R3). Needs an already paired simulator and
/// SM_UITEST_SESSION (public session id of a tmux session showing a permission menu).
/// Run: SM_UITEST_SESSION=<id> xcodebuild test … (the variable is forwarded as TEST_RUNNER_…).
final class RemoteFlowUITests: XCTestCase {
  @MainActor func testAnswerMenuThenSendMessage() throws {
    let session = try XCTUnwrap(ProcessInfo.processInfo.environment["SM_UITEST_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-SMOpenSession", session]
    app.launch()

    // The permission menu parsed from the pane: press "No".
    let no = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "No")).firstMatch
    XCTAssertTrue(no.waitForExistence(timeout: 20), "menu option No not shown")
    no.tap()
    let menuGone = NSPredicate(format: "exists == false")
    expectation(for: menuGone, evaluatedWith: no)
    waitForExpectations(timeout: 15)

    // Type and send a message.
    let field = app.textFields["发送消息到终端"].exists ? app.textFields["发送消息到终端"] : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText("来自手机 UI 测试，只回复：OK")
    app.buttons["发送"].tap()
    let delivered = app.staticTexts["已送达"]
    XCTAssertTrue(delivered.waitForExistence(timeout: 15), "no delivery confirmation")
  }
}
