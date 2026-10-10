import XCTest
@testable import studiquo

/// The swipe-to-trash gesture on folder rows. The drag maths lives in pure
/// functions so the "reopened row jumps back" regression can be pinned down
/// without driving a real touch.
final class SwipeToTrashRowTests: XCTestCase {
    private let reveal = SwipeToTrashRow.revealWidth

    func testDragFromClosedFollowsTheFinger() {
        XCTAssertEqual(SwipeToTrashRow.offset(start: 0, translation: -30), -30)
    }

    func testDragFromOpenContinuesFromTheOpenPosition() {
        // Regression: the offset used to restart from zero, so grabbing an
        // open row and moving 30pt right snapped it shut.
        XCTAssertEqual(SwipeToTrashRow.offset(start: -reveal, translation: 30), -reveal + 30)
    }

    func testOffsetNeverGoesPastClosedOrFullyOpen() {
        XCTAssertEqual(SwipeToTrashRow.offset(start: 0, translation: 50), 0)
        XCTAssertEqual(SwipeToTrashRow.offset(start: 0, translation: -500), -reveal)
        XCTAssertEqual(SwipeToTrashRow.offset(start: -reveal, translation: -40), -reveal)
        XCTAssertEqual(SwipeToTrashRow.offset(start: -reveal, translation: 500), 0)
    }

    func testRowSettlesOpenPastHalfwayAndClosedOtherwise() {
        XCTAssertEqual(SwipeToTrashRow.settledOffset(-reveal), -reveal)
        XCTAssertEqual(SwipeToTrashRow.settledOffset(-reveal / 2 - 1), -reveal)
        XCTAssertEqual(SwipeToTrashRow.settledOffset(-reveal / 2), 0)
        XCTAssertEqual(SwipeToTrashRow.settledOffset(0), 0)
    }

    func testReopenedRowDraggedSlightlyStaysOpen() {
        let dragged = SwipeToTrashRow.offset(start: -reveal, translation: 30)
        XCTAssertEqual(SwipeToTrashRow.settledOffset(dragged), -reveal)
    }
}
