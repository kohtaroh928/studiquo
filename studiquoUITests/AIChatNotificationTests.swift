import XCTest

/// When an AI answer finishes, a notification is wanted only if the student is
/// not looking at that conversation — wherever else they are in the app, and
/// even if the conversation has a tab in the note's tab bar. The fixture
/// records the notifications the app asks for (`ai-completion-probe`) instead
/// of sending real ones. The fake AI answers "少し待って" after three seconds.
final class AIChatNotificationTests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        // The orientation outlives the test run; leave the simulator portrait
        // for other UI tests that compare screenshot pixels.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(_ extra: [String] = []) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20))
    }

    // MARK: Helpers

    private var completion: String { app.otherElements["ai-completion-probe"].label }
    private var viewing: String { app.otherElements["ai-viewing-probe"].label }

    private func wait(_ description: String, timeout: TimeInterval = 12, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(condition(), "Timed out: \(description) (completion=\(completion), viewing=\(viewing))")
    }

    private var draftField: XCUIElement {
        let textView = app.textViews["ai-chat-draft"]
        return textView.exists ? textView : app.textFields["ai-chat-draft"]
    }

    private func waitForDraftField() {
        wait("the chat input appears") { app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists }
    }

    private func send(_ text: String) {
        waitForDraftField()
        let draft = draftField
        draft.tap()
        draft.typeText(text)
        app.buttons["ai-chat-send"].tap()
    }

    private func openHomeAI() {
        app.buttons["home-tab-ai"].tap()
        waitForDraftField()
    }

    private func openNotebookAndItsAI() {
        app.buttons["home-tab-notes"].tap()
        let row = app.descendants(matching: .any)["library-entry-Drag me"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let toolbar = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 20))
        toolbar.tap()
        waitForDraftField()
    }

    // MARK: Tests

    func testNoNotificationWhileTheAnswerIsOnScreen() {
        launch()
        openHomeAI()
        send("見ている")
        XCTAssertTrue(app.staticTexts["テスト返答: 見ている"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(completion.hasPrefix("notified=;"), "見ている最中に通知が出ています: \(completion)")
    }

    func testAnAnswerThatFinishesAfterLeavingTheChatIsAnnouncedAndClearedOnReturn() {
        launch()
        openHomeAI()
        send("少し待って")
        app.buttons["home-tab-calendar"].tap() // leave before the answer arrives

        wait("the notification is requested") { completion.hasPrefix("notified=少し待って;") }
        // Sending already cleared once: the new conversation came into view
        // (still called by its placeholder name at that instant).
        XCTAssertTrue(completion.hasSuffix("cleared=新しいトーク"), "離れている間に余計に消しています: \(completion)")

        // Coming back to that conversation takes the notification away again.
        app.buttons["home-tab-ai"].tap()
        wait("the notification is cleared") { completion.hasSuffix("cleared=新しいトーク,少し待って") }
    }

    func testAnAnswerFinishingWhileTheChatIsClosedInTheNoteIsAnnounced() {
        launch()
        openNotebookAndItsAI()
        send("少し待って")
        // Close the chat pane; the conversation keeps its tab in the tab bar.
        app.buttons["note-ai-toolbar-button"].tap()
        wait("the chat is closed") { viewing == "screens=0;viewing=-" }

        wait("the notification is requested") { completion.hasPrefix("notified=少し待って;") }
    }

    func testTappingTheNotificationOpensTheAITabOnThatConversation() {
        launch(["--ui-test-ai-notification-route"])
        // The fixture simulates the tap a few seconds after launch.
        wait("the AI tab opens", timeout: 20) { app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists }
        XCTAssertTrue(app.buttons["ai-chat-thread-通知から"].waitForExistence(timeout: 5), "通知の会話が履歴にありません。")
        XCTAssertTrue(app.staticTexts["通知の返答"].exists, "通知の会話が選択されていません。")
        wait("it counts as viewed") { viewing == "screens=1;viewing=通知から" }
    }
}
