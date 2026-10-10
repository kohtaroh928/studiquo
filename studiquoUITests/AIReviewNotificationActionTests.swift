import XCTest

/// Taps the real "文書として残す" button on an AI復習 notification on the
/// simulator, then checks the document landed in the AI復習 folder.
final class AIReviewNotificationActionTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func allowNotificationsIfAsked() {
        for label in ["Allow", "許可", "Allow Notifications"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 4) { button.tap(); return }
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai",
                               "--ui-test-real-notifications", "--ui-test-ai-review-notification"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
        allowNotificationsIfAsked()
        return app
    }

    func testKeepButtonFilesTheDocumentInTheReviewFolder() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        XCUIDevice.shared.press(.home)

        let banner = springboard.staticTexts["復習の時間です"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "通知バナーが表示されません。")
        // Let the banner settle into the notification centre, then open it.
        Thread.sleep(forTimeInterval: 8)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        let entry = springboard.staticTexts["復習の時間です"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "通知センターに通知がありません。")
        entry.press(forDuration: 1.5)
        let keep = springboard.buttons["文書として残す"]
        if !keep.waitForExistence(timeout: 5) {
            let shot = XCTAttachment(screenshot: springboard.screenshot()); shot.lifetime = .keepAlways; add(shot)
            XCTFail("「文書として残す」ボタンが出ません。")
            return
        }
        keep.tap()

        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.staticTexts["AI復習"].firstMatch.waitForExistence(timeout: 15)
                || app.buttons["AI復習"].firstMatch.waitForExistence(timeout: 5),
            "AI復習フォルダが表示されません。"
        )
    }
}
