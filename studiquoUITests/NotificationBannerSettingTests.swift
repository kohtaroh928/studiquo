import XCTest

/// Each kind of notification has a "バナーで知らせる" switch under its own
/// on/off switch, in the gear's settings → 通知. Off keeps the notification
/// but makes it quiet (no banner, no sound; it only lands in the notification
/// centre). The fixture resets every notification setting at launch.
final class NotificationBannerSettingTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-notes"].waitForExistence(timeout: 20), "ホーム画面が表示されません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Helpers

    private func openNotificationSettings() {
        app.buttons["home-tab-notes"].tap()
        let overflow = app.buttons["OverflowBarButtonItem"]
        let gear = app.buttons["設定"]
        let deadline = Date().addingTimeInterval(10)
        while !overflow.exists && !(gear.exists && gear.isHittable) && Date() < deadline {
            _ = overflow.waitForExistence(timeout: 0.5)
        }
        if !(gear.exists && gear.isHittable) && overflow.exists { overflow.tap() }
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "ノート画面に設定(歯車)ボタンがありません。")
        gear.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10), "設定シートが開きません。")
        sleep(1)

        let row = app.buttons["settings-notifications"]
        reveal(row)
        XCTAssertTrue(row.exists, "設定に「通知」の行がありません。")
        row.tap()
        XCTAssertTrue(app.navigationBars["通知"].waitForExistence(timeout: 10), "通知の設定画面が開きません。")
    }

    /// Rows are built lazily — a row exists only while it is on screen — so
    /// the list must be scrolled in steps smaller than what is visible.
    /// `app.swipeUp()` is not: its distance follows the whole window, about
    /// 700pt however small the sheet is, so it steps clean over the rows in
    /// between and the search can fail depending on where the list comes to
    /// rest. Swiping the sheet's own list moves it by a fraction of its height.
    private func reveal(_ row: XCUIElement) {
        guard !isReachable(row) else { return }
        for _ in 0..<14 {
            scroll(up: true)
            if isReachable(row) { return }
        }
        for _ in 0..<28 {
            scroll(up: false)
            if isReachable(row) { return }
        }
    }

    /// Swipes the sheet's list; if it cannot be found for a moment (the form
    /// is rebuilding), falls back to the whole window rather than doing nothing.
    private func scroll(up: Bool) {
        let target: XCUIElement = sheetList() ?? app
        if up { target.swipeUp(velocity: .slow) } else { target.swipeDown(velocity: .slow) }
    }

    /// The settings sheet's list: the narrow one (the home list behind it is
    /// far wider).
    private func sheetList() -> XCUIElement? {
        let lists = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        return lists.filter { $0.exists && $0.frame.width < 700 && $0.frame.height > 200 }.first
    }

    private var navigationBarBottom: CGFloat {
        app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
    }

    /// On screen, hittable, and not under the translucent navigation bar — a
    /// row there is reported hittable, but a tap lands on the bar.
    private func isReachable(_ row: XCUIElement) -> Bool {
        row.exists && row.isHittable && row.frame.minY >= navigationBarBottom + 4
    }

    private func kindSwitch(_ kind: String) -> XCUIElement { app.switches["notification-\(kind)"] }
    private func bannerSwitch(_ kind: String) -> XCUIElement { app.switches["notification-banner-\(kind)"] }

    private func value(_ element: XCUIElement) -> String {
        reveal(element)
        XCTAssertTrue(element.exists, "スイッチが見つかりません: \(element)")
        return "\(element.value ?? "")"
    }

    private func flip(_ element: XCUIElement) {
        reveal(element)
        let before = "\(element.value ?? "")"
        let width = element.frame.width
        element.coordinate(withNormalizedOffset: CGVector(dx: max(0.5, (width - 60) / width), dy: 0.5)).tap()
        // Turning a notification off removes its banner row, and the list
        // re-lays out; the switch can be briefly missing, and reading `value`
        // of a missing element is an error — so check it exists first.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if element.exists, "\(element.value ?? "")" != before { break }
            usleep(200_000)
        }
    }

    // MARK: Tests

    func testEveryKindShowsABannerSwitchThatIsOnByDefault() {
        openNotificationSettings()
        for kind in ["calendarDeadline", "flashcardReview", "studyStreak", "studyReminder", "friendMessage", "aiReview", "aiTaskComplete"] {
            XCTAssertEqual(value(kindSwitch(kind)), "1", "\(kind) の通知は既定でオンです。")
            XCTAssertEqual(value(bannerSwitch(kind)), "1", "\(kind) の「バナーで知らせる」は既定でオンです。")
        }
    }

    func testTurningTheBannerOffKeepsTheNotificationOnAndIsRemembered() {
        openNotificationSettings()
        flip(bannerSwitch("friendMessage"))
        XCTAssertEqual(value(bannerSwitch("friendMessage")), "0", "バナーをオフにできません。")
        XCTAssertEqual(value(kindSwitch("friendMessage")), "1", "バナーをオフにしても通知自体はオンのままです。")
        XCTAssertEqual(value(bannerSwitch("groupInvite")), "1", "ほかの通知のバナーは変わりません。")

        // Back out and in again: the choice is stored.
        app.navigationBars["通知"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        let row = app.buttons["settings-notifications"]
        reveal(row)
        row.tap()
        XCTAssertTrue(app.navigationBars["通知"].waitForExistence(timeout: 10))
        XCTAssertEqual(value(bannerSwitch("friendMessage")), "0", "バナーの設定が保存されていません。")
    }

    func testTurningANotificationOffHidesItsBannerSwitch() {
        openNotificationSettings()
        flip(kindSwitch("friendRequest"))
        XCTAssertEqual(value(kindSwitch("friendRequest")), "0", "通知をオフにできません。")
        // The row leaves with an animation, so wait for it instead of reading at once.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bannerSwitch("friendRequest"))
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(bannerSwitch("groupInvite").exists, "ほかの通知の設定は残ります。")
    }
}
