import XCTest

/// The gear's settings sheet and the その他 tab are the same form
/// (`AppSettingsForm`), so what is changed in one must show in the other.
/// These guard that refactor: nothing dropped from the sheet, the saved
/// values are shared both ways, language changes apply immediately, and
/// account deletion stays a single, last row.
final class SettingsFormSharedTests: XCTestCase {
    private var app: XCUIApplication!
    /// Title of the category form on screen, if one is open: it replaces the
    /// settings title as the navigation bar the rows scroll under.
    private var categoryTitle: String?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-more"].waitForExistence(timeout: 20), "ホーム下部に「その他」タブがありません。")
    }

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Helpers

    private func openMore() {
        app.buttons["home-tab-more"].tap()
        XCTAssertTrue(app.navigationBars["その他"].waitForExistence(timeout: 10), "「その他」画面が開きません。")
    }

    private func openCategory(_ id: String) {
        app.openSettingsCategory(id)
        categoryTitle = SettingsCategoryUI.titles[id]
    }

    private func leaveCategory(_ id: String) {
        app.leaveSettingsCategory(id)
        categoryTitle = nil
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
        (scrollableList() ?? app).descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
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
        let settingsBar = app.navigationBars[categoryTitle ?? "設定"]
        if settingsBar.exists {
            let sheetBounds = settingsBar.frame
            let sheetLists = lists.filter {
                $0.frame.minX >= sheetBounds.minX - 20 && $0.frame.maxX <= sheetBounds.maxX + 20
            }
            if let sheet = sheetLists.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) { return sheet }
        }
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
        let settingsBar = app.navigationBars[categoryTitle ?? "設定"]
        let moreBar = app.navigationBars[categoryTitle ?? "その他"]
        let barBottom = settingsBar.exists ? settingsBar.frame.maxY : (moreBar.exists ? moreBar.frame.maxY : 0)
        guard row.exists && row.isHittable else { return false }
        let visibleBounds = (scrollableList()?.frame ?? app.frame).intersection(app.frame)
        // A partially clipped switch can report hittable even when its
        // center lies below the sheet and a tap dismisses the sheet.
        return row.frame.minY >= max(barBottom, visibleBounds.minY) + 4
            && row.frame.maxY <= visibleBounds.maxY - 4
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
        let categories: [(id: String, labels: [String])] = [
            ("account", ["プランとお支払い", "アカウントを削除"]),
            ("study", ["勉強時間を記録する", "左利きモード", "翌日復習を作成する"]),
            ("notifications", ["通知"]),
            ("privacy", ["エラー情報を自動送信", "AI機能とデータ送信について", "プライバシーポリシーを見る", "利用規約を見る"]),
        ]
        for category in categories {
            openCategory(category.id)
            for label in category.labels {
                let row = element(label)
                reveal(row)
                XCTAssertTrue(row.exists, "歯車のシートの「\(category.id)」に「\(label)」がありません。")
            }
            leaveCategory(category.id)
        }
        closeGear()
    }

    // MARK: 2. Settings changed in one place show in the other (both ways)

    private func toggle(_ label: String) -> XCUIElement {
        (scrollableList() ?? app).switches[label]
    }

    private func flip(_ label: String) {
        let sw = scrollTo(toggle(label))
        sw.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func value(_ label: String) -> String {
        let sw = scrollTo(toggle(label))
        return "\(sw.value ?? "")"
    }

    /// Flips `label` in その他, expects the gear sheet to show the same, flips it
    /// back in the gear sheet, and expects その他 to show the restored value.
    private func assertToggleIsSharedBothWays(_ label: String, in category: String) {
        openMore()
        openCategory(category)
        let original = value(label)
        flip(label)
        let changed = value(label)
        XCTAssertNotEqual(changed, original, "「\(label)」が「その他」で切り替わりません。")

        leaveCategory(category)

        openGear()
        openCategory(category)
        XCTAssertEqual(value(label), changed, "「その他」で切り替えた「\(label)」が歯車のシートに反映されていません。")
        flip(label)
        XCTAssertEqual(value(label), original, "歯車のシートで「\(label)」を戻せません。")
        leaveCategory(category)
        closeGear()

        openMore()
        openCategory(category)
        XCTAssertEqual(value(label), original, "歯車のシートで切り替えた「\(label)」が「その他」に反映されていません。")
    }

    func testStudyTimeTrackingIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("勉強時間を記録する", in: "study")
    }

    func testLeftHandedModeIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("左利きモード", in: "study")
    }

    func testDayAfterReviewIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("翌日復習を作成する", in: "study")
    }

    func testAutomaticErrorReportingIsSharedBetweenMoreAndGear() {
        assertToggleIsSharedBothWays("エラー情報を自動送信", in: "privacy")
    }

    // MARK: 3. Language applies immediately

    func testSwitchingLanguageToEnglishChangesTheScreenAtOnce() {
        openMore()
        openCategory("app")
        scrollTo(element("English")).tap()
        XCTAssertTrue(element("English").isSelected, "「English」を選んでも選択状態になりません。")
        // The tab's name is translated at once. (The settings list's own
        // navigation title, already pushed over, keeps its old text until it
        // is shown again, so it is not checked here.)
        let moreTab = app.buttons["home-tab-more"]
        leaveCategory("app")
        XCTAssertEqual(moreTab.label, "More", "タブ名が「More」になっていません。")
        // The screen the category was pushed over follows the language too.
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10), "押し込み画面の下の「その他」タイトルが「More」になっていません。")
    }

    // MARK: 4. Account deletion is a single row, at the very end

    private func scrollToBottom() {
        for _ in 0..<12 { app.swipeUp() }
    }

    func testAccountDeletionIsASingleLastRowInMore() {
        openMore()
        openCategory("account")
        scrollToBottom()
        let deletes = app.buttons.matching(NSPredicate(format: "label == %@", "アカウントを削除"))
        XCTAssertEqual(deletes.count, 1, "「アカウントを削除」は1つだけである必要があります。")
        let logout = element("ログアウト")
        XCTAssertTrue(logout.exists, "ログアウト行が見つかりません。")
        XCTAssertGreaterThan(
            deletes.firstMatch.frame.minY, logout.frame.minY,
            "「アカウントを削除」はアカウントの分類の最後(ログアウトより下)にある必要があります。"
        )
    }

    func testAccountDeletionIsASingleLastRowInGearSheet() {
        openGear()
        openCategory("account")
        scrollToBottom()
        let deletes = app.buttons.matching(NSPredicate(format: "label == %@", "アカウントを削除"))
        XCTAssertEqual(deletes.count, 1, "「アカウントを削除」は1つだけである必要があります。")
        let plan = element("プランとお支払い")
        XCTAssertGreaterThan(
            deletes.firstMatch.frame.minY, plan.frame.minY,
            "歯車のシートでも「アカウントを削除」はアカウントの分類の最後の行である必要があります。"
        )
    }
}
