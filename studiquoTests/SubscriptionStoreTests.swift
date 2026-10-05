import XCTest
@testable import studiquo

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    private enum TestError: Error { case unavailable }

    func testProductIdentifiersMapToExpectedPlans() {
        XCTAssertEqual(SubscriptionProductID.plan(for: SubscriptionProductID.plusMonthly), .plus)
        XCTAssertEqual(SubscriptionProductID.plan(for: SubscriptionProductID.plusYearly), .plus)
        XCTAssertEqual(SubscriptionProductID.plan(for: SubscriptionProductID.proMonthly), .pro)
        XCTAssertEqual(SubscriptionProductID.plan(for: SubscriptionProductID.proYearly), .pro)
        XCTAssertNil(SubscriptionProductID.plan(for: "unknown.product"))
    }

    func testHighestActiveEntitlementWins() {
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: []), .standard)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["plus"]), .plus)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["pro"]), .pro)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["plus", "pro"]), .pro)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["future-entitlement"]), .standard)
    }

    func testProductOrderingUsesPlanThenBillingPeriodThenPrice() {
        XCTAssertTrue(SubscriptionStore.productComesBefore(
            lhsID: SubscriptionProductID.plusYearly, lhsPrice: 10_000,
            rhsID: SubscriptionProductID.proMonthly, rhsPrice: 100
        ))
        XCTAssertTrue(SubscriptionStore.productComesBefore(
            lhsID: SubscriptionProductID.plusMonthly, lhsPrice: 2_000,
            rhsID: SubscriptionProductID.plusYearly, rhsPrice: 1_000
        ))
        XCTAssertTrue(SubscriptionStore.productComesBefore(
            lhsID: SubscriptionProductID.proMonthly, lhsPrice: 1_000,
            rhsID: SubscriptionProductID.proMonthly, rhsPrice: 2_000
        ))
    }

    func testPurchaseFailureRestoresBusyStateAndShowsProviderMessage() async {
        let store = SubscriptionStore(automaticallyRefresh: false)

        await store.performPurchase { throw TestError.unavailable }

        XCTAssertFalse(store.isPurchasing)
        XCTAssertEqual(store.message, TestError.unavailable.localizedDescription)
        XCTAssertEqual(store.currentPlan, .standard)
    }

    func testRestoreFailureRestoresLoadingStateAndShowsStableMessage() async {
        let store = SubscriptionStore(automaticallyRefresh: false)

        await store.restorePurchases { throw TestError.unavailable }

        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.message, "購入履歴を復元できませんでした。通信状況を確認して、もう一度お試しください。")
        XCTAssertEqual(store.currentPlan, .standard)
    }
}
