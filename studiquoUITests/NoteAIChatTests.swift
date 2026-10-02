import XCTest

/// Pins the note editor's AIトーク behaviour before its state is moved into a
/// shared store (see the AI home tab work). The editor runs against a
/// deterministic provider (`--note-ai-chat-ui-test`): it echoes the question
/// as "テスト返答: <question>", and a question containing "ゆっくり" streams
/// for ~30s so the stop button can be exercised.
///
/// `--note-ai-chat-auto-open` seeds one conversation ("既存の会話") and opens
/// the chat beside the note without a tap.
final class NoteAIChatTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test", "--note-ai-chat-auto-open"]
        app.launch()
        XCTAssertTrue(
            button("ai-chat-thread-既存の会話").waitForExistence(timeout: 30),
            "既存の会話が履歴に表示されません。"
        )
        XCTAssertTrue(waitForDraftField(), "AIチャットの入力欄が開きません。")
    }

    override func tearDown() {
        // The orientation outlives the test run; leave the simulator the way
        // other UI tests (some of which compare screenshot pixels) expect it.
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Typed queries only: a `.any` descendant query over the editor (ink
    /// canvas included) times out while the snapshot is being taken.
    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }

    /// A vertical-axis TextField is exposed as a text view on some OS
    /// versions and as a text field on others.
    private var draftField: XCUIElement {
        let textView = app.textViews["ai-chat-draft"]
        return textView.exists ? textView : app.textFields["ai-chat-draft"]
    }

    private func waitForDraftField(timeout: TimeInterval = 10) -> Bool {
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
        button("ai-chat-send").tap()
    }

    func testSendingAppendsTheStreamedReplyToTheOpenThreadWithoutRetitlingIt() {
        XCTAssertTrue(app.staticTexts["既存の返答"].exists, "既存の会話の内容が表示されていません。")
        send("こんにちは")
        XCTAssertTrue(app.staticTexts["テスト返答: こんにちは"].waitForExistence(timeout: 10), "返答が表示されません。")
        XCTAssertTrue(app.staticTexts["こんにちは"].exists, "自分の発言が表示されません。")
        XCTAssertTrue(app.staticTexts["既存の返答"].exists, "以前のやり取りが消えています。")
        XCTAssertTrue(button("ai-chat-thread-既存の会話").exists, "2通目以降で会話名が変わってはいけません。")
    }

    func testStopButtonCancelsAStreamingReply() {
        send("ゆっくり答えて")
        let stop = button("ai-chat-stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "返答中に停止ボタンが表示されません。")
        stop.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "（中断しました）")).firstMatch
                .waitForExistence(timeout: 10),
            "中断の表示が出ません。"
        )
        XCTAssertTrue(button("ai-chat-send").waitForExistence(timeout: 5), "中断後に送信ボタンへ戻りません。")
    }

    func testNewTalkStartsASeparateThreadTitledFromItsFirstMessage() {
        button("ai-chat-new-thread").tap()
        XCTAssertFalse(app.staticTexts["既存の返答"].exists, "新しいトークに前の会話が残っています。")

        send("二番目の質問")
        XCTAssertTrue(app.staticTexts["テスト返答: 二番目の質問"].waitForExistence(timeout: 10))
        XCTAssertTrue(button("ai-chat-thread-二番目の質問").waitForExistence(timeout: 5), "最初の発言が会話名になりません。")

        button("ai-chat-thread-既存の会話").tap()
        XCTAssertTrue(app.staticTexts["既存の返答"].waitForExistence(timeout: 5), "履歴から前の会話を開けません。")
        XCTAssertFalse(app.staticTexts["テスト返答: 二番目の質問"].exists, "別の会話の内容が混ざっています。")
    }

    func testUnsentDraftIsKeptPerThread() {
        let draft = draftField
        draft.tap()
        draft.typeText("書きかけ")

        button("ai-chat-new-thread").tap()
        XCTAssertNotEqual(draftField.value as? String, "書きかけ", "新しいトークに別会話の下書きが残っています。")

        button("ai-chat-thread-既存の会話").tap()
        XCTAssertEqual(draftField.value as? String, "書きかけ", "元の会話の下書きが保持されていません。")
    }

    func testDeletingAThreadRemovesItFromHistory() {
        let row = button("ai-chat-thread-既存の会話")
        row.swipeLeft()
        // The toolbar has a trash button with the same label, so pick the
        // swipe action that sits on the history row.
        let rowFrame = row.frame
        let deleteButtons = app.buttons.matching(NSPredicate(format: "label == %@", "削除"))
        XCTAssertTrue(deleteButtons.firstMatch.waitForExistence(timeout: 5), "スワイプで削除ボタンが出ません。")
        let delete = deleteButtons.allElementsBoundByIndex.first {
            $0.frame.midY >= rowFrame.minY && $0.frame.midY <= rowFrame.maxY
        }
        XCTAssertNotNil(delete, "履歴の行に削除ボタンが出ません。")
        delete?.tap()
        XCTAssertTrue(
            app.staticTexts["このトークを削除しますか？"].waitForExistence(timeout: 5),
            "削除の確認が表示されません。"
        )
        let confirm = app.buttons["はい"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "確認の「はい」ボタンが見つかりません。")
        confirm.tap()
        XCTAssertTrue(
            button("ai-chat-thread-既存の会話").waitForNonExistence(timeout: 5),
            "削除した会話が履歴に残っています。"
        )
    }
}


/// Regression: opening the chat beside a one-page note, with no earlier
/// conversation, used to send `ContinuousPagesView` into an endless layout
/// pass (100% CPU, app never idle) whenever the pane was about as tall as one
/// page. Every later query then timed out. Tapping the toolbar button is what
/// reproduced it, so this goes through the real tap rather than the fixture's
/// auto-open.
final class NoteAIChatOpenTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testOpeningTheChatFromTheToolbarWithNoConversationKeepsTheAppResponsive() {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test"]
        app.launch()

        let toolbar = app.buttons["note-ai-toolbar-button"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 20), "ツールバーのAIトークボタンが見つかりません。")
        toolbar.tap()

        XCTAssertTrue(
            app.buttons["ai-chat-new-thread"].waitForExistence(timeout: 15),
            "AIチャットを開いた後にアプリが応答しません(レイアウトの無限ループ)。"
        )
        let draft = app.textViews["ai-chat-draft"].exists ? app.textViews["ai-chat-draft"] : app.textFields["ai-chat-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "AIチャットの入力欄が見つかりません。")
    }
}
