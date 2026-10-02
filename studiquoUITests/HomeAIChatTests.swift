import XCTest

/// The home screen's AI tab and the note editor's AIトーク tool show one
/// shared conversation: what is started, selected or typed in either is there
/// in the other. Runs against the library fixture with a deterministic AI
/// (`--ui-test-fake-ai`: it answers "テスト返答: <question>").
final class HomeAIChatTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-fake-ai"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-ai"].waitForExistence(timeout: 20), "ホーム下部に「AI」タブがありません。")
    }

    // MARK: Helpers

    private func openHomeAI() {
        app.buttons["home-tab-ai"].tap()
        XCTAssertTrue(waitForDraftField(), "AIチャットが全画面で開きません。")
    }

    private var draftField: XCUIElement {
        let textView = app.textViews["ai-chat-draft"]
        return textView.exists ? textView : app.textFields["ai-chat-draft"]
    }

    private func waitForDraftField(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func send(_ text: String) {
        let draft = draftField
        draft.tap()
        draft.typeText(text)
        app.buttons["ai-chat-send"].tap()
    }

    private func openNotebookFromLibrary() {
        app.buttons["home-tab-notes"].tap()
        let row = app.descendants(matching: .any)["library-entry-Drag me"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "ノートの一覧が表示されません。")
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library-open-notebook-Drag me"].waitForExistence(timeout: 10),
            "ノートが開きません。"
        )
    }

    private func openEditorAI() {
        let toolbar = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 20), "ツールバーのAIトークボタンが見つかりません。")
        toolbar.tap()
        XCTAssertTrue(waitForDraftField(), "ツールバーのAIチャットが開きません。")
    }

    // MARK: Tests

    func testTheAITabOpensAFullScreenChatThatRepliesAndOffersNoPagePaste() {
        openHomeAI()
        XCTAssertTrue(app.buttons["home-tab-notes"].exists, "AI画面でも下部のタブは残ること")
        XCTAssertFalse(
            app.descendants(matching: .any)["library-entry-Drag me"].exists,
            "AI画面にノート一覧が混ざっています。"
        )

        send("ホームから")
        XCTAssertTrue(app.staticTexts["テスト返答: ホームから"].waitForExistence(timeout: 10), "返答が表示されません。")
        XCTAssertTrue(app.buttons["ai-chat-thread-ホームから"].exists, "履歴に会話が追加されていません。")

        // No page is open here, so the reply must not offer to paste onto one.
        app.staticTexts["テスト返答: ホームから"].press(forDuration: 1)
        XCTAssertFalse(
            app.buttons["ページに貼り付け"].waitForExistence(timeout: 2),
            "ホームのAIに「ページに貼り付け」が出ています。"
        )
    }

    func testAConversationStartedAtHomeIsTheOneOpenInTheEditorToolbarAI() {
        openHomeAI()
        send("ホームから")
        XCTAssertTrue(app.staticTexts["テスト返答: ホームから"].waitForExistence(timeout: 10))
        draftField.tap()
        draftField.typeText("書きかけ")

        openNotebookFromLibrary()
        openEditorAI()

        XCTAssertTrue(app.buttons["ai-chat-thread-ホームから"].waitForExistence(timeout: 10), "エディタの履歴にホームの会話がありません。")
        XCTAssertTrue(app.staticTexts["テスト返答: ホームから"].exists, "エディタが同じ会話を選択していません。")
        XCTAssertEqual(draftField.value as? String, "書きかけ", "ホームの下書きがエディタに引き継がれていません。")

        // The editor can paste onto a page, so there the menu item exists.
        app.staticTexts["テスト返答: ホームから"].press(forDuration: 1)
        XCTAssertTrue(
            app.buttons["ページに貼り付け"].waitForExistence(timeout: 5),
            "エディタのAIに「ページに貼り付け」が出ません。"
        )
    }

    func testAConversationStartedInTheEditorIsTheOneOpenInTheHomeAITab() {
        openNotebookFromLibrary()
        openEditorAI()
        send("エディタから")
        XCTAssertTrue(app.staticTexts["テスト返答: エディタから"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 5))
        app.buttons["ホームへ戻る"].tap()
        openHomeAI()

        XCTAssertTrue(app.buttons["ai-chat-thread-エディタから"].waitForExistence(timeout: 10), "ホームの履歴にエディタの会話がありません。")
        XCTAssertTrue(app.staticTexts["テスト返答: エディタから"].exists, "ホームが同じ会話を選択していません。")
    }
}
