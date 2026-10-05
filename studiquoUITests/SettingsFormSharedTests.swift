import XCTest

/// The gear's settings sheet and the その他 tab are the same form
/// (`AppSettingsForm`), so what is changed in one must show in the other.
/// These guard that refactor: nothing dropped from the sheet, the saved
/// values are shared both ways, language changes apply immediately, and
/// account deletion stays a single, last row.
final class SettingsFormSharedTests: XCTestCase {
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

    // MARK: Helpers

    private func openMore() {
        app.buttons["home-tab-more"].tap()
        XCTAssertTrue(app.navigationBars["その他"].waitForExistence(timeout: 10), "「その他」画面が開きません。")
    }

    private func openGear() {
        app.buttons["home-tab-notes"].tap()
        // In portrait the toolbar has no room for the gear and folds it into
        // the "さらに表示" overflow menu; wider layouts show it directly.
        let overflow = app.buttons["OverflowBarButtonItem"]
        let gear = app.buttons["設定"]
        let deadline = Date().addingTimeInterval(10)
        while !overflow.exists && !(gear.exists && gear.isHittable) && Date() < deadline {
            _ = overflow.waitForExistence(timeout: 0.5)
        }
        XCTAssertTrue(overflow.exists || gear.exists, "ノート画面のツールバーが表示されません。")
        if !(gear.exists && gear.isHittable) && overflow.exists { overflow.tap() }
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "ノート画面に設定(歯車)ボタンがありません。")
        gear.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10), "設定シートが開きません。")
    }

    private func closeGear() {
        app.navigationBars["設定"].buttons["完了"].tap()
        XCTAssertFalse(app.navigationBars["設定"].waitForExistence(timeout: 3), "「完了」で設定シートが閉じません。")
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Brings a row into view. Rows are built lazily — a row exists only while
    /// it is on screen — so the list must be scrolled in steps smaller than
    /// what is visible. `app.swipeUp()` is not: its distance follows the whole
    /// window, about 700pt however small the gear sheet is, so it steps clean
    /// over the rows in between, and whether the search succeeds depends on
    /// where the list happens to come to rest. Swiping the list itself moves
    /// it by a fraction of its own height.
    private func reveal(_ row: XCUIElement) {
        guard !isReachable(row) else { return }
        for _ in 0..<14 {
            scroll(up: true)
            if isReachable(row) { return }
        }
        for _ in 0..<28 {
            scroll(up: false)
            if isReachable(row) { return }
        }
    }

    /// The list being scrolled: the smallest one on screen (the gear sheet's
    /// list is smaller than the home list behind it).
    private func scrollableList() -> XCUIElement? {
        let lists = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex)
            .filter { $0.exists && $0.frame.height > 200 }
        return lists.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Swipes the list; if it cannot be found for a moment (the form is
    /// rebuilding), falls back to the whole window rather than doing nothing.
    private func scroll(up: Bool) {
        let target: XCUIElement = scrollableList() ?? app
        if up { target.swipeUp(velocity: .slow) } else { target.swipeDown(velocity: .slow) }
    }

    /// On screen, hittable, and not under the translucent navigation bar — a
    /// row there is reported hittable, but a tap lands on the bar and never
    /// reaches the row.
    private func isReachable(_ row: XCUIElement) -> Bool {
        let barBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
        return row.exists && row.isHittable && row.frame.minY >= barBottom + 4
    }

    /// Settings rows are built lazily, so a lower one has to be scrolled to.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        reveal(element)
        XCTAssertTrue(element.exists, "スクロールしても見つかりません: \(element)", file: file, line: line)
        return element
    }

    // MARK: 1. The gear sheet still shows what it always did

    func testGearSheetStillListsTheSameSettingsAndClosesWithDone() {
        openGear()
        let labels = [
            "プランとお支払い",
            "勉強時間を記録する",
            "通知",
            "左利きモード",
            "翌日復習を作成する",
            "エラー情報を自動送信",
            "AI機能とデータ送信について",
            "プライバシーポリシーを見る",
            "利用規約を見る",
            "アカウントを削除",
        ]
        for label in labels {
            let row = element(label)
            reveal(row)
            XCTAssertTrue(row.exists, "歯車のシートに「\(label)」がありません。")
        }
        closeGear()
    }

    // MARK: 2. Settings changed in one place show in the other (both ways)

    private func toggle(_ label: String) -> XCUIElement {
        app.switches[label]
    }

    private func flip(_ label: String) {
        let sw = scrollTo(toggle(label))
        sw.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    private func value(_ label: String) -> String {
        let sw = scrollTo(toggle(label))
        return "\(sw.value ?? "")"
    }

    /// Flips `label` in その他, expects the gear sheet to show the same, flips it
    /// back in the gear sheet, and expects その他 to show the restored value.
    private func assertToggleIsSharedBothWays(_ label: String) {
        openMore()
        let original = value(label)
        flip(label)
        let changed = value(label)
        XCTAssertNotEqual(changed, original, "「\(label)」が「その他」で切り替わりません。")

        openGear()
        XCTAssertEqual(value(label), changed, "「その他」で切り替えた「\(label)」が歯車のシートに反映されていません。")
        flip(label)
        XCTAssertEqual(value(label), original, "歯車のシートで「\(label)」を戻せません。")
        closeGear()

        openMore()
        XCTAssertEqual(value(label), original, "歯車のシートで切り替えた「\(label)」が「その他」に反映されていません。")
    }

    func testStudyTimeTrackingIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("勉強時間を記録する")
    }

    func testLeftHandedModeIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("左利きモード")
    }

    func testDayAfterReviewIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("翌日復習を作成する")
    }

    func testAutomaticErrorReportingIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("エラー情報を自動送信")
    }

    // MARK: 3. Language applies immediately

    func testSwitchingLanguageToEnglishChangesTheScreenAtOnce() {
        openMore()
        scrollTo(element("English")).tap()
        XCTAssertTrue(
            app.navigationBars["More"].waitForExistence(timeout: 10),
            "言語を英語にしたら「その他」の画面タイトルがすぐ「More」になる必要があります。"
        )
        XCTAssertEqual(app.buttons["home-tab-more"].label, "More", "タブ名が「More」になっていません。")
    }

    // MARK: 4. Account deletion is a single row, at the very end

    private func scrollToBottom() {
        for _ in 0..<12 { app.swipeUp() }
    }

    func testAccountDeletionIsASingleLastRowInMore() {
        openMore()
        scrollToBottom()
        let deletes = app.buttons.matching(NSPredicate(format: "label == %@", "アカウントを削除"))
        XCTAssertEqual(deletes.count, 1, "「アカウントを削除」は1つだけである必要があります。")
        let version = element("バージョン")
        XCTAssertTrue(version.exists, "バージョン行が見つかりません。")
        XCTAssertGreaterThan(
            deletes.firstMatch.frame.minY, version.frame.minY,
            "「アカウントを削除」はリストの最後(バージョンより下)にある必要があります。"
        )
    }

    func testAccountDeletionIsASingleLastRowInGearSheet() {
        openGear()
        scrollToBottom()
        let deletes = app.buttons.matching(NSPredicate(format: "label == %@", "アカウントを削除"))
        XCTAssertEqual(deletes.count, 1, "「アカウントを削除」は1つだけである必要があります。")
        let terms = element("利用規約を見る")
        XCTAssertGreaterThan(
            deletes.firstMatch.frame.minY, terms.frame.minY,
            "歯車のシートでも「アカウントを削除」は最後の行である必要があります。"
        )
    }
}
