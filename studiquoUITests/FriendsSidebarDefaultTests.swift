import XCTest

final class FriendsSidebarDefaultTests: XCTestCase {
    func testFullWindowDoesNotShowTheCompactOnlySidebarButton() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-friends"].waitForExistence(timeout: 20))
        app.buttons["home-tab-friends"].tap()
        XCTAssertTrue(app.navigationBars["メッセージ"].waitForExistence(timeout: 10))
        if app.alerts["エラー"].waitForExistence(timeout: 2) { app.alerts["エラー"].buttons["OK"].tap() }
        XCTAssertFalse(app.buttons["friends-sidebar-toggle"].exists)
        XCTAssertTrue(app.navigationBars["メッセージ"].exists)
    }
}
