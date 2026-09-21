import XCTest
@testable import studiquo

/// Coverage for `PullHoldTracker` — the wall-clock "has this pull gauge
/// been held full long enough" check, deliberately matching the notebook
/// feature's own 0.2-second hold requirement rather than firing on plain
/// release. See `PullHoldTracker`'s own doc comment for why a release-only
/// version was tried and then reverted: it diverged from the one mechanism
/// actually proven correct in production, and the user's own testing kept
/// reporting the same underlying problem either way.
final class PullHoldTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testDoesNotFireBeforeTheHoldDurationElapses() {
        var tracker = PullHoldTracker()
        XCTAssertFalse(tracker.update(progress: 1, holdDuration: 0.2, now: start))
        XCTAssertFalse(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.1)))
    }

    func testFiresExactlyOnceTheMomentTheHoldDurationIsReached() {
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.2)))
    }

    func testDoesNotFireAgainOnSubsequentCallsWhileStillHeld() {
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.3)), "already triggered once for this hold — must not fire twice")
    }

    func testDroppingBelowFullProgressResetsTheHold() {
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        _ = tracker.update(progress: 0.4, holdDuration: 0.2, now: start.addingTimeInterval(0.1))
        // Back to full, but the clock should have restarted at this point,
        // not counted from the original start.
        XCTAssertFalse(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.15)))
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.35)))
    }

    func testCanFireAgainAfterDroppingAndPullingFullAgain() {
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.2)))
        _ = tracker.update(progress: 0, holdDuration: 0.2, now: start.addingTimeInterval(0.3))
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.4))
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.6)), "a fresh pull after releasing must be able to trigger again")
    }

    func testBriefMomentaryDipsBelowFullDoNotPermanentlyBlockFiring() {
        // Momentum from a fast scroll can rebound within a few frames —
        // the whole reason a hold duration exists at all (see the
        // notebook feature's own rationale, quoted in
        // ContinuousScrollPullToAdd.swift). A dip resets the clock but the
        // gauge can still fire once held continuously afterward.
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        _ = tracker.update(progress: 0.9, holdDuration: 0.2, now: start.addingTimeInterval(0.05))
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.06))
        XCTAssertFalse(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.2)), "clock restarted at 0.06, so 0.2 hasn't held long enough yet")
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.27)))
    }

    func testExactlyAtTheHoldDurationCounts() {
        var tracker = PullHoldTracker()
        _ = tracker.update(progress: 1, holdDuration: 0.2, now: start)
        XCTAssertTrue(tracker.update(progress: 1, holdDuration: 0.2, now: start.addingTimeInterval(0.2)), ">= holdDuration should count, not just strictly greater")
    }
}
