import XCTest

/// The home screen's その他 tab gathers every setting in one list. These
/// guard that the tab exists, that each area is reachable from it, and that
/// the rows which hand off to another screen (calendar connection, trash)
/// actually arrive there.
final class HomeMoreTabTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
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

    /// The settings list is long enough that lower rows are not built until
    /// scrolled into view.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        for _ in 0..<10 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "スクロールしても見つかりません: \(element)", file: file, line: line)
        return element
    }

    func testMoreTabIsTheLastTab() {
        let tabs = ["home-tab-notes", "home-tab-calendar", "home-tab-friends", "home-tab-ai", "home-tab-more"]
        let xs = tabs.map { app.buttons[$0].frame.minX }
        XCTAssertEqual(xs, xs.sorted(), "「その他」は「AI」の右隣(一番右)に並ぶ必要があります。")
    }

    func testEverySettingsAreaIsReachableFromMore() {
        openMore()
        let labels = [
            "ログアウト",
            "プランとお支払い",
            "勉強時間を記録する",
            "通知",
            "左利きモード",
            "翌日復習を作成する",
            "エラー情報を自動送信",
            "プライバシーポリシーを見る",
            "カレンダー連携(Google・大学)",
            "MCPクラウド連携(Claude・ChatGPT)",
            "ゴミ箱",
            "バックアップを復元",
            "自動バックアップを復元",
            "MCP連携データを書き出す",
            "MCPの変更を読み込む",
            "フレンド設定",
            "問題を報告",
            "バージョン",
        ]
        for label in labels {
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            scrollTo(element)
        }
    }

    func testCalendarConnectionRowOpensTheCalendarConnectionSheet() {
        openMore()
        scrollTo(app.buttons["カレンダー連携(Google・大学)"]).tap()
        XCTAssertTrue(
            app.navigationBars["カレンダー連携"].waitForExistence(timeout: 10),
            "その他からカレンダー連携を押すと、カレンダー画面の連携設定が開く必要があります。"
        )
    }

    func testTrashRowLeavesTheMoreTab() {
        openMore()
        scrollTo(app.buttons["ゴミ箱"]).tap()
        XCTAssertFalse(app.navigationBars["その他"].waitForExistence(timeout: 3), "ゴミ箱を押したらノート画面(ゴミ箱)へ移動する必要があります。")
    }

    /// The row has to land on the trash itself, not just anywhere outside その他.
    func testTrashRowShowsTheTrash() {
        openMore()
        scrollTo(app.buttons["ゴミ箱"]).tap()
        XCTAssertTrue(
            app.navigationBars["ゴミ箱"].waitForExistence(timeout: 10),
            "ゴミ箱を押したら、ゴミ箱の表示(タイトル「ゴミ箱」)になる必要があります。"
        )
        // The title is the library mode's own ("ホーム" while on the home
        // screen), so "ゴミ箱" with no "ホーム" means the trash mode is active.
        XCTAssertFalse(app.navigationBars["ホーム"].exists, "ゴミ箱ではなく通常のホーム表示になっています。")
    }

    /// Whatever was open before visiting その他 (here a folder) must not
    /// carry over: the trash row starts from a clean home state.
    func testTrashRowDoesNotKeepThePreviouslyOpenFolder() {
        let folder = app.buttons["library-folder-Target"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15), "フォルダ「Target」が見つかりません。")
        folder.tap()
        XCTAssertTrue(app.navigationBars["Target"].waitForExistence(timeout: 10), "フォルダを開けません。")

        openMore()
        scrollTo(app.buttons["ゴミ箱"]).tap()
        XCTAssertTrue(app.navigationBars["ゴミ箱"].waitForExistence(timeout: 10), "ゴミ箱の表示になりません。")
        XCTAssertFalse(
            app.navigationBars["Target"].exists,
            "直前に開いていたフォルダが残ったままになっています。ホームに戻った状態からゴミ箱を開く必要があります。"
        )
    }

    /// The "open once" flag is consumed when the sheet opens, so closing it
    /// and coming back to the calendar later must not reopen it.
    func testCalendarConnectionSheetDoesNotReopenAfterBeingClosed() {
        openMore()
        scrollTo(app.buttons["カレンダー連携(Google・大学)"]).tap()
        let sheetBar = app.navigationBars["カレンダー連携"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 10), "連携設定が開きません。")

        sheetBar.buttons["完了"].tap()
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10), "完了を押しても連携設定が閉じません。")

        app.buttons["home-tab-notes"].tap()
        app.buttons["home-tab-calendar"].tap()
        XCTAssertFalse(
            sheetBar.waitForExistence(timeout: 3),
            "連携設定を閉じて別のタブから戻っただけで、設定画面が再度開いてはいけません。"
        )
    }

    /// Having visited the calendar tab beforehand must not stop the row from
    /// opening the connection sheet.
    func testCalendarConnectionRowOpensSheetAfterCalendarTabWasAlreadyVisited() {
        app.buttons["home-tab-calendar"].tap()
        XCTAssertFalse(app.navigationBars["カレンダー連携"].waitForExistence(timeout: 2), "カレンダータブを開いただけで連携設定が開いています。")

        openMore()
        scrollTo(app.buttons["カレンダー連携(Google・大学)"]).tap()
        XCTAssertTrue(
            app.navigationBars["カレンダー連携"].waitForExistence(timeout: 10),
            "カレンダータブを一度開いた後でも、その他から連携設定を開ける必要があります。"
        )
    }
}
