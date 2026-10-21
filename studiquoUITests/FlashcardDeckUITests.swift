import XCTest

/// 暗記帳の画面。ライブラリの「Cards」(カード0枚の暗記帳)を開いて、カードを作る・直す・消す、
/// 暗記して結果を見るまでを通す。長押しメニューは `LibraryDropInteractionTests` が見ている。
final class FlashcardDeckUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.yabuko.studiquo")
        app.launchArguments = ["--library-drop-ui-test", "--resource-types-fixture"]
        app.launch()
        let deck = app.descendants(matching: .any)["library-entry-Cards"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 20), "ライブラリに暗記帳「Cards」がありません。")
        deck.tap()
        XCTAssertTrue(app.buttons["ホームへ戻る"].waitForExistence(timeout: 10), "暗記帳が開きません。")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: - 手順

    // 空の入力欄は、中身ではなくプレースホルダ(「問題」「答え」)が値になる。文字を入れると
    // その名前では探せなくなるので、位置(上が問題、下が答え)で選ぶ。
    private var questionField: XCUIElement { app.textFields.element(boundBy: 0) }
    private var answerField: XCUIElement { app.textFields.element(boundBy: 1) }
    private var saveCardButton: XCUIElement { app.buttons["このカードを保存して次へ"] }

    private func fill(_ field: XCUIElement, with text: String) {
        // キーボードや案内文で下に押し出された欄は、リストが組み立てていないことがある。
        for _ in 0..<3 where !field.exists { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "入力欄がありません: \(field)")
        field.tap()
        field.typeText(text)
    }

    /// 結果画面のボタンは、存在していても `isHittable` が真にならないことがある(スクロールの中にあり、
    /// 位置の計算が定まらない)。存在を待ってから、ボタンの中心を座標で押す。
    private func tapByCoordinate(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), message)
        Thread.sleep(forTimeInterval: 1)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func addCard(_ question: String, _ answer: String) {
        fill(questionField, with: question)
        fill(answerField, with: answer)
        XCTAssertTrue(saveCardButton.isEnabled, "問題と答えを入れたのに保存できません。")
        saveCardButton.tap()
        let shown = question.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", shown)).firstMatch
            .waitForExistence(timeout: 10), "保存したカードが一覧に出ません: \(shown)")
    }

    /// 暗記モードに入り、設定画面を出す。上の「暗記する」/「カード作成」は切り替えの2択。
    private func openStudySetup() {
        app.buttons["暗記する"].firstMatch.tap()
        XCTAssertTrue(app.buttons["スタート"].waitForExistence(timeout: 10), "暗記の設定画面が開きません。")
    }

    // MARK: - カード作成

    func testEmptyDeckShowsNoCardsAndCannotStartStudying() {
        XCTAssertTrue(app.staticTexts["作成済みカード(0枚)"].exists
                      || app.staticTexts["作成済みカード（0枚）"].exists, "作成済みカードの見出しが0枚になっていません。")
        app.buttons["暗記する"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["先に暗記カードを作成してください"].waitForExistence(timeout: 10), "カードが0枚のときの案内がありません。")
        let start = app.buttons["スタート"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "カードが0枚なのに「スタート」が押せます。")
    }

    func testSavingNeedsBothQuestionAndAnswerAndExplainsWhy() {
        XCTAssertFalse(saveCardButton.isEnabled, "何も入れていないのに保存できます。")
        XCTAssertFalse(app.staticTexts["問題と答えの両方を入力すると、次のカードを作れます。"].exists, "何も入れていないのに注意が出ています。")

        fill(questionField, with: "光合成とは")
        XCTAssertFalse(saveCardButton.isEnabled, "問題だけで保存できます。")
        XCTAssertTrue(app.staticTexts["問題と答えの両方を入力すると、次のカードを作れます。"].waitForExistence(timeout: 5), "片方だけのときの案内がありません。")

        fill(answerField, with: "   ")
        XCTAssertFalse(saveCardButton.isEnabled, "空白だけの答えで保存できます。")
    }

    func testSavedCardIsListedAndTheFormIsClearedForTheNextOne() {
        addCard("  mitochondria  ", "  エネルギーを作る  ")
        XCTAssertTrue(app.staticTexts["1. mitochondria"].exists, "問題の前後の空白が取り除かれていません。")
        XCTAssertTrue(app.staticTexts["エネルギーを作る"].exists)
        XCTAssertEqual(questionField.valueString, "", "保存後も問題欄に文字が残っています。")
        XCTAssertEqual(answerField.valueString, "", "保存後も答え欄に文字が残っています。")
        XCTAssertFalse(saveCardButton.isEnabled)
    }

    func testTappingACardEditsItAndCancelKeepsTheOriginal() {
        addCard("元の問題", "元の答え")
        app.staticTexts["1. 元の問題"].tap()
        XCTAssertTrue(app.navigationBars["カードを編集"].waitForExistence(timeout: 10), "カードをタップしても編集画面が開きません。")
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.staticTexts["1. 元の問題"].waitForExistence(timeout: 5), "キャンセルしたのにカードが変わりました。")

        app.staticTexts["1. 元の問題"].tap()
        XCTAssertTrue(app.navigationBars["カードを編集"].waitForExistence(timeout: 10))
        // シートの欄は、入っている文字が値になる。後ろのカード作成フォームの欄(空)とは取り違えない。
        let question = app.textFields["元の問題"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "編集画面に今の問題が入っていません。")
        XCTAssertTrue(app.textFields["元の答え"].exists, "編集画面に今の答えが入っていません。")
        question.tap()
        question.typeText("(改)")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["1. 元の問題(改)"].waitForExistence(timeout: 10), "直した問題が一覧に出ません。")
    }

    func testSwipingACardAwayDeletesIt() {
        addCard("消すカード", "答え")
        let row = app.staticTexts["1. 消すカード"]
        row.swipeLeft()
        // 画面上部のツールバーにも(無効な)「削除」があるので、スワイプで出た行の「削除」を選ぶ。
        let rowFrame = row.frame
        let delete = app.buttons.matching(identifier: "削除").allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.midY >= rowFrame.minY - 40 && $0.frame.midY <= rowFrame.maxY + 40 && $0.frame.minY > 150
        }
        XCTAssertNotNil(delete, "スワイプしても行の「削除」が出ません。")
        delete?.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 3), "削除してもカードが残っています。")
        XCTAssertTrue(app.staticTexts["作成済みカード(0枚)"].exists || app.staticTexts["作成済みカード（0枚）"].exists, "削除後の見出しが0枚になっていません。")
    }

    // MARK: - 暗記

    func testStudySetupShowsTheDeckStatsAndTheTwoSettings() {
        addCard("問い1", "答え1")
        addCard("問い2", "答え2")
        openStudySetup()
        for label in ["出題順", "出題方向", "カード数", "学習回数", "平均正解率"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.exists, "暗記の設定画面に「\(label)」がありません。")
        }
        XCTAssertTrue(app.staticTexts["2"].exists, "カード数が2になっていません。")
        XCTAssertFalse(app.buttons["flashcard-mistake-review-start"].exists, "まだ間違えていないのに復習ボタンが出ています。")
        for option in ["作成順", "ランダム", "問題 → 答え", "答え → 問題"] {
            XCTAssertTrue(app.buttons[option].exists, "選択肢「\(option)」がありません。")
        }
    }

    func testStudyingShowsTheQuestionFirstThenTheAnswerAndGradesAdvance() {
        addCard("問い1", "答え1")
        addCard("問い2", "答え2")
        openStudySetup()
        app.buttons["スタート"].tap()

        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 10), "暗記が始まりません。")
        XCTAssertTrue(app.staticTexts["問い1"].exists, "最初に問題が出ていません。")
        XCTAssertFalse(app.staticTexts["答え1"].exists, "答えが先に見えています。")
        XCTAssertFalse(app.buttons["正解"].exists, "答えを見る前に採点できます。")

        app.staticTexts["問い1"].tap()
        XCTAssertTrue(app.staticTexts["答え1"].waitForExistence(timeout: 5), "カードを押しても答えが出ません。")
        XCTAssertTrue(app.buttons["正解"].exists && app.buttons["不正解"].exists)

        app.buttons["正解"].tap()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5), "採点しても次のカードに進みません。")
        XCTAssertTrue(app.staticTexts["問い2"].exists)
        XCTAssertFalse(app.buttons["正解"].exists, "次のカードで答えが出たままです。")
    }

    func testResultsReportTheScoreAndListWhatWasMissed() {
        addCard("問い1", "答え1")
        addCard("問い2", "答え2")
        openStudySetup()
        app.buttons["スタート"].tap()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 10))
        app.staticTexts["問い1"].tap()
        app.buttons["不正解"].tap()
        XCTAssertTrue(app.staticTexts["問い2"].waitForExistence(timeout: 5))
        app.staticTexts["問い2"].tap()
        app.buttons["正解"].tap()

        XCTAssertTrue(app.staticTexts["学習結果"].waitForExistence(timeout: 10), "最後まで答えても結果が出ません。")
        XCTAssertTrue(app.staticTexts["50%"].exists, "正答率が50%になっていません。")
        XCTAssertTrue(app.staticTexts["全 2 問中 1 問正解"].exists)
        XCTAssertTrue(app.staticTexts["間違えたカード"].exists)
        XCTAssertTrue(app.staticTexts["1. 問い1"].exists, "間違えたカードが一覧にありません。")
        XCTAssertFalse(app.staticTexts["全問正解です！"].exists)
        XCTAssertTrue(app.buttons["間違いのみ"].isEnabled)
    }

    func testAnAllCorrectRunCelebratesAndOffersNoRetryOfMistakes() {
        addCard("問い1", "答え1")
        openStudySetup()
        app.buttons["スタート"].tap()
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 10))
        app.staticTexts["問い1"].tap()
        app.buttons["正解"].tap()

        XCTAssertTrue(app.staticTexts["学習結果"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["100%"].exists)
        XCTAssertTrue(app.staticTexts["全問正解です！"].exists, "全問正解の表示がありません。")
        XCTAssertFalse(app.staticTexts["間違えたカード"].exists)
        XCTAssertFalse(app.buttons["間違いのみ"].isEnabled, "間違いがないのに「間違いのみ」が押せます。")
    }

    func testFinishingReturnsToTheSetupWhichNowOffersAMistakeReview() {
        addCard("問い1", "答え1")
        openStudySetup()
        app.buttons["スタート"].tap()
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 10))
        app.staticTexts["問い1"].tap()
        app.buttons["不正解"].tap()
        XCTAssertTrue(app.staticTexts["学習結果"].waitForExistence(timeout: 10))

        tapByCoordinate(app.buttons["終了"], "結果画面に「終了」がありません。")
        XCTAssertTrue(app.buttons["スタート"].waitForExistence(timeout: 10), "「終了」で設定画面に戻りません。")
        let review = app.buttons["flashcard-mistake-review-start"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "間違えたのに復習ボタンが出ません。")
        XCTAssertTrue(review.label.contains("1問"), "復習ボタンの問数が1問になっていません: \(review.label)")
    }

    func testReversedDirectionAsksTheAnswerFirst() {
        addCard("問い1", "答え1")
        openStudySetup()
        app.buttons["答え → 問題"].tap()
        app.buttons["スタート"].tap()
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["答え1"].exists, "「答え → 問題」なのに答えが先に出ていません。")
        XCTAssertFalse(app.staticTexts["問い1"].exists)
        app.staticTexts["答え1"].tap()
        XCTAssertTrue(app.staticTexts["問い1"].waitForExistence(timeout: 5), "面を押しても問題が出ません。")
    }

    func testSwitchingBackToCardCreationAndOutToHome() {
        addCard("問い1", "答え1")
        openStudySetup()
        app.buttons["カード作成"].firstMatch.tap()
        XCTAssertTrue(app.textFields["問題"].firstMatch.waitForExistence(timeout: 10), "カード作成に戻れません。")
        XCTAssertTrue(app.staticTexts["1. 問い1"].exists, "戻ると作ったカードが消えています。")
        app.buttons["ホームへ戻る"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-entry-Cards"].firstMatch.waitForExistence(timeout: 10), "ホームに戻れません。")
    }
}

private extension XCUIElement {
    /// テキスト欄の今の内容。未入力のときは、プレースホルダではなく空文字にする。
    var valueString: String {
        let text = (value as? String) ?? ""
        return text == (placeholderValue ?? "\u{0}") ? "" : text
    }
}
