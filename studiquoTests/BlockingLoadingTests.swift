import XCTest
@testable import studiquo

final class BlockingLoadingTests: XCTestCase {
    func testRemainingMinimumDisplay() {
        let shown = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            BlockingLoadingTiming.remainingMinimumDisplay(shownAt: shown, now: shown.addingTimeInterval(0.1)),
            0.3, accuracy: 0.001)
        XCTAssertEqual(
            BlockingLoadingTiming.remainingMinimumDisplay(shownAt: shown, now: shown.addingTimeInterval(2)), 0)
    }

    func testTheSlowNoticeComesAfterTheOverlayAppears() {
        XCTAssertGreaterThan(BlockingLoadingTiming.slowNoticeDelay, BlockingLoadingTiming.showDelay)
    }

    func testAnAncestorForTheSameSourceCoversANestedView() {
        XCTAssertTrue(BlockingLoadingScope.isCovered(source: "friends", presentationRoot: false, ancestors: ["friends"]))
    }

    func testADifferentSourceIsNotCovered() {
        XCTAssertFalse(BlockingLoadingScope.isCovered(source: "mcp", presentationRoot: false, ancestors: ["friends"]))
        XCTAssertFalse(BlockingLoadingScope.isCovered(source: "friends", presentationRoot: false, ancestors: []))
    }

    func testAPresentationRootDrawsItsOwnOverlayEvenUnderTheSameSource() {
        XCTAssertFalse(BlockingLoadingScope.isCovered(source: "friends", presentationRoot: true, ancestors: ["friends"]))
    }

    func testSourcesCoveredInsideAreResetAtAPresentationRootAndAccumulateOtherwise() {
        XCTAssertEqual(
            BlockingLoadingScope.sourcesCovered(source: "friends", presentationRoot: true, ancestors: ["default", "mcp"]),
            ["friends"])
        XCTAssertEqual(
            BlockingLoadingScope.sourcesCovered(source: "friends", presentationRoot: false, ancestors: ["default"]),
            ["default", "friends"])
    }
}
