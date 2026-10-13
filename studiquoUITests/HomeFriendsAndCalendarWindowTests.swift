import XCTest

final class HomeFriendsAndCalendarWindowTests: XCTestCase {
    private func launch(halfWidth: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        if halfWidth { app.launchArguments += ["--compact-library-ui-test", "--half-width-window-ui-test"] }
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-friends"].waitForExistence(timeout: 20))
        return app
    }

    func testFriendsTabDisplaysItsOwnNavigationInFullWindow() {
        let app = launch()
        app.buttons["home-tab-friends"].tap()
        XCTAssertTrue(app.navigationBars["メッセージ"].waitForExistence(timeout: 10))
        if app.alerts["エラー"].exists { app.alerts["エラー"].buttons["OK"].tap() }
        XCTAssertTrue(app.buttons["friends-sidebar-toggle"].waitForExistence(timeout: 5))
        app.buttons["friends-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["申請・招待"].waitForExistence(timeout: 5))
        // This in-memory library fixture has no authenticated friend session.
        // Its background refresh may present an error; dismiss that expected
        // fixture-only dialog before exercising the bottom-tab navigation.
        if app.alerts["エラー"].exists {
            app.alerts["エラー"].buttons["OK"].tap()
        }
        XCTAssertTrue(app.buttons["home-tab-calendar"].isHittable, app.debugDescription)
        app.buttons["home-tab-calendar"].tap()
        XCTAssertTrue(app.navigationBars["カレンダー"].waitForExistence(timeout: 5))
    }

    func testFriendsTabDisplaysItsOwnNavigationInCompactWindow() {
        let app = launch(halfWidth: true)
        app.buttons["home-tab-friends"].tap()
        XCTAssertTrue(app.navigationBars["メッセージ"].waitForExistence(timeout: 10))
        if app.alerts["エラー"].exists { app.alerts["エラー"].buttons["OK"].tap() }
        app.buttons["friends-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["申請・招待"].waitForExistence(timeout: 5))
        app.buttons["friends-sidebar-close"].tap()
        XCTAssertTrue(app.navigationBars["メッセージ"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["friends-sidebar-toggle"].isHittable)
    }

    func testHalfWindowCalendarCanCloseAndReopenDayEvents() {
        let app = launch(halfWidth: true)
        app.buttons["home-tab-calendar"].tap()
        let toggle = app.buttons["calendar-day-events-toggle"]
        let add = app.buttons["calendar-add-day-event"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(add.waitForExistence(timeout: 2))
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    func testFullWindowCalendarAlwaysDisplaysDayEventsWithoutToggle() {
        let app = launch()
        app.buttons["home-tab-calendar"].tap()
        XCTAssertTrue(app.buttons["calendar-add-day-event"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["calendar-day-events-toggle"].exists)
    }
}
