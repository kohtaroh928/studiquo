import XCTest

/// 分割画面の資料選択で、並べ方(リスト・アイコン・カラム)の切り替え、フォルダ階層のカラム、
/// 新規作成、キャンセルが働くことの確認。
final class SplitSourcePickerLayoutTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--split-source-picker-ui-test"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["split-source-layout-list"].waitForExistence(timeout: 15))
        return app
    }

    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["split-source-item-\(title)"].firstMatch
    }

    private func folder(_ app: XCUIApplication, _ path: String) -> XCUIElement {
        app.buttons["split-source-folder-\(path)"].firstMatch
    }

    private func selected(_ app: XCUIApplication) -> String {
        app.staticTexts["split-source-selected"].label
    }

    // MARK: 並べ方

    func testStartsAsListAndShowsEveryKind() {
        let app = launch()
        XCTAssertTrue(app.buttons["split-source-layout-list"].isSelected)
        for title in ["分割ノート", "分割PDF", "分割暗記"] {
            XCTAssertTrue(item(app, title).exists, title)
        }
        XCTAssertTrue(app.staticTexts["表示中"].exists)
    }

    func testEachLayoutButtonRearrangesTheMaterials() {
        let app = launch()

        app.buttons["split-source-layout-icon"].tap()
        XCTAssertTrue(app.buttons["split-source-layout-icon"].isSelected)
        XCTAssertTrue(app.scrollViews["split-source-icons"].waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "分割PDF").exists)

        app.buttons["split-source-layout-column"].tap()
        XCTAssertTrue(app.buttons["split-source-layout-column"].isSelected)
        XCTAssertTrue(app.scrollViews["split-source-columns"].waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "分割ノート").exists)

        app.buttons["split-source-layout-list"].tap()
        XCTAssertTrue(app.buttons["split-source-layout-list"].isSelected)
        XCTAssertTrue(item(app, "分割暗記").exists)
    }

    func testSelectingAMaterialWorksInEveryLayout() {
        let app = launch()
        let cases: [(layout: String, title: String)] = [
            ("list", "分割ノート"), ("icon", "分割PDF"), ("column", "分割ノート"),
        ]
        for (layout, title) in cases {
            app.buttons["split-source-layout-\(layout)"].tap()
            XCTAssertTrue(item(app, title).waitForExistence(timeout: 5), "\(title) in \(layout)")
            item(app, title).tap()
            XCTAssertEqual(selected(app), title, layout)
        }
    }

    // MARK: カラム(フォルダ階層)

    func testColumnsFollowTheFolderHierarchy() {
        let app = launch()
        app.buttons["split-source-layout-column"].tap()

        // 最上位の列には、最上位のノートとフォルダだけがある。
        XCTAssertTrue(item(app, "分割ノート").waitForExistence(timeout: 5))
        XCTAssertTrue(folder(app, "科目").exists)
        XCTAssertFalse(item(app, "分割PDF").exists)
        XCTAssertFalse(item(app, "分割暗記").exists)

        folder(app, "科目").tap()
        XCTAssertTrue(item(app, "分割PDF").waitForExistence(timeout: 5))
        XCTAssertTrue(folder(app, "科目/数学").exists)
        XCTAssertFalse(item(app, "分割暗記").exists)

        folder(app, "科目/数学").tap()
        XCTAssertTrue(item(app, "分割暗記").waitForExistence(timeout: 5))

        item(app, "分割暗記").tap()
        XCTAssertEqual(selected(app), "分割暗記")
    }

    func testColumnsScrollSidewaysWhenTheyDoNotFit() {
        let app = launch(["--split-source-picker-narrow"])
        app.buttons["split-source-layout-column"].tap()
        let columns = app.scrollViews["split-source-columns"]
        XCTAssertTrue(columns.waitForExistence(timeout: 5))

        folder(app, "科目").tap()
        folder(app, "科目/数学").tap()

        // 3列(900pt)は600ptの画面に収まらず、最新の列まで自動でスクロールする。
        let deck = item(app, "分割暗記")
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        XCTAssertTrue(deck.isHittable)
        XCTAssertFalse(item(app, "分割ノート").isHittable, "the first column should have scrolled out of view")

        columns.swipeRight()
        XCTAssertTrue(item(app, "分割ノート").isHittable, "swiping back should reveal the first column")
    }

    // MARK: 新規作成とキャンセル

    private func waitUntilClosed(_ app: XCUIApplication) {
        let state = app.staticTexts["split-source-sheet-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", "closed"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
    }

    private func openCreateMenu(_ app: XCUIApplication, _ entry: String) {
        app.buttons["新規作成"].firstMatch.tap()
        XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 5))
        app.buttons[entry].tap()
    }

    func testCreatingANotebookWithAName() {
        let app = launch(["--split-source-picker-sheet"])
        openCreateMenu(app, "新規ノート")
        let field = app.textFields["ノート名"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("新規テストノート")
        app.buttons["作成して開く"].tap()

        XCTAssertEqual(selected(app), "新規テストノート")
        waitUntilClosed(app)
    }

    func testCreatingANotebookWithoutANameUsesTheDefaultName() {
        let app = launch(["--split-source-picker-sheet"])
        openCreateMenu(app, "新規ノート")
        XCTAssertTrue(app.textFields["ノート名"].waitForExistence(timeout: 5))
        app.buttons["作成して開く"].tap()
        XCTAssertEqual(selected(app), "新しいノート")
    }

    func testCreatingAFlashcardDeck() {
        let app = launch(["--split-source-picker-sheet"])
        openCreateMenu(app, "新規暗記カード")
        let field = app.textFields["暗記カード名"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("新規テストカード")
        app.buttons["作成して開く"].tap()
        XCTAssertEqual(selected(app), "新規テストカード")
    }

    func testCancellingTheCreationAlertCreatesNothingAndKeepsThePickerOpen() {
        let app = launch(["--split-source-picker-sheet"])
        openCreateMenu(app, "新規ノート")
        XCTAssertTrue(app.textFields["ノート名"].waitForExistence(timeout: 5))
        app.alerts.buttons["キャンセル"].tap()

        XCTAssertFalse(app.textFields["ノート名"].waitForExistence(timeout: 2))
        XCTAssertEqual(selected(app), "なし")
        XCTAssertTrue(app.buttons["split-source-layout-list"].exists, "the picker should still be open")
        XCTAssertEqual(app.staticTexts["split-source-sheet-state"].label, "open")
    }

    func testCancelButtonClosesThePickerWithoutSelecting() {
        let app = launch(["--split-source-picker-sheet"])
        app.buttons["キャンセル"].firstMatch.tap()

        waitUntilClosed(app)
        XCTAssertEqual(selected(app), "なし")
        XCTAssertFalse(app.buttons["split-source-layout-list"].exists)
    }
}
