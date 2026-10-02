import XCTest
final class ReproHangTests: XCTestCase {
    func testRepro() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test"]
        app.launch()
        let toolbar = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 20))
        toolbar.tap()
        Thread.sleep(forTimeInterval: 70)
    }
}
