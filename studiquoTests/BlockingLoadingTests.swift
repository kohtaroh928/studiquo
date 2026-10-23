import XCTest
@testable import studiquo

@MainActor
final class BlockingLoadingTests: XCTestCase {
    func testCoordinatorIsActiveOnlyWhileOperationRuns() async {
        let coordinator = BlockingLoadingCoordinator()
        XCTAssertFalse(coordinator.isActive)
        await coordinator.withBlockingLoading {
            XCTAssertTrue(coordinator.isActive)
        }
        XCTAssertFalse(coordinator.isActive)
    }

    func testOverlappingOperationsKeepItActiveUntilTheLastEnds() async {
        let coordinator = BlockingLoadingCoordinator()
        async let slow: Void = coordinator.withBlockingLoading {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await coordinator.withBlockingLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(coordinator.isActive)
        await slow
        XCTAssertFalse(coordinator.isActive)
    }

    func testOperationThatThrowsStillEndsLoading() async {
        struct Boom: Error {}
        let coordinator = BlockingLoadingCoordinator()
        do {
            try await coordinator.withBlockingLoading { throw Boom() }
            XCTFail("expected throw")
        } catch {}
        XCTAssertFalse(coordinator.isActive)
    }

    func testRemainingMinimumDisplay() {
        let shown = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            BlockingLoadingTiming.remainingMinimumDisplay(shownAt: shown, now: shown.addingTimeInterval(0.1)),
            0.3, accuracy: 0.001)
        XCTAssertEqual(
            BlockingLoadingTiming.remainingMinimumDisplay(shownAt: shown, now: shown.addingTimeInterval(2)), 0)
    }
}
