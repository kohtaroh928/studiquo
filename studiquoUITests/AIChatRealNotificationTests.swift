import XCTest

/// Sends and taps a real system notification on the simulator: the answer
/// finishes while the app is in the background, the banner appears, and
/// tapping it opens the conversation. Everything the other notification tests
/// replace with a recorder is real here (permission, delivery, the tap).
final class AIChatRealNotificationTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func tearDown() {
        // The orientation outlives the test run; leave the simulator portrait
        // for other UI tests that compare screenshot pixels.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func allowNotificationsIfAsked() {
        for label in ["Allow", "許可", "Allow Notifications"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 4) {
                button.tap()
                return
            }
        }
    }

    func testAnAnswerFinishingInTheBackgroundShowsABannerThatOpensTheConversation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai", "--ui-test-real-notifications"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
        allowNotificationsIfAsked()

        app.buttons["home-tab-ai"].tap()
        let draft = app.textViews["ai-chat-draft"].waitForExistence(timeout: 10)
            ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
        draft.tap()
        draft.typeText("ちょっと待って")
        app.buttons["ai-chat-send"].tap()

        // Leave before the answer arrives: the app goes to the background.
        XCUIDevice.shared.press(.home)

        let banner = springboard.staticTexts["ちょっと待って"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "通知バナーが表示されません。")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "通知をタップしてもアプリが前面に来ません。")
        XCTAssertTrue(
            app.buttons["ai-chat-thread-ちょっと待って"].waitForExistence(timeout: 15),
            "通知から会話が開きません。"
        )
        XCTAssertTrue(app.staticTexts["テスト返答: ちょっと待って"].exists, "通知の会話が選択されていません。")
    }

    private func openNotificationCenter() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        top.press(forDuration: 0.1, thenDragTo: bottom)
    }

    func testComingBackToTheConversationTakesItsNotificationOutOfTheNotificationCenter() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai", "--ui-test-real-notifications"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
        allowNotificationsIfAsked()

        app.buttons["home-tab-ai"].tap()
        let draft = app.textViews["ai-chat-draft"].waitForExistence(timeout: 10)
            ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
        draft.tap()
        draft.typeText("ちょっと待って")
        app.buttons["ai-chat-send"].tap()
        XCUIDevice.shared.press(.home)

        // The banner arrives; leave it alone so it moves to the notification centre.
        XCTAssertTrue(springboard.staticTexts["ちょっと待って"].waitForExistence(timeout: 20), "通知バナーが表示されません。")
        Thread.sleep(forTimeInterval: 8)

        // Control: while the app has not been looked at, the notification is in the centre.
        openNotificationCenter()
        XCTAssertTrue(
            springboard.staticTexts["ちょっと待って"].waitForExistence(timeout: 8),
            "通知センターに通知が見つかりません(確認手順の前提)。"
        )
        XCUIDevice.shared.press(.home)

        // Back in the app: the conversation is on screen again, so its notification goes.
        app.activate()
        XCTAssertTrue(app.buttons["ai-chat-thread-ちょっと待って"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        openNotificationCenter()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(
            springboard.staticTexts["ちょっと待って"].exists,
            "会話を見た後も通知が通知センターに残っています。"
        )
    }
}
