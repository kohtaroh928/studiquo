import XCTest
@testable import studiquo

final class FlashcardStudyLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func deck() -> FlashcardDeck {
        let deck = FlashcardDeck(title: "英単語")
        deck.cards = [
            Flashcard(question: "third", answer: "3", order: 2),
            Flashcard(question: "first", answer: "1", order: 0),
            Flashcard(question: "second", answer: "2", order: 1)
        ]
        return deck
    }

    func testCreationOrderUsesSortedCards() {
        let deck = deck()
        deck.orderMode = .creation
        XCTAssertEqual(FlashcardStudyLogic.orderedCards(in: deck).map(\.question), ["first", "second", "third"])
    }

    func testRandomOrderUsesShuffler() {
        let deck = deck()
        deck.orderMode = .random
        let cards = FlashcardStudyLogic.orderedCards(in: deck) { Array($0.reversed()) }
        XCTAssertEqual(cards.map(\.question), ["third", "second", "first"])
    }

    func testCorrectGradeUpdatesCardAndDeckTotals() {
        let deck = deck()
        let card = deck.sortedCards[0]
        let due = now.addingTimeInterval(86_400)

        FlashcardStudyLogic.recordGrade(
            correct: true, card: card, deck: deck, at: now,
            nextReviewDate: { _, mastery, correct in
                XCTAssertEqual(mastery, 1)
                XCTAssertTrue(correct)
                return due
            }
        )

        XCTAssertEqual(card.mastery, 1)
        XCTAssertEqual(card.reviewCount, 1)
        XCTAssertEqual(card.lastReviewedAt, now)
        XCTAssertEqual(card.nextReviewAt, due)
        XCTAssertEqual(deck.totalAnswered, 1)
        XCTAssertEqual(deck.totalCorrect, 1)
        XCTAssertEqual(deck.lastStudiedAt, now)
    }

    func testIncorrectGradeUpdatesTotalsAndAddsMistakeState() {
        let deck = deck()
        let card = deck.sortedCards[0]
        card.mastery = 2

        FlashcardStudyLogic.recordGrade(
            correct: false, card: card, deck: deck, at: now,
            nextReviewDate: { _, _, _ in nil }
        )

        XCTAssertEqual(card.mastery, 1)
        XCTAssertTrue(card.needsReview)
        XCTAssertEqual(deck.totalAnswered, 1)
        XCTAssertEqual(deck.totalCorrect, 0)
    }

    func testAdvanceCompletesOnlyAfterFinalCard() {
        let deck = deck()
        XCTAssertEqual(FlashcardStudyLogic.advance(after: 0, cardCount: 3, deck: deck), 1)
        XCTAssertEqual(deck.studySessionCount, 0)
        XCTAssertNil(FlashcardStudyLogic.advance(after: 2, cardCount: 3, deck: deck))
        XCTAssertEqual(deck.studySessionCount, 1)
    }

    func testRetryUsesOnlyIncorrectCardsInOriginalOrder() {
        let cards = deck().sortedCards
        let retry = FlashcardStudyLogic.retryCards(from: [cards[2], cards[0]])
        XCTAssertEqual(retry.map(\.question), ["third", "first"])
    }
}
