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
        XCTAssertEqual(SubscriptionProductID.plan(for: SubscriptionProductID.standardYearly), .standard)
        XCTAssertNil(SubscriptionProductID.plan(for: "unknown.product"))
    }

    func testHighestActiveEntitlementWins() {
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: []), .free)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["standard"]), .standard)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["standard", "plus"]), .plus)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["plus"]), .plus)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["pro"]), .pro)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["plus", "pro"]), .pro)
        XCTAssertEqual(SubscriptionStore.plan(forActiveEntitlementIDs: ["future-entitlement"]), .free)
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

    // MARK: Paid Standard / paywall switch

    func testPaywallOffTreatsEveryoneAsAtLeastStandard() {
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .free, server: nil, paywallEnabled: false), .standard)
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .free, server: .free, paywallEnabled: false), .standard)
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .pro, server: nil, paywallEnabled: false), .pro)
    }

    func testPaywallOnTakesTheBetterOfPurchaseAndServer() {
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .free, server: nil, paywallEnabled: true), .free)
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .free, server: .standard, paywallEnabled: true), .standard)
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .standard, server: .free, paywallEnabled: true), .standard)
        XCTAssertEqual(SubscriptionStore.effectivePlan(purchased: .plus, server: .standard, paywallEnabled: true), .plus)
    }

    func testThePaywallShipsOff() {
        XCTAssertFalse(PaywallConfiguration.isEnabled)
        let store = SubscriptionStore(automaticallyRefresh: false)
        XCTAssertFalse(store.paywallEnabled)
        XCTAssertEqual(store.currentPlan, .standard)
        XCTAssertFalse(store.requiresSubscription)
    }

    func testPaywallOnStartsUnresolvedSoItNeverFlashesAtAnEntitledStudent() {
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { nil })
        XCTAssertEqual(store.currentPlan, .free)
        XCTAssertFalse(store.hasResolvedPlan)
        XCTAssertFalse(store.requiresSubscription)
    }

    func testServerPlanResponseParsing() {
        func plan(_ json: String) -> StudiquoPlan? { ServerPlanClient.plan(fromResponse: Data(json.utf8)) }
        XCTAssertEqual(plan(#"{"plan":"free","paywallRequired":true}"#), .free)
        XCTAssertEqual(plan(#"{"plan":"standard"}"#), .standard)
        XCTAssertEqual(plan(#"{"plan":"pro"}"#), .pro)
        XCTAssertNil(plan(#"{"plan":"platinum"}"#))
        XCTAssertNil(plan("not json"))
    }
}
