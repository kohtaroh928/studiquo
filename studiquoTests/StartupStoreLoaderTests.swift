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
