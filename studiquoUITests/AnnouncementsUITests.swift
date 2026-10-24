import XCTest

/// その他 → 通知・お知らせ → お知らせ。運営のお知らせは公開APIから取るので、
/// 届いているかどうかはテストの環境次第。どちらでも崩れないことを見る。
final class AnnouncementsUITests: XCTestCase {
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

    private func openAnnouncements() {
        app.buttons["home-tab-more"].tap()
        XCTAssertTrue(app.navigationBars["その他"].waitForExistence(timeout: 10), "「その他」画面が開きません。")
        app.openSettingsCategory("notifications")
        let row = app.descendants(matching: .any)["more-announcements"].firstMatch
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "「お知らせ」の行がありません。")
        row.tap()
        XCTAssertTrue(app.navigationBars["お知らせ"].waitForExistence(timeout: 10), "お知らせ画面が開きません。")
    }

    func testBackFromAnnouncementsLeavesTheScreen() {
        openAnnouncements()
        let back = app.navigationBars["お知らせ"].buttons["BackButton"]
        XCTAssertTrue(back.exists, "戻るボタンがありません。")
        back.tap()
        XCTAssertTrue(app.navigationBars["お知らせ"].waitForNonExistence(timeout: 5), "戻ってもお知らせ画面が残っています。")
        let known = ["その他", SettingsCategoryUI.titles["notifications"]!]
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in known.contains { self.app.navigationBars[$0].exists } }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 5), .completed, "戻った先が「その他」でも通知の分類でもありません。")
    }

    func testTheScreenShowsEitherTheNoticesOrAnExplanationForNone() {
        openAnnouncements()
        let empty = app.descendants(matching: .any)["announcements-empty"].firstMatch
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'announcement-row-'"))
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in empty.exists || rows.count > 0 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 15), .completed, "お知らせの一覧も「ありません」の案内も出ません。")
        if empty.exists {
            let known = ["お知らせはまだありません。", "お知らせを取得できませんでした。通信状況を確認してください。"]
            // `Text(LocalizedStringKey(...))` で表示するので、翻訳キーのまま出ない(直した不具合の回帰テスト)。
            XCTAssertTrue(known.contains(empty.label), "空のときの案内が日本語になっていません: \(empty.label)")
            XCTAssertFalse(app.buttons["すべて既読"].exists, "お知らせが無いのに「すべて既読」が出ています。")
        } else {
            XCTAssertGreaterThan(rows.count, 0)
        }
    }

    func testOpeningANoticeShowsItsDetailAndGoingBackKeepsTheList() throws {
        openAnnouncements()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'announcement-row-'"))
        let appeared = rows.firstMatch.waitForExistence(timeout: 15)
        try XCTSkipUnless(appeared, "この環境には届いているお知らせがないため、詳細画面は確認できません。")
        rows.firstMatch.tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "詳細画面に移っていません。")
        back.tap()
        XCTAssertTrue(app.navigationBars["お知らせ"].waitForExistence(timeout: 5), "詳細から一覧に戻れません。")
        XCTAssertTrue(rows.firstMatch.exists, "戻ると一覧が消えています。")
    }
}
