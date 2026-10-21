import XCTest

/// カレンダーの予定を作る・直す・消す流れ。メモ欄の保持は
/// `LibraryDropInteractionTests.testCalendarEventNotesStayVisibleAndSave` が見ているので、
/// ここでは保存の条件、取り消し、再編集、削除、種類の選択肢を見る。
final class CalendarEventFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // 予定を保存すると通知の許可を尋ねることがある。出たら断って先へ進む。
        addUIInterruptionMonitor(withDescription: "通知の許可") { alert in
            for label in ["許可しない", "Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--startup-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["ホーム"].waitForExistence(timeout: 20), "ホームが表示されません。")
        app.buttons["カレンダー"].tap()
        XCTAssertTrue(app.staticTexts["カレンダー"].waitForExistence(timeout: 10), "カレンダー画面が開きません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: - 手順

    private func openNewEventEditor() {
        let add = app.buttons["予定を追加"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "「予定を追加」ボタンがありません。")
        add.tap()
        XCTAssertTrue(app.navigationBars["予定を追加"].waitForExistence(timeout: 10), "予定の追加画面が開きません。")
    }

    private func typeTitle(_ text: String) {
        let title = app.textFields["calendar-event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "タイトル欄がありません。")
        title.tap()
        title.typeText(text)
    }

    /// 通知の行が出ているとシートの下側が組み立てられないことがあるので、
    /// 通知の有無を問わないテストでは切っておく(メモ欄のテストと同じ理由)。
    private func switchRemindersOff() {
        let notify = app.switches["通知する"]
        guard notify.waitForExistence(timeout: 5) else { return }
        if (notify.value as? String) == "1" {
            notify.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
    }

    private func createEvent(titled text: String) {
        openNewEventEditor()
        switchRemindersOff()
        typeTitle(text)
        let save = app.buttons["保存"]
        XCTAssertTrue(save.isEnabled, "タイトルを入れたのに「保存」が押せません。")
        save.tap()
        XCTAssertTrue(app.staticTexts[text.trimmingCharacters(in: .whitespaces)].waitForExistence(timeout: 10),
                      "保存した予定が一覧に出ません: \(text)")
    }

    // MARK: - テスト

    func testDayWithNoEventsShowsThePlaceholderAndAZeroCount() {
        XCTAssertTrue(app.staticTexts["予定はありません"].waitForExistence(timeout: 10), "予定のない日の案内がありません。")
        XCTAssertTrue(app.staticTexts["0件の予定"].exists, "件数が「0件の予定」になっていません。")
    }

    func testSaveStaysDisabledUntilTheTitleHasRealText() {
        openNewEventEditor()
        let save = app.buttons["保存"]
        XCTAssertFalse(save.isEnabled, "タイトルが空なのに「保存」が押せます。")
        typeTitle("   ")
        XCTAssertFalse(save.isEnabled, "空白だけのタイトルで「保存」が押せます。")
        typeTitle("a")
        XCTAssertTrue(save.isEnabled, "タイトルを入れても「保存」が押せません。")
    }

    func testCancellingTheEditorLeavesNoEventBehind() {
        openNewEventEditor()
        typeTitle("取り消す予定")
        app.buttons["キャンセル"].tap()
        XCTAssertFalse(app.navigationBars["予定を追加"].waitForExistence(timeout: 2), "キャンセルしても画面が閉じません。")
        XCTAssertFalse(app.staticTexts["取り消す予定"].exists, "キャンセルした予定が一覧に残っています。")
        XCTAssertTrue(app.staticTexts["0件の予定"].exists)
    }

    func testSavedEventAppearsWithTheTitleTrimmedAndCounted() {
        createEvent(titled: "  レポート提出  ")
        XCTAssertTrue(app.staticTexts["1件の予定"].waitForExistence(timeout: 5), "件数が「1件の予定」になっていません。")
        XCTAssertFalse(app.staticTexts["予定はありません"].exists, "予定があるのに空の案内が出ています。")
    }

    func testTappingAnEventReopensItForEditingAndSavingReplacesTheTitle() {
        createEvent(titled: "中間テスト")
        app.staticTexts["中間テスト"].tap()
        XCTAssertTrue(app.navigationBars["予定を編集"].waitForExistence(timeout: 10), "予定をタップしても編集画面が開きません。")

        let title = app.textFields["calendar-event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.valueString, "中間テスト", "編集画面に今のタイトルが入っていません。")
        title.tap()
        title.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else if app.menuItems["すべてを選択"].exists { app.menuItems["すべてを選択"].tap() }
        title.typeText("期末テスト")
        app.buttons["保存"].tap()

        XCTAssertTrue(app.staticTexts["期末テスト"].waitForExistence(timeout: 10), "直したタイトルが一覧に出ません。")
        XCTAssertFalse(app.staticTexts["中間テスト"].exists, "元のタイトルが残っています。")
        XCTAssertTrue(app.staticTexts["1件の予定"].exists, "編集で予定が増えました。")
    }

    func testSwipingAnEventAwayDeletesItAndRestoresThePlaceholder() {
        createEvent(titled: "消す予定")
        let row = app.staticTexts["消す予定"]
        row.swipeLeft()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "スワイプしても「削除」が出ません。")
        delete.tap()
        XCTAssertTrue(app.staticTexts["予定はありません"].waitForExistence(timeout: 10), "削除しても予定が残っています。")
        XCTAssertFalse(row.exists)
        XCTAssertTrue(app.staticTexts["0件の予定"].exists)
    }

    func testEventKindPickerOffersTestClassAndOther() {
        openNewEventEditor()
        let picker = app.buttons["種類"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "「種類」の選択がありません。")
        picker.tap()
        for kind in ["テスト", "授業", "その他"] {
            XCTAssertTrue(app.buttons[kind].firstMatch.waitForExistence(timeout: 5), "種類に「\(kind)」がありません。")
        }
    }

    func testReminderRowsFollowTheNotifySwitch() {
        openNewEventEditor()
        let notify = app.switches["通知する"]
        XCTAssertTrue(notify.waitForExistence(timeout: 5))
        if (notify.value as? String) != "1" {
            notify.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.staticTexts["通知日時"].waitForExistence(timeout: 5), "通知を入にしても通知日時が出ません。")
        notify.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(app.staticTexts["通知日時"].waitForExistence(timeout: 2), "通知を切っても通知日時が残っています。")
    }
}

private extension XCUIElement {
    /// テキスト欄の今の内容(未入力なら空)。
    var valueString: String { (value as? String) ?? "" }
}
