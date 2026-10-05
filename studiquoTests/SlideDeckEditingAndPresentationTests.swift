import XCTest
@testable import studiquo

@MainActor
final class SlideDeckEditingAndPresentationTests: XCTestCase {
    private func deckWithThreeSlides() -> SlideDeck {
        let deck = SlideDeck(title: "発表")
        for index in 0..<3 {
            let slide = Slide(order: index, layout: .titleAndBody)
            slide.titleText = "slide-\(index)"
            slide.deck = deck
            deck.addSlide(slide)
        }
        return deck
    }

    func testAddSlideAppendsAndRenumbers() {
        let deck = deckWithThreeSlides()
        let added = SlideDeckEditingLogic.addSlide(to: deck, layout: .sectionHeader)
        XCTAssertEqual(deck.sortedSlides.count, 4)
        XCTAssertTrue(deck.sortedSlides.last === added)
        XCTAssertEqual(added.order, 3)
        XCTAssertEqual(added.legacyLayout, .sectionHeader)
    }

    func testDuplicateCopiesContentImmediatelyAfterSource() {
        let deck = deckWithThreeSlides()
        let source = deck.sortedSlides[1]
        source.bodyText = "本文"
        source.notes = "発表者ノート"

        let copy = SlideDeckEditingLogic.duplicate(source, in: deck)

        XCTAssertEqual(deck.sortedSlides.map(\.order), [0, 1, 2, 3])
        XCTAssertTrue(deck.sortedSlides[2] === copy)
        XCTAssertEqual(copy.titleText, source.titleText)
        XCTAssertEqual(copy.bodyText, "本文")
        XCTAssertEqual(copy.notes, "発表者ノート")
    }

    func testMoveSwapsSlidesAndRejectsOutOfRangeMove() {
        let deck = deckWithThreeSlides()
        let first = deck.sortedSlides[0]
        XCTAssertTrue(SlideDeckEditingLogic.move(first, by: 1, in: deck))
        XCTAssertEqual(deck.sortedSlides.map(\.titleText), ["slide-1", "slide-0", "slide-2"])
        XCTAssertFalse(SlideDeckEditingLogic.move(deck.sortedSlides[0], by: -1, in: deck))
    }

    func testDeleteSelectsFollowingSlideAndRenumbers() {
        let deck = deckWithThreeSlides()
        let middle = deck.sortedSlides[1]
        let following = deck.sortedSlides[2]
        let selection = SlideDeckEditingLogic.delete(middle, from: deck)
        XCTAssertTrue(selection === following)
        XCTAssertEqual(deck.sortedSlides.map(\.order), [0, 1])
        XCTAssertNil(middle.deck)
    }

    func testPresentationClampsStartIndexAndMovesBetweenSlides() {
        XCTAssertEqual(SlidePresentationLogic.initialIndex(startAt: -4, slideCount: 3), 0)
        XCTAssertEqual(SlidePresentationLogic.initialIndex(startAt: 99, slideCount: 3), 2)
        XCTAssertEqual(
            SlidePresentationLogic.action(step: 1, index: 0, revealStepIndex: 0, animationStepCount: 1, slideCount: 3),
            .move(to: 1)
        )
        XCTAssertEqual(
            SlidePresentationLogic.action(step: -1, index: 1, revealStepIndex: 0, animationStepCount: 1, slideCount: 3),
            .move(to: 0)
        )
    }

    func testPresentationRevealsAnimationsBeforeMovingAndFinishesAtEnd() {
        XCTAssertEqual(
            SlidePresentationLogic.action(step: 1, index: 0, revealStepIndex: 0, animationStepCount: 3, slideCount: 2),
            .reveal(step: 1)
        )
        XCTAssertEqual(
            SlidePresentationLogic.action(step: 1, index: 1, revealStepIndex: 2, animationStepCount: 3, slideCount: 2),
            .finish
        )
        XCTAssertEqual(
            SlidePresentationLogic.action(step: -1, index: 0, revealStepIndex: 0, animationStepCount: 1, slideCount: 2),
            .none
        )
    }

    func testExternalConnectionSelectsPresenterSurface() {
        XCTAssertEqual(SlidePresentationLogic.surface(externalDisplayConnected: false), .audience)
        XCTAssertEqual(SlidePresentationLogic.surface(externalDisplayConnected: true), .presenter)
    }
}
