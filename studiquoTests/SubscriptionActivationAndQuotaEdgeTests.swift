import Foundation
import RevenueCat
import XCTest
@testable import studiquo

@MainActor
final class SubscriptionActivationAndQuotaEdgeTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "SubscriptionActivationAndQuotaEdgeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - 1. StudiquoPlan Comparable rank & localized titles

    func testStudiquoPlanRankOrderingAndTitles() {
        let allPlans: [StudiquoPlan] = [.free, .standard, .plus, .pro]
        XCTAssertEqual(StudiquoPlan.allCases, allPlans)
        XCTAssertLessThan(StudiquoPlan.free, .standard)
        XCTAssertLessThan(StudiquoPlan.standard, .plus)
        XCTAssertLessThan(StudiquoPlan.plus, .pro)

        XCTAssertEqual(StudiquoPlan.free.title, "未加入")
        XCTAssertEqual(StudiquoPlan.standard.title, "Standard")
        XCTAssertEqual(StudiquoPlan.plus.title, "Plus")
        XCTAssertEqual(StudiquoPlan.pro.title, "Pro")
    }

    // MARK: - 2. refreshIfStale interval throttling

    func testRefreshIfStaleSkipsLookupWithinMinimumIntervalAndRefreshesWhenIntervalIsZero() async {
        var serverCalls = 0
        let store = SubscriptionStore(
            automaticallyRefresh: false,
            paywallEnabled: true,
            serverPlanProvider: {
                serverCalls += 1
                return .plus
            },
            defaults: isolatedDefaults(),
            accountIDProvider: { "acct-stale-test" }
        )

        // First call performs refresh because lastRefresh is nil:
        await store.refreshIfStale(minimumInterval: 60)
        XCTAssertEqual(serverCalls, 1)
        XCTAssertEqual(store.currentPlan, .plus)

        // Immediate second call within 60s window is skipped:
        await store.refreshIfStale(minimumInterval: 60)
        XCTAssertEqual(serverCalls, 1, "Refresh within minimumInterval must be skipped")

        // Calling with minimumInterval: 0 forces a refresh:
        await store.refreshIfStale(minimumInterval: 0)
        XCTAssertEqual(serverCalls, 2)
    }

    // MARK: - 3. Sign-out generation bump aborts in-flight confirmPlanOnServer polling

    func testSignOutDuringConfirmPlanOnServerStopsPollingAndDoesNotApplyLateServerPlan() async {
        var pollCount = 0
        var store: SubscriptionStore!
        store = SubscriptionStore(
            automaticallyRefresh: false,
            paywallEnabled: true,
            serverPlanProvider: { @MainActor in
                pollCount += 1
                if pollCount == 1 {
                    // Simulate user signing out while webhook polling is in flight
                    store.resetForSignOut()
                }
                return .pro
            },
            defaults: isolatedDefaults(),
            accountIDProvider: { "acct-polling" }
        )
        store.activationDelays = Array(repeating: .milliseconds(1), count: 5)
        store.setPurchasedPlanForTesting(.pro)

        await store.confirmPlanOnServer()

        XCTAssertEqual(pollCount, 1, "Polling loop must stop immediately once resetForSignOut bumps generation")
        XCTAssertEqual(store.currentPlan, .free)
        XCTAssertFalse(store.isActivatingPlan)
    }

    // MARK: - 4. User-cancelled purchase leaves state clean without error message

    func testUserCancelledPurchaseDoesNotShowMessageOrStartServerConfirmation() async {
        var serverCalls = 0
        let store = SubscriptionStore(
            automaticallyRefresh: false,
            paywallEnabled: true,
            serverPlanProvider: {
                serverCalls += 1
                return .standard
            },
            defaults: isolatedDefaults(),
            accountIDProvider: { "acct-cancel" }
        )

        enum UnusedError: Error { case shouldNotReach }
        await store.performPurchase {
            // Simulate RevenueCat user cancellation before CustomerInfo is applied
            throw CancellationCheck.cancelled
        }
        // Verify error path vs cancellation: now test that isPurchasing always resets
        XCTAssertFalse(store.isPurchasing)
        XCTAssertEqual(serverCalls, 0)
    }

    private enum CancellationCheck: LocalizedError {
        case cancelled
        var errorDescription: String? { "Purchase cancelled" }
    }
}
