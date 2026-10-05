import XCTest

/// "エラー情報を自動送信" is on by default and can be turned off from the
/// gear's settings sheet; the privacy policy promises exactly that. The
/// fixture resets the setting to on at every launch, so each test starts
/// from the shipped default.
final class ErrorReportingSettingTests: XCTestCase {
    private var app: XCUIApplication!
    private let label = "エラー情報を自動送信"

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

    private func openGear() {
        app.buttons["home-tab-notes"].tap()
        // In portrait the toolbar folds the gear into the "さらに表示" menu.
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
    }

    private func closeGear() {
        app.navigationBars["設定"].buttons["完了"].tap()
        XCTAssertFalse(app.navigationBars["設定"].waitForExistence(timeout: 3), "「完了」で設定シートが閉じません。")
    }

    /// Rows are built lazily and the last lookup may have scrolled past
    /// this one: look down first, then back up.
    private func toggle() -> XCUIElement {
        let row = app.switches[label]
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        for _ in 0..<16 where !row.exists || !row.isHittable { app.swipeDown() }
        XCTAssertTrue(row.exists, "歯車のシートに「\(label)」がありません。")
        return row
    }

    private func value(_ row: XCUIElement) -> String { "\(row.value ?? "")" }

    func testIsOnByDefault() {
        openGear()
        XCTAssertEqual(value(toggle()), "1", "初期状態では自動送信がオンである必要があります。")
    }

    func testTurningItOffSticksAfterReopeningTheSettings() {
        openGear()
        toggle().coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(value(toggle()), "0", "スイッチをオフにできません。")
        closeGear()

        openGear()
        XCTAssertEqual(value(toggle()), "0", "オフにした設定が保存されていません。")
        toggle().coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(value(toggle()), "1", "スイッチをオンに戻せません。")
        closeGear()
    }
}
