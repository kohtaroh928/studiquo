import XCTest

/// 問題の報告シート。カレンダーの右上のボタンからも開く(その他からの入口は
/// `HomeMoreRowsOpenTests` が見ている)。実際に送ると運営へ届いてしまうので、
/// 「送信」は押さない。ここでは送信できる条件と、閉じ方を見る。
final class ReportIssueUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--startup-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 20), "ホームが表示されません。")
        app.buttons["カレンダー"].tap()
        XCTAssertTrue(app.staticTexts["カレンダー"].waitForExistence(timeout: 10), "カレンダー画面が開きません。")
        let report = app.buttons["問題を報告"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), "カレンダーの右上に「問題を報告」ボタンがありません。")
        report.tap()
        XCTAssertTrue(app.navigationBars["問題を報告"].waitForExistence(timeout: 10), "報告のシートが開きません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private var send: XCUIElement { app.buttons["送信"] }
    private var editor: XCUIElement { app.textViews.firstMatch }

    func testTheSheetExplainsWhatToWrite() {
        XCTAssertTrue(app.staticTexts["何が起きましたか？"].exists, "入力欄の見出しがありません。")
        XCTAssertTrue(app.staticTexts["操作の手順や、いつから起きているかを書いていただけると助かります。"].exists, "書き方の案内がありません。")
    }

    func testSendStaysDisabledUntilSomethingIsWritten() {
        XCTAssertTrue(send.exists, "「送信」がありません。")
        XCTAssertFalse(send.isEnabled, "何も書いていないのに「送信」が押せます。")

        editor.tap()
        editor.typeText("   \n  ")
        XCTAssertFalse(send.isEnabled, "空白と改行だけで「送信」が押せます。")

        editor.typeText("保存ボタンが反応しません")
        XCTAssertTrue(send.isEnabled, "内容を書いても「送信」が押せません。")
    }

    func testSendBecomesDisabledAgainWhenTheTextIsErased() {
        editor.tap()
        editor.typeText("a")
        XCTAssertTrue(send.isEnabled)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(send.isEnabled, "書いた内容を消しても「送信」が押せます。")
    }

    func testCancelClosesTheSheetAndNothingIsSent() {
        editor.tap()
        editor.typeText("書きかけ")
        app.buttons["キャンセル"].tap()
        XCTAssertFalse(app.navigationBars["問題を報告"].waitForExistence(timeout: 2), "キャンセルしてもシートが閉じません。")
        XCTAssertFalse(app.alerts["送信しました"].exists, "キャンセルしたのに送信されています。")
        XCTAssertTrue(app.staticTexts["カレンダー"].exists, "シートを閉じたあと、元の画面に戻っていません。")
    }

    func testReopeningStartsWithAnEmptyForm() {
        editor.tap()
        editor.typeText("前回の下書き")
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.buttons["問題を報告"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["問題を報告"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["問題を報告"].waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "開き直したのに前回の下書きが残っています。")
    }
}
