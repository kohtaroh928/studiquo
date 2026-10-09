import XCTest
import Combine
@testable import studiquo

@MainActor
final class StartupStoreLoaderTests: XCTestCase {
    func testBlockedOpenReachesDeadlineAndStillAcceptsLateSuccess() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = expectation(description: "Store open started")
        let delayed = expectation(description: "Deadline fires while store is blocked")
        let ready = expectation(description: "Late success opens the app")
        let loader = StartupStoreLoader(timeout: 0.05) {
            entered.fulfill()
            release.wait()
            return 42
        }
        let subscription = loader.$state.sink { state in
            if case .delayed = state { delayed.fulfill() }
            if case .ready(42) = state { ready.fulfill() }
        }
        defer { subscription.cancel() }

        loader.start()
        loader.start() // Another window must not open the same store again.
        await fulfillment(of: [entered, delayed], timeout: 2)
        guard case .delayed = loader.state else { return XCTFail("Still stuck loading") }
        loader.start() // A timeout does not make the existing open cancellable.
        guard case .delayed = loader.state else { return XCTFail("Started a competing open") }
        release.signal()
        await fulfillment(of: [ready], timeout: 2)
        loader.start()
        guard case .ready(42) = loader.state else { return XCTFail("Reopened a ready store") }
    }

    func testSuccessIsNotOverwrittenByDeadline() async {
        let ready = expectation(description: "Ready")
        let lateDeadline = expectation(description: "Past the deadline")
        let loader = StartupStoreLoader(timeout: 0.05) { 7 }
        let subscription = loader.$state.sink { state in
            if case .ready(7) = state { ready.fulfill() }
            if case .delayed = state { XCTFail("Deadline replaced a ready store") }
        }
        defer { subscription.cancel() }
        loader.start()
        await fulfillment(of: [ready], timeout: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { lateDeadline.fulfill() }
        await fulfillment(of: [lateDeadline], timeout: 2)
        guard case .ready(7) = loader.state else { return XCTFail("Lost ready state") }
    }

    func testFailureCanBeRetriedAfterOpenHasFinished() async {
        let attempts = Attempts()
        let failed = expectation(description: "Failure is visible")
        let ready = expectation(description: "Retry succeeds")
        let loader = StartupStoreLoader(timeout: 1) { try attempts.open() }
        let subscription = loader.$state.sink { state in
            if case .failed = state { failed.fulfill() }
            if case .ready(2) = state { ready.fulfill() }
        }
        defer { subscription.cancel() }
        loader.start()
        await fulfillment(of: [failed], timeout: 2)
        loader.start()
        await fulfillment(of: [ready], timeout: 2)
    }

    // The launch screen must never stay on the plain spinner: whatever the
    // store open does, the state has to reach `.ready`, `.failed` or
    // `.delayed` (the notice that tells the person something is slow).

    private func isTerminalOrNotified(_ state: StartupStoreLoader<Int>.State) -> Bool {
        switch state {
        case .idle, .loading: false
        case .delayed, .failed, .ready: true
        }
    }

    func testStartMovesOffIdleImmediately() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = StartupStoreLoader(timeout: 10) { release.wait(); return 1 }
        guard case .idle = loader.state else { return XCTFail("Should begin idle") }
        loader.start()
        guard case .loading = loader.state else { return XCTFail("start() must enter .loading synchronously") }
    }

    func testImmediateFailureShowsFailedAndReportsTheError() async {
        let reported = expectation(description: "Failure reported once")
        reported.assertForOverFulfill = true
        let failed = expectation(description: "Failed state shown")
        let loader = StartupStoreLoader<Int>(
            timeout: 10,
            openStore: { throw NSError(domain: "StartupTest", code: 7) },
            onFailure: { error in
                XCTAssertEqual((error as NSError).code, 7)
                reported.fulfill()
            }
        )
        let subscription = loader.$state.sink { state in
            if case .failed(let message) = state {
                XCTAssertFalse(message.isEmpty, "the person must be told something")
                failed.fulfill()
            }
        }
        defer { subscription.cancel() }
        loader.start()
        await fulfillment(of: [failed, reported], timeout: 2)
    }

    func testFailureArrivingAfterTheDeadlineReplacesTheSlowNoticeAndCanBeRetried() async {
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let delayed = expectation(description: "Slow notice")
        let failed = expectation(description: "Failure replaces the notice")
        let ready = expectation(description: "Retry succeeds")
        let loader = StartupStoreLoader<Int>(timeout: 0.05) {
            if calls.next() == 1 {
                release.wait()
                throw NSError(domain: "StartupTest", code: 2)
            }
            return 9
        }
        let subscription = loader.$state.sink { state in
            if case .delayed = state { delayed.fulfill() }
            if case .failed = state { failed.fulfill() }
            if case .ready(9) = state { ready.fulfill() }
        }
        defer { subscription.cancel() }
        loader.start()
        await fulfillment(of: [delayed], timeout: 2)
        release.signal()
        await fulfillment(of: [failed], timeout: 2)
        loader.start()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(calls.count, 2, "the retry opens the store exactly once more")
    }

    func testEveryOutcomeLeavesTheSpinnerWithinTheDeadline() async {
        enum Outcome: CaseIterable { case success, failure, hangs }
        for outcome in Outcome.allCases {
            let release = DispatchSemaphore(value: 0)
            let loader = StartupStoreLoader<Int>(timeout: 0.1) {
                switch outcome {
                case .success: return 1
                case .failure: throw NSError(domain: "StartupTest", code: 3)
                case .hangs: release.wait(); return 1
                }
            }
            loader.start()
            let deadline = Date().addingTimeInterval(2)
            while !isTerminalOrNotified(loader.state), Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(isTerminalOrNotified(loader.state), "\(outcome) left the launch screen on the plain spinner")
            release.signal()
        }
    }

    func testRepeatedStartDuringLoadingOpensTheStoreOnlyOnce() async {
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let ready = expectation(description: "Ready")
        let loader = StartupStoreLoader<Int>(timeout: 10) {
            _ = calls.next()
            release.wait()
            return 5
        }
        let subscription = loader.$state.sink { state in
            if case .ready(5) = state { ready.fulfill() }
        }
        defer { subscription.cancel() }
        for _ in 0..<5 { loader.start() }
        release.signal()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(calls.count, 1)
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func open() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == 1 { throw NSError(domain: "StartupTest", code: 1) }
        return count
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return value }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
