import XCTest
@testable import studiquo

final class StudySessionLogicTests: XCTestCase {
    private func page(order: Int, question: String, mastery: Int = 0) -> NotePage {
        let page = NotePage(order: order)
        page.flashcardQuestion = question
        page.flashcardMastery = mastery
        return page
    }

    func testCardsAreSortedAndBlankQuestionsAreExcluded() {
        let notebook = Notebook(title: "数学")
        let second = page(order: 2, question: "第2問")
        let blank = page(order: 1, question: "  \n")
        let first = page(order: 0, question: "第1問")
        notebook.pages = [second, blank, first]

        let cards = StudySessionLogic.cards(in: notebook, weakOnly: false)

        XCTAssertEqual(cards.map(\.flashcardQuestion), ["第1問", "第2問"])
    }

    func testWeakOnlyExcludesMasteredCards() {
        let notebook = Notebook(title: "英語")
        notebook.pages = [
            page(order: 0, question: "未習得", mastery: 0),
            page(order: 1, question: "難しい", mastery: 1),
            page(order: 2, question: "習得済み", mastery: 2)
        ]

        XCTAssertEqual(
            StudySessionLogic.cards(in: notebook, weakOnly: true).map(\.flashcardQuestion),
            ["未習得", "難しい"]
        )
    }

    func testScoreUpdatesCardAndNotebookMetadata() {
        let notebook = Notebook(title: "化学")
        let card = page(order: 0, question: "元素記号")
        card.flashcardReviewCount = 3
        notebook.pages = [card]
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let next = StudySessionLogic.score(
            card, mastery: 1, in: notebook, weakOnly: false,
            currentIndex: 0, at: reviewedAt
        )

        XCTAssertEqual(card.flashcardMastery, 1)
        XCTAssertEqual(card.flashcardReviewCount, 4)
        XCTAssertEqual(card.flashcardLastReviewedAt, reviewedAt)
        XCTAssertEqual(notebook.updatedAt, reviewedAt)
        XCTAssertEqual(next, 0)
    }

    func testScoringMasteredInWeakOnlyDoesNotSkipTheFollowingCard() {
        let notebook = Notebook(title: "歴史")
        let first = page(order: 0, question: "A", mastery: 0)
        let second = page(order: 1, question: "B", mastery: 0)
        let third = page(order: 2, question: "C", mastery: 0)
        notebook.pages = [first, second, third]

        let next = StudySessionLogic.score(
            first, mastery: 2, in: notebook, weakOnly: true, currentIndex: 0
        )

        let remaining = StudySessionLogic.cards(in: notebook, weakOnly: true)
        XCTAssertEqual(next, 0)
        XCTAssertTrue(remaining[next] === second)
    }

    func testScoreAdvancesAndWrapsWhenCardRemainsInDeck() {
        let notebook = Notebook(title: "物理")
        let first = page(order: 0, question: "A")
        let second = page(order: 1, question: "B")
        notebook.pages = [first, second]

        XCTAssertEqual(
            StudySessionLogic.score(first, mastery: 1, in: notebook, weakOnly: false, currentIndex: 0),
            1
        )
        XCTAssertEqual(
            StudySessionLogic.score(second, mastery: 1, in: notebook, weakOnly: false, currentIndex: 1),
            0
        )
    }
}
