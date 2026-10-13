import XCTest

final class FriendsSidebarDefaultTests: XCTestCase {
    func testFullWindowStartsWithChatHistoryAndCanToggleSidebarRepeatedly() {
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
        XCTAssertFalse(app.buttons["申請・招待"].isHittable)
        let toggle = app.buttons["friends-sidebar-toggle"]
        for _ in 0..<2 {
            toggle.tap()
            XCTAssertTrue(app.buttons["申請・招待"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["申請・招待"].isHittable)
            app.buttons["friends-sidebar-close"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["申請・招待"].isHittable)
            XCTAssertTrue(app.navigationBars["メッセージ"].exists)
        }
    }
}
