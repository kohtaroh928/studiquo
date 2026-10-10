import XCTest

/// Coverage for the "+" buttons added to each section header of the "タブを
/// 追加" (add tab) picker — tapping one now creates a brand-new item of that
/// section's kind (reusing the same name-entry alert/sheet the home screen's
/// own create flow already uses) and opens it as a tab, instead of the
/// picker only ever letting you pick from what already exists.
///
/// The real risk in this feature isn't the creation itself (that logic was
/// already exercised elsewhere) — it's the new dispatch added to route "which
/// + was tapped" to "which alert/sheet appears", via `pendingTabPickerCreation`
/// read back in the tab picker sheet's own `onDismiss`. A regression there
/// would most likely show up as the wrong alert appearing, or none at all.
final class TabPickerCreateTests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--tab-picker-create-ui-test"]
        app.launch()
        return app
    }

    /// Opens the fixture's one seeded notebook (so the tab bar — and its own
    /// "+" — becomes visible; see `notebookTabBar` in ContentView.swift),
    /// then taps that "+" to bring up the "タブを追加" picker itself.
    private func openTabPicker(_ app: XCUIApplication) {
        let notebookEntry = app.buttons["library-entry-既存のノート"]
        XCTAssertTrue(notebookEntry.waitForExistence(timeout: 10), "フィクスチャのノートが見つかりません。")
        notebookEntry.tap()

        let addTabButton = app.buttons["tab-picker-add-tab"]
        XCTAssertTrue(addTabButton.waitForExistence(timeout: 10), "ノートを開いてもタブバーの＋が出てきません。")
        addTabButton.tap()
    }

    /// 画面右上の「新規作成」メニューから、種類ごとの項目を選ぶ。
    private func chooseCreate(_ app: XCUIApplication, _ entry: String) {
        app.buttons["新規作成"].firstMatch.tap()
        XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 5), "\(entry)がメニューにありません。")
        app.buttons[entry].tap()
    }

    func testCreatingADocumentFromTheTabPickerShowsTheDocumentAlertAndOpensANewTab() {
        let app = launchApp()
        openTabPicker(app)

        chooseCreate(app, "新規文書")

        let alert = app.alerts["新規文書"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "「新規作成」の「新規文書」を押したら「新規文書」のアラートが出る必要があります。")
        alert.textFields["文書名"].tap()
        alert.textFields["文書名"].typeText("回帰テスト用の文書")
        alert.buttons["作成"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["tab-document-回帰テスト用の文書"].waitForExistence(timeout: 5),
            "作成した文書が新しいタブとして開く必要があります。"
        )
    }

    func testCreatingAFlashcardDeckFromTheTabPickerShowsTheFlashcardAlert() {
        let app = launchApp()
        openTabPicker(app)

        chooseCreate(app, "新規暗記カード")

        XCTAssertTrue(
            app.alerts["新規暗記帳"].waitForExistence(timeout: 5),
            "「新規作成」の「新規暗記カード」を押したら「新規暗記帳」のアラートが出る必要があります。"
        )
    }

    func testCreatingANotebookFromTheTabPickerShowsTheNotebookSheet() {
        let app = launchApp()
        openTabPicker(app)

        chooseCreate(app, "新規ノート")

        XCTAssertTrue(
            app.navigationBars["新規ノート"].waitForExistence(timeout: 5),
            "「新規作成」の「新規ノート」を押したら「新規ノート」のシートが出る必要があります。"
        )
    }

    // Regression coverage for the pending-kind dispatch itself: tapping one
    // section's "+" must never show a different section's alert — that
    // would mean `pendingTabPickerCreation` was set to the wrong kind, or
    // read back after being overwritten by a second tap.
    func testTappingASectionsCreateButtonNeverShowsAMismatchedAlert() {
        let app = launchApp()
        openTabPicker(app)

        chooseCreate(app, "新規文書")
        XCTAssertTrue(app.alerts["新規文書"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["新規暗記帳"].exists)
        app.alerts["新規文書"].buttons["キャンセル"].tap()
    }
}
