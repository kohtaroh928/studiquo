import XCTest
@testable import studiquo

final class FlashcardEditingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func deck(_ questions: [String]) -> FlashcardDeck {
        let deck = FlashcardDeck(title: "テスト")
        for (index, question) in questions.enumerated() {
            let card = Flashcard(question: question, answer: "a", order: index)
            card.deck = deck
            deck.addCard(card)
        }
        return deck
    }

    func testValidityNeedsBothSidesToHaveNonWhitespaceText() {
        XCTAssertTrue(FlashcardEditing.isValid(question: "Q", answer: "A"))
        XCTAssertFalse(FlashcardEditing.isValid(question: "", answer: "A"))
        XCTAssertFalse(FlashcardEditing.isValid(question: "Q", answer: ""))
        XCTAssertFalse(FlashcardEditing.isValid(question: " \n\t", answer: "A"))
        XCTAssertFalse(FlashcardEditing.isValid(question: "Q", answer: "　 "))
    }

    func testMakeCardTrimsAppendsAtTheEndAndTouchesTheDeck() throws {
        let deck = deck(["one", "two"])
        let card = try XCTUnwrap(FlashcardEditing.makeCard(question: "  apple\n", answer: " りんご ", in: deck, at: now))

        XCTAssertEqual(card.question, "apple")
        XCTAssertEqual(card.answer, "りんご")
        XCTAssertEqual(card.order, 2)
        XCTAssertTrue(card.deck === deck)
        XCTAssertEqual(deck.sortedCards.map(\.question), ["one", "two", "apple"])
        XCTAssertEqual(deck.updatedAt, now)
    }

    func testMakeCardOnAnEmptyDeckCreatesTheCardArray() throws {
        let deck = FlashcardDeck(title: "空")
        XCTAssertNil(deck.cards)
        let card = try XCTUnwrap(FlashcardEditing.makeCard(question: "Q", answer: "A", in: deck))
        XCTAssertEqual(card.order, 0)
        XCTAssertEqual(deck.cards?.count, 1)
    }

    func testMakeCardRejectsBlankSidesWithoutChangingTheDeck() {
        let deck = deck(["one"])
        let before = deck.updatedAt
        XCTAssertNil(FlashcardEditing.makeCard(question: "  ", answer: "A", in: deck, at: now))
        XCTAssertNil(FlashcardEditing.makeCard(question: "Q", answer: "\n", in: deck, at: now))
        XCTAssertEqual(deck.cards?.count, 1)
        XCTAssertEqual(deck.updatedAt, before)
    }

    func testRecognizedTextStartsAnEmptyFieldAndAppendsOnANewLine() {
        var field = ""
        XCTAssertTrue(FlashcardEditing.appendRecognizedText("  abc \n", to: &field))
        XCTAssertEqual(field, "abc")

        XCTAssertTrue(FlashcardEditing.appendRecognizedText("def", to: &field))
        XCTAssertEqual(field, "abc\ndef")

        var endingWithNewline = "x\n"
        XCTAssertTrue(FlashcardEditing.appendRecognizedText("y", to: &endingWithNewline))
        XCTAssertEqual(endingWithNewline, "x\ny", "既に改行で終わっていれば改行を重ねない")
    }

    func testRecognizedTextThatIsNilOrBlankChangesNothing() {
        var field = "keep"
        XCTAssertFalse(FlashcardEditing.appendRecognizedText(nil, to: &field))
        XCTAssertFalse(FlashcardEditing.appendRecognizedText(" \n ", to: &field))
        XCTAssertEqual(field, "keep")
    }

    func testMoveReordersAndRenumbersFromZero() {
        let deck = deck(["A", "B", "C", "D"])
        FlashcardEditing.move(from: IndexSet(integer: 0), to: 3, in: deck, at: now)
        XCTAssertEqual(deck.sortedCards.map(\.question), ["B", "C", "A", "D"])
        XCTAssertEqual(deck.sortedCards.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(deck.updatedAt, now)

        FlashcardEditing.move(from: IndexSet(integer: 3), to: 0, in: deck, at: now)
        XCTAssertEqual(deck.sortedCards.map(\.question), ["D", "B", "C", "A"])
    }

    func testRenumberClosesGapsLeftByADeletedCard() {
        let deck = deck(["A", "B", "C"])
        deck.cards?.removeAll { $0.question == "B" }
        XCTAssertEqual(deck.sortedCards.map(\.order), [0, 2])

        FlashcardEditing.renumber(deck, at: now)
        XCTAssertEqual(deck.sortedCards.map(\.question), ["A", "C"])
        XCTAssertEqual(deck.sortedCards.map(\.order), [0, 1])
        XCTAssertEqual(deck.updatedAt, now)
    }
}
