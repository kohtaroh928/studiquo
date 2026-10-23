import XCTest

/// その他 tab: logout confirmation, and the hand-off to the calendar
/// connection sheet (a one-shot request that must be consumed).
final class HomeMoreLogoutAndCalendarTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "--ui-test-login-gate"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-more"].waitForExistence(timeout: 20), "ホーム下部に「その他」タブがありません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func openMore() {
        app.buttons["home-tab-more"].tap()
        XCTAssertTrue(app.navigationBars["その他"].waitForExistence(timeout: 10), "「その他」画面が開きません。")
    }

    /// 設定は6分類のボタンに分かれているので、目的の行がある分類まで開く。
    private func openMore(category: String) {
        openMore()
        app.openSettingsCategory(category)
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        for _ in 0..<10 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "スクロールしても見つかりません: \(element)", file: file, line: line)
        return element
    }

    private var connectionBar: XCUIElement { app.navigationBars["カレンダー連携"] }

    private func openConnectionFromMore() {
        openMore(category: "data")
        scrollTo(app.buttons["カレンダー連携(Google・大学)"]).tap()
        XCTAssertTrue(connectionBar.waitForExistence(timeout: 10), "カレンダー連携の設定が開きません。")
    }

    // MARK: ログアウト

    /// 5. 「ログアウト」→確認→キャンセルならログイン状態のまま
    func testCancellingLogoutKeepsTheUserSignedIn() {
        openMore(category: "account")
        scrollTo(app.buttons["more-logout"]).tap()

        let confirmTitle = app.staticTexts["ログアウトしますか？"]
        XCTAssertTrue(confirmTitle.waitForExistence(timeout: 5), "ログアウトの確認が出ません。")
        // On iPad the dialog is a popover with no cancel button; tapping
        // outside it is the cancel.
        if app.buttons["キャンセル"].exists {
            app.buttons["キャンセル"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.97)).tap()
        }
        XCTAssertFalse(confirmTitle.waitForExistence(timeout: 3), "キャンセルしても確認が閉じません。")

        XCTAssertFalse(app.staticTexts["おかえりなさい"].waitForExistence(timeout: 2), "キャンセルしたのにログイン画面になりました。")
        XCTAssertTrue(app.navigationBars["アカウント"].exists, "キャンセル後も「アカウント」画面に留まる必要があります。")
        // 分類を開いている間はタブバーが隠れるので、一覧に戻ってから確かめる。
        app.leaveSettingsCategory("account")
        XCTAssertTrue(app.buttons["home-tab-more"].exists, "キャンセル後もホームのタブが残る必要があります。")
    }

    /// 6. 確認で「ログアウト」→ログイン画面に戻る
    func testConfirmingLogoutReturnsToTheLoginScreen() {
        openMore(category: "account")
        scrollTo(app.buttons["more-logout"]).tap()
        XCTAssertTrue(app.staticTexts["ログアウトしますか？"].waitForExistence(timeout: 5), "ログアウトの確認が出ません。")

        // The destructive button in the dialog shares its label with the row.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "ログアウト")).allElementsBoundByIndex
            .last(where: { $0.isHittable && $0.identifier != "more-logout" })
        XCTAssertNotNil(confirm, "確認ダイアログに「ログアウト」ボタンがありません。")
        confirm?.tap()

        XCTAssertTrue(app.staticTexts["おかえりなさい"].waitForExistence(timeout: 10), "ログアウト後にログイン画面へ戻りません。")
        XCTAssertTrue(app.buttons["ログイン"].exists, "ログイン画面に「ログイン」ボタンがありません。")
        XCTAssertFalse(app.buttons["home-tab-more"].exists, "ログアウト後もホームが残っています。")
    }

    /// iPad縦向きのログイン画面で、Appleのサインインボタンが縦に伸びない(高さに上限がなく、余白を使い切っていた不具合の回帰)
    func testLoginScreenAppleButtonKeepsAButtonHeightInPortrait() {
        openMore(category: "account")
        scrollTo(app.buttons["more-logout"]).tap()
        XCTAssertTrue(app.staticTexts["ログアウトしますか？"].waitForExistence(timeout: 5), "ログアウトの確認が出ません。")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "ログアウト")).allElementsBoundByIndex
            .last(where: { $0.isHittable && $0.identifier != "more-logout" })
        XCTAssertNotNil(confirm, "確認ダイアログに「ログアウト」ボタンがありません。")
        confirm?.tap()
        XCTAssertTrue(app.staticTexts["おかえりなさい"].waitForExistence(timeout: 10), "ログアウト後にログイン画面へ戻りません。")

        let apple = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apple")).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 5), "ログイン画面にAppleのサインインボタンがありません。")
        XCTAssertGreaterThanOrEqual(apple.frame.height, 40, "Appleのボタンが潰れています(\(apple.frame.height)pt)。")
        XCTAssertLessThanOrEqual(apple.frame.height, 60, "Appleのボタンが縦に伸びています(\(apple.frame.height)pt)。")
    }

    // MARK: カレンダー連携の引き継ぎ

    /// 7. 連携設定を閉じて別タブへ→カレンダーに戻っても、設定が勝手に再度開かない
    func testClosingCalendarConnectionDoesNotReopenItWhenReturningToCalendar() {
        openConnectionFromMore()
        connectionBar.buttons["完了"].tap()
        XCTAssertFalse(connectionBar.waitForExistence(timeout: 3), "「完了」で連携設定が閉じません。")

        // 分類を開いている間はタブバーが隠れるので、「その他」の一覧まで戻る。
        app.leaveSettingsCategory("data")
        app.buttons["home-tab-notes"].tap()
        app.buttons["home-tab-calendar"].tap()
        XCTAssertTrue(app.navigationBars["カレンダー"].waitForExistence(timeout: 10), "カレンダー画面に戻れません。")
        XCTAssertFalse(connectionBar.waitForExistence(timeout: 3), "カレンダーに戻ると連携設定が勝手に再度開きました(一度だけ使うフラグが消費されていません)。")
    }

    /// 8. すでにカレンダータブを開いた後でも、その他から連携設定が開ける
    func testCalendarConnectionOpensFromMoreAfterCalendarTabWasAlreadyVisited() {
        app.buttons["home-tab-calendar"].tap()
        XCTAssertTrue(app.navigationBars["カレンダー"].waitForExistence(timeout: 10), "カレンダー画面が開きません。")
        XCTAssertFalse(connectionBar.exists, "カレンダーを開いただけで連携設定が開いています。")

        openConnectionFromMore()
        XCTAssertTrue(connectionBar.exists)
    }
}
