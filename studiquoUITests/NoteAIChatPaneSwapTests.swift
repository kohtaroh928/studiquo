import XCTest

/// The AIトーク button swaps the chat into the pane opposite the one being
/// worked in, leaving that pane's own content in state so pressing the button
/// again hands it back. From a single screen it still opens the split.
///
/// Runs against the note-editor fixture (`--note-ai-chat-ui-test`) without a
/// seeded conversation, in portrait so the split is top/bottom.
final class NoteAIChatPaneSwapTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--note-ai-chat-ui-test"]
        app.launch()
        XCTAssertTrue(aiButton.waitForExistence(timeout: 30), "AIトークのボタンが表示されません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private var aiButton: XCUIElement { app.buttons["note-ai-toolbar-button"] }
    private var swappedPane: XCUIElement { app.descendants(matching: .any)["note-ai-swapped-pane"].firstMatch }
    private var primaryPane: XCUIElement { app.descendants(matching: .any)["split-pane-primary"].firstMatch }

    /// Layout changes animate; a tap during one can be swallowed.
    private func settle() { Thread.sleep(forTimeInterval: 1.5) }

    private var chatIsShown: Bool {
        app.textViews["ai-chat-draft"].exists || app.textFields["ai-chat-draft"].exists
    }

    private func waitForChat(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chatIsShown { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func waitForNoChat(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !chatIsShown { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// The pane opposite the note, whatever it shows: the split fixtures open
    /// the Files browser there, whose pane identifier carries its kind.
    private var companionPane: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "split-pane-secondary")
        ).firstMatch
    }

    /// Splits the note with the Files browser below it (portrait). The
    /// editor's own pane is the active one afterwards.
    private func splitWithFilesBrowser() {
        let menu = app.buttons["画面分割"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "画面分割のメニューがありません。")
        menu.tap()
        let item = app.buttons["ファイルアプリと2分割"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "ファイルアプリと2分割の項目がありません。")
        item.tap()
        XCTAssertTrue(companionPane.waitForExistence(timeout: 10), "2分割になりません。")
    }

    // MARK: 単画面

    func testSingleScreenOpensTheSplitAsBefore() {
        aiButton.tap()
        XCTAssertTrue(waitForChat(), "単画面でAIトークを押してもチャットが開きません。")
        XCTAssertFalse(swappedPane.exists, "単画面からの起動でペイン入れ替えになってはいけません。")
        settle()
        aiButton.tap()
        XCTAssertTrue(waitForNoChat(), "もう一度押すとチャットが閉じるはずです。")
    }

    // MARK: 2分割

    func testSplitSwapsTheChatIntoTheOppositePaneAndBackAgain() {
        splitWithFilesBrowser()
        XCTAssertFalse(chatIsShown, "分割しただけでAIトークが出ています。")

        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10), "2分割でAIトークがペインに入れ替わりません。")
        XCTAssertTrue(waitForChat(), "入れ替わったペインにチャットが表示されません。")
        XCTAssertFalse(app.buttons["note-ai-floating-to-pane"].exists, "入れ替えと同時に臨時画面が出ています。")

        // 操作中は上のペインなので、入れ替わるのは下のペイン。
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(swappedPane.frame.midY, window.midY, "操作中ペインの反対側(下)に入れ替わるはずです。")
        XCTAssertTrue(primaryPane.exists, "操作中のペインは残るはずです。")

        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "もう一度押しても元に戻りません。")
        XCTAssertTrue(waitForNoChat(), "戻したあともチャットが残っています。")
        XCTAssertTrue(companionPane.exists, "戻したあと2分割が崩れています。")
    }

    func testSwapFollowsTheActivePane() {
        splitWithFilesBrowser()
        // 「画面を入れ替え」でノートが下のペインへ移り、操作中のペインもそれに付いていく。
        let flip = app.buttons["画面を入れ替え"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10), "画面を入れ替えのボタンがありません。")
        flip.tap()
        settle()

        aiButton.tap()
        XCTAssertTrue(waitForChat(), "AIトークがペインに入れ替わりません。")
        let close = app.buttons["AIトークを閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "入れ替わったペインの閉じるボタンがありません。")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(close.frame.midY, window.midY, "下のペインを操作中なら、上のペインに入れ替わるはずです。")
    }

    func testSwapRestoresTheOtherPaneContentUntouched() {
        splitWithFilesBrowser()
        let before = companionPane.identifier

        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10), "AIトークがペインに入れ替わりません。")
        XCTAssertFalse(companionPane.exists, "入れ替え中も元のペインが表示されています。")
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "元に戻りません。")

        XCTAssertTrue(companionPane.waitForExistence(timeout: 10), "戻したペインが表示されません。")
        XCTAssertEqual(companionPane.identifier, before, "戻したペインの内容が入れ替え前と違います。")
    }

    // MARK: 臨時画面との行き来

    private var floatingToPane: XCUIElement { app.buttons["note-ai-floating-to-pane"] }

    /// A context-menu item. The floating panel's header button carries the
    /// same label as "ペインに入れ替え", so it is left out by identifier.
    private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", label, "note-ai-floating-to-pane"
        )).firstMatch
    }

    private func longPressAIButton() {
        aiButton.press(forDuration: 1.2)
    }

    private func dismissMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        settle()
    }

    /// Opens the floating panel from the long-press menu (split, chat hidden).
    private func openFloatingFromMenu() {
        longPressAIButton()
        let item = menuItem("臨時画面で開く")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "長押しメニューに「臨時画面で開く」がありません。")
        item.tap()
        XCTAssertTrue(floatingToPane.waitForExistence(timeout: 10), "臨時画面が開きません。")
    }

    func testLongPressMenuOffersBothOnlyWhileTheChatIsHiddenInASplit() {
        splitWithFilesBrowser()
        longPressAIButton()
        XCTAssertTrue(menuItem("ペインに入れ替え").waitForExistence(timeout: 5), "分割中でAIが見えていないのに「ペインに入れ替え」がありません。")
        XCTAssertTrue(menuItem("臨時画面で開く").exists, "分割中でAIが見えていないのに「臨時画面で開く」がありません。")
        menuItem("ペインに入れ替え").tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10), "メニューからペインに入れ替わりません。")
        settle()

        // チャットが見えている間はメニューを出さない。
        longPressAIButton()
        XCTAssertFalse(menuItem("ペインに入れ替え").waitForExistence(timeout: 2), "AIが見えているのに「ペインに入れ替え」が出ています。")
        XCTAssertFalse(menuItem("臨時画面で開く").exists, "AIが見えているのに「臨時画面で開く」が出ています。")
    }

    func testLongPressMenuIsAbsentOnASingleScreen() {
        longPressAIButton()
        XCTAssertFalse(menuItem("ペインに入れ替え").waitForExistence(timeout: 2), "単画面で「ペインに入れ替え」が出ています。")
        XCTAssertFalse(menuItem("臨時画面で開く").exists, "単画面で「臨時画面で開く」が出ています。")
    }

    func testFloatingFromTheSwappedHeaderRestoresThePane() {
        splitWithFilesBrowser()
        let before = companionPane.identifier
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10))
        settle()

        let toFloating = app.buttons["臨時画面で開く"]
        XCTAssertTrue(toFloating.waitForExistence(timeout: 5), "入れ替え中のヘッダーに「臨時画面で開く」がありません。")
        toFloating.tap()

        XCTAssertTrue(floatingToPane.waitForExistence(timeout: 10), "フローティングに移りません。")
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "フローティングと入れ替えが同時に出ています。")
        XCTAssertTrue(companionPane.waitForExistence(timeout: 10), "元のペインが戻りません。")
        XCTAssertEqual(companionPane.identifier, before, "戻ったペインの内容が違います。")
    }

    func testFloatingHeaderSwapsIntoThePane() {
        splitWithFilesBrowser()
        openFloatingFromMenu()
        settle()

        floatingToPane.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10), "フローティングからペインに入りません。")
        XCTAssertTrue(floatingToPane.waitForNonExistence(timeout: 10), "入れ替えと同時にフローティングが残っています。")
    }

    func testFloatingPanelHasNoPaneButtonOnASingleScreen() {
        splitWithFilesBrowser()
        openFloatingFromMenu()
        settle()

        let menu = app.buttons["画面分割"]
        menu.tap()
        let single = app.buttons["1画面"]
        XCTAssertTrue(single.waitForExistence(timeout: 5), "1画面の項目がありません。")
        single.tap()
        settle()
        // 1画面に戻すと臨時画面も閉じる仕様。閉じていなければ、そこに「ペインに入れ替え」が残らないことを確かめる。
        XCTAssertFalse(floatingToPane.exists, "単画面の臨時画面に「ペインに入れ替え」が出ています。")
    }

    func testFloatingAndSwapNeverShowTogether() {
        splitWithFilesBrowser()
        openFloatingFromMenu()
        settle()
        XCTAssertFalse(swappedPane.exists, "臨時画面を開いたのに入れ替えも出ています。")

        // 臨時画面を出したまま、メニューからペインへ入れ替える。
        longPressAIButton()
        let toPane = menuItem("ペインに入れ替え")
        XCTAssertTrue(toPane.waitForExistence(timeout: 5), "臨時画面の表示中も入れ替えを選べるはずです。")
        toPane.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10), "ペインへ入れ替わりません。")
        XCTAssertTrue(floatingToPane.waitForNonExistence(timeout: 10), "入れ替えたのに臨時画面が残っています。")
        settle()

        // 入れ替え中にボタンで閉じ、開き直したあとも二重にならない。
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "ボタンで入れ替えが閉じません。")
        XCTAssertFalse(floatingToPane.exists, "入れ替えを閉じただけで臨時画面が出ています。")
        settle()
        openFloatingFromMenu()
        XCTAssertFalse(swappedPane.exists, "臨時画面を開き直したら入れ替えも出ています。")
        settle()

        // 臨時画面の表示中にボタンを押すと、臨時画面が閉じるだけ。
        aiButton.tap()
        XCTAssertTrue(floatingToPane.waitForNonExistence(timeout: 10), "ボタンで臨時画面が閉じません。")
        XCTAssertFalse(swappedPane.exists, "臨時画面を閉じたら入れ替えが出ています。")
    }

    // MARK: 他機能との干渉

    private var drawingBarControls: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "描画バー"))
    }

    private func chooseFromSplitMenu(_ title: String) {
        let menu = app.buttons["画面分割"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "画面分割のメニューがありません。")
        menu.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title)の項目がありません。")
        // メニューが開き切る前に押すと取りこぼす。
        Thread.sleep(forTimeInterval: 1)
        item.tap()
        settle()
    }

    func testSwappedHeaderCloseHandsThePaneBack() {
        splitWithFilesBrowser()
        let before = companionPane.identifier
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10))
        settle()

        let close = app.buttons["AIトークを閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "ヘッダーに閉じるボタンがありません。")
        close.tap()
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "閉じても入れ替えが残っています。")
        XCTAssertTrue(companionPane.waitForExistence(timeout: 10), "元のペインが戻りません。")
        XCTAssertEqual(companionPane.identifier, before)
    }

    func testCollapsingToOneScreenClearsTheSwap() {
        splitWithFilesBrowser()
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10))
        settle()

        chooseFromSplitMenu("1画面")
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "1画面にしても入れ替えが残っています。")
        XCTAssertTrue(waitForNoChat(), "1画面にしてもチャットが見えています。")

        // 開き直した分割に、前の入れ替えが残っていない。
        splitWithFilesBrowser()
        XCTAssertFalse(swappedPane.exists, "分割し直したら入れ替えが復活しました。")
        XCTAssertFalse(chatIsShown, "分割し直したらチャットが出ています。")
    }

    func testDrawingToolbarIsHiddenWhileTheChatCoversTheNote() {
        splitWithFilesBrowser()
        // ノートを操作中のまま反対側へ入れ替えると、ノートは隠れない。まず「画面を入れ替え」で
        // 操作中のペインとチャットが重なる並びにする。
        let flip = app.buttons["画面を入れ替え"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10))
        flip.tap()
        settle()
        XCTAssertTrue(drawingBarControls.firstMatch.waitForExistence(timeout: 5), "入れ替え前に描画バーが出ていません。")

        aiButton.tap()
        // 上のペインは識別子が上書きされるため、チャットは閉じるボタンで見分ける。
        XCTAssertTrue(app.buttons["AIトークを閉じる"].waitForExistence(timeout: 10), "AIトークが入れ替わりません。")
        settle()
        let noteCovered = !drawingBarControls.firstMatch.exists
        XCTAssertTrue(noteCovered, "チャットがノートを覆っている間、描画バーが残っています。")

        aiButton.tap()
        XCTAssertTrue(app.buttons["AIトークを閉じる"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(drawingBarControls.firstMatch.waitForExistence(timeout: 10), "チャットを閉じても描画バーが戻りません。")
    }

    func testOpeningPhotoStudyDropsTheSwap() {
        splitWithFilesBrowser()
        aiButton.tap()
        XCTAssertTrue(swappedPane.waitForExistence(timeout: 10))
        settle()

        chooseFromSplitMenu("写真アプリと2分割")
        let library = app.descendants(matching: .any)["photo-study-library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "写真アプリと2分割を選んでも、写真資料のペインが開きません。")
        XCTAssertTrue(swappedPane.waitForNonExistence(timeout: 10), "写真資料を開いても入れ替えが残っています。")
    }

    func testOpeningTheChatWhilePhotoStudyIsOpenDropsPhotoStudy() {
        chooseFromSplitMenu("写真アプリと2分割")
        let library = app.descendants(matching: .any)["photo-study-library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "写真アプリと2分割を選んでも、写真資料のペインが開きません。")

        aiButton.tap()
        XCTAssertTrue(waitForChat(), "写真資料の表示中にAIトークが開きません。")
        XCTAssertTrue(library.waitForNonExistence(timeout: 10), "AIトークを開いても写真資料が残っています。")
    }
}
