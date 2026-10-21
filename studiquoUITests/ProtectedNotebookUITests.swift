import XCTest

/// 「ノートを保護」したノートは、本人確認が済むまで中身を見せない。
/// 確認の結果(成功・失敗)は端末の設定次第で、シミュレータでは認証の画面が出たまま終わらず、
/// アプリの画面は操作できない状態になる。そのため、ここでは「開こうとするとロックの案内が出る」
/// ことと、保護していないノートには出ないことだけを見る。
final class ProtectedNotebookUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--home-pdf-cover"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func entry(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)["library-entry-\(title)"].firstMatch
    }

    private func openLockedNotebook() {
        let locked = entry("保護されたPDF")
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "保護されたノートがライブラリにありません。")
        locked.tap()
        XCTAssertTrue(app.staticTexts["ロックされたノート"].waitForExistence(timeout: 20), "保護されたノートを開いてもロックの案内が出ません。")
    }

    func testAProtectedNotebookShowsTheLockNoticeInsteadOfItsPages() {
        openLockedNotebook()
        XCTAssertTrue(app.buttons["ロックを解除"].exists, "「ロックを解除」ボタンがありません。")
        XCTAssertTrue(app.images["lock.fill"].exists || app.staticTexts["ロックされたノート"].exists)
        XCTAssertFalse(app.staticTexts["パスワードが必要です"].exists, "生体認証が先のはずが、PDFのパスワードの案内が出ています。")
    }

    func testTheLockNoticeSaysWhatToDoNext() {
        openLockedNotebook()
        // 認証の途中は初期の案内、失敗したあとは失敗の案内になる。どちらかが出ていればよい。
        let known = ["認証してノートを開いてください", "認証できませんでした。もう一度お試しください"]
        let message = app.staticTexts.matching(NSPredicate(format: "label IN %@", known)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "ロックの案内に、次にすることが書かれていません。")
    }

    func testAnUnprotectedNotebookOpensWithoutAnyLockNotice() {
        let open = entry("表紙つきPDF")
        XCTAssertTrue(open.waitForExistence(timeout: 20), "保護されていないPDFがライブラリにありません。")
        open.tap()
        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 10), "保護されていないノートが開きません。")
        XCTAssertFalse(app.staticTexts["ロックされたノート"].exists, "保護していないノートにロックの案内が出ています。")
        XCTAssertFalse(app.buttons["ロックを解除"].exists)
    }
}
