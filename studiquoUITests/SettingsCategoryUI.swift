import XCTest

/// The settings list shows category buttons first (`settings-category-<id>`);
/// each opens a form with that category's rows. Shared by every UI test that
/// has to reach a setting, from the その他 tab or the gear's sheet.
enum SettingsCategoryUI {
    static let titles = [
        "account": "アカウント",
        "study": "学習・ノート",
        "notifications": "通知・お知らせ",
        "data": "データ・連携",
        "privacy": "フレンド・プライバシー",
        "app": "言語・サポート",
    ]
}

extension XCUIApplication {
    /// Taps the category button on the settings list and waits for its form.
    func openSettingsCategory(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = descendants(matching: .any)["settings-category-\(id)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "設定の分類「\(id)」がありません。", file: file, line: line)
        button.tap()
        XCTAssertTrue(
            navigationBars[SettingsCategoryUI.titles[id] ?? id].waitForExistence(timeout: 10),
            "設定の分類「\(id)」が開きません。", file: file, line: line
        )
    }

    /// Goes back from a category's form to the settings list.
    func leaveSettingsCategory(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = navigationBars[SettingsCategoryUI.titles[id] ?? id]
        XCTAssertTrue(bar.exists, "設定の分類「\(id)」が開いていません。", file: file, line: line)
        bar.buttons.firstMatch.tap()
        XCTAssertTrue(
            bar.waitForNonExistence(timeout: 10),
            "設定の分類「\(id)」から戻れません。", file: file, line: line
        )
    }
}
