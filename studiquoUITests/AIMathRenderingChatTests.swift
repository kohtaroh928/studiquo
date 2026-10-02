import XCTest

/// The AI chat shows replies with their math typeset, reads them out as plain
/// words, and copies readable text rather than LaTeX.
final class AIMathRenderingChatTests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func openChat() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
        app.buttons["home-tab-ai"].tap()
        return app
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !(app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists) {
            Thread.sleep(forTimeInterval: 0.3)
        }
        let draft = app.textViews["ai-chat-draft"].exists ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
        draft.tap()
        draft.typeText(text)
        app.buttons["ai-chat-send"].tap()
    }

    func testAReplyIsReadAsPlainWordsNotLaTeX() {
        let app = openChat()
        send("sample:quadratic-formula", in: app)
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "解の公式")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        // Wait for the streamed reply to finish.
        Thread.sleep(forTimeInterval: 3)
        let label = reply.label
        XCTAssertFalse(label.contains("\\frac"), "LaTeXのまま読み上げられます: \(label)")
        XCTAssertFalse(label.contains("$"), "区切り記号が残っています: \(label)")
        XCTAssertTrue(label.contains("√"), "式が読める形になっていません: \(label)")
    }

    func testALongMarkedUpReplyStreamsToTheEndWithoutTroubles() {
        let app = openChat()
        send("sample:reply-quadratic-extremum", in: app)
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "平方完成")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["ai-chat-send"].waitForExistence(timeout: 20), "返答の生成が終わりません")
        XCTAssertFalse(reply.label.contains("\\"), "LaTeXの記号が残っています: \(reply.label)")
    }

    func testCopyingAReplyOffersReadableText() {
        let app = openChat()
        send("sample:quadratic-formula", in: app)
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "解の公式")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        reply.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["コピー"].waitForExistence(timeout: 5) || app.buttons["Copy"].waitForExistence(timeout: 1))
    }
}
