import XCTest

/// Creating an item from the home screen must leave the student on the folder
/// that holds it, not open the item. (From inside an open editor the "タブを
/// 追加" picker still opens the new item as a tab — see TabPickerCreateTests.)
final class CreatedItemRevealTests: XCTestCase {
    func testCreatingADocumentFromHomeShowsItInTheListWithoutOpeningIt() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--tab-picker-create-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["library-entry-既存のノート"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.buttons["home-create-menu"].waitForExistence(timeout: 5))
        app.buttons["home-create-menu"].tap()
        XCTAssertTrue(app.buttons["新規文書"].waitForExistence(timeout: 5))
        app.buttons["新規文書"].tap()

        let alert = app.alerts["新規文書"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields["文書名"].tap()
        alert.textFields["文書名"].typeText("ホームで作った文書")
        alert.buttons["作成"].tap()

        XCTAssertTrue(
            app.buttons["library-entry-ホームで作った文書"].waitForExistence(timeout: 5),
            "作成した文書がホームの一覧に表示される必要があります。"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["tab-document-ホームで作った文書"].exists,
            "ホームで作成した文書を開いてはいけません。"
        )
    }

    func testCreatingANotebookInsideFolderStaysInsideFolderWithoutOpeningIt() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--tab-picker-create-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["library-entry-既存のノート"].waitForExistence(timeout: 10))

        // 1. 新規フォルダ作成
        XCTAssertTrue(app.buttons["home-create-menu"].waitForExistence(timeout: 5))
        app.buttons["home-create-menu"].tap()
        XCTAssertTrue(app.buttons["新規フォルダ"].waitForExistence(timeout: 5))
        app.buttons["新規フォルダ"].tap()

        let folderAlert = app.alerts["新規フォルダ"]
        XCTAssertTrue(folderAlert.waitForExistence(timeout: 5))
        folderAlert.textFields["フォルダ名"].tap()
        folderAlert.textFields["フォルダ名"].typeText("理科フォルダ")
        folderAlert.buttons["作成"].tap()

        // 2. フォルダ内に遷移していることを確認
        XCTAssertTrue(app.navigationBars["理科フォルダ"].waitForExistence(timeout: 5))

        // 3. フォルダ内で新規ノート作成
        XCTAssertTrue(app.buttons["home-create-menu"].waitForExistence(timeout: 5))
        app.buttons["home-create-menu"].tap()
        XCTAssertTrue(app.buttons["新規ノート"].waitForExistence(timeout: 5))
        app.buttons["新規ノート"].tap()

        let sheet = app.navigationBars["新規ノート"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let nameField = app.textFields["名称未設定のノート"]
        if nameField.waitForExistence(timeout: 3) {
            nameField.tap()
            nameField.typeText("化学ノート")
        }
        app.buttons["作成"].tap()

        // 4. ノートが開かれず、理科フォルダ内に留まっていることを確認
        XCTAssertTrue(
            app.navigationBars["理科フォルダ"].waitForExistence(timeout: 5),
            "新規ノート作成後もフォルダ内に留まる必要があります。"
        )
        XCTAssertTrue(
            app.buttons["library-entry-化学ノート"].waitForExistence(timeout: 5),
            "フォルダ一覧内に作成されたノートが表示される必要があります。"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["tab-notebook-化学ノート"].exists,
            "作成されたノートをエディタで開いてはいけません。"
        )
    }
}
