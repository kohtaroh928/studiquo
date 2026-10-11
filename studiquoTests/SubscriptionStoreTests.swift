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

    func testSignOutForgetsThePreviousAccountsPlan() async {
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { .standard })
        await store.restorePurchases { throw TestError.unavailable }
        store.resetForSignOut()
        XCTAssertEqual(store.currentPlan, .free)
        XCTAssertFalse(store.hasResolvedPlan)
        XCTAssertFalse(store.requiresSubscription)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "SubscriptionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRefreshCachesAPaidServerPlanAndAnOfflineLaunchUsesIt() async {
        let defaults = isolatedDefaults()
        let online = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { .standard }, defaults: defaults, accountIDProvider: { "acct" })
        await online.refresh()
        XCTAssertEqual(online.currentPlan, .standard)

        let offline = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { nil }, defaults: defaults, accountIDProvider: { "acct" })
        XCTAssertEqual(offline.currentPlan, .standard)
        XCTAssertTrue(offline.hasResolvedPlan)
        XCTAssertFalse(offline.requiresSubscription)
    }

    func testAFreeAnswerIsNeverCachedAndClearsAStaleEntry() async {
        let defaults = isolatedDefaults()
        defaults.set(["account": "acct", "plan": StudiquoPlan.standard.rawValue], forKey: SubscriptionStore.cachedServerPlanKey)
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { .free }, defaults: defaults, accountIDProvider: { "acct" })
        await store.refresh()
        XCTAssertNil(defaults.object(forKey: SubscriptionStore.cachedServerPlanKey))
        XCTAssertTrue(store.requiresSubscription)
    }

    func testSignOutClearsTheCachedPlan() async {
        let defaults = isolatedDefaults()
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { .standard }, defaults: defaults, accountIDProvider: { "acct" })
        await store.refresh()
        store.resetForSignOut()
        XCTAssertNil(defaults.object(forKey: SubscriptionStore.cachedServerPlanKey))
        XCTAssertFalse(store.requiresSubscription)
    }

    func testPaywallIsOffWhenDisabledEvenWithACachedPlan() {
        let defaults = isolatedDefaults()
        defaults.set(["account": "acct", "plan": StudiquoPlan.free.rawValue], forKey: SubscriptionStore.cachedServerPlanKey)
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: false, defaults: defaults)
        XCTAssertEqual(store.currentPlan, .standard)
        XCTAssertFalse(store.requiresSubscription)
    }

    func testARefreshThatFinishesAfterSignOutWritesNothing() async {
        let defaults = isolatedDefaults()
        var store: SubscriptionStore!
        store = SubscriptionStore(
            automaticallyRefresh: false, paywallEnabled: true,
            serverPlanProvider: { .standard }, defaults: defaults
        )
        // Sign out while the lookup is waiting for the identity.
        store.waitForIdentity = { @MainActor in store.resetForSignOut() }
        await store.refresh()
        XCTAssertNil(defaults.object(forKey: SubscriptionStore.cachedServerPlanKey))
        XCTAssertFalse(store.hasResolvedPlan)
        XCTAssertFalse(store.requiresSubscription)
    }

    func testRefreshIfStaleDoesNothingWhileThePaywallIsOff() async {
        var asked = false
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: false, serverPlanProvider: { asked = true; return .free })
        await store.refreshIfStale()
        XCTAssertFalse(asked)
    }

    func testACachedPlanIsIgnoredForADifferentAccount() {
        let defaults = isolatedDefaults()
        defaults.set(["account": "someone-else", "plan": StudiquoPlan.standard.rawValue], forKey: SubscriptionStore.cachedServerPlanKey)
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { nil }, defaults: defaults, accountIDProvider: { "acct" })
        XCTAssertEqual(store.currentPlan, .free)
        XCTAssertFalse(store.hasResolvedPlan)
    }

    func testNothingIsCachedWhileTheAccountIsUnknown() async {
        let defaults = isolatedDefaults()
        let store = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { .standard }, defaults: defaults, accountIDProvider: { nil })
        await store.refresh()
        XCTAssertNil(defaults.object(forKey: SubscriptionStore.cachedServerPlanKey))
    }

    func testConfirmPlanOnServerStopsOnceTheServerCatchesUp() async {
        var answers: [StudiquoPlan] = [.free, .free, .standard]
        var asked = 0
        let store = SubscriptionStore(
            automaticallyRefresh: false, paywallEnabled: true,
            serverPlanProvider: { asked += 1; return answers.isEmpty ? nil : answers.removeFirst() },
            defaults: isolatedDefaults(), accountIDProvider: { "acct" }
        )
        store.activationDelays = Array(repeating: .milliseconds(1), count: 5)
        store.setPurchasedPlanForTesting(.standard)
        await store.confirmPlanOnServer()
        XCTAssertEqual(asked, 3)
        XCTAssertFalse(store.isActivatingPlan)
        XCTAssertEqual(store.currentPlan, .standard)
    }

    func testConfirmPlanOnServerDoesNothingWithoutAPurchaseOrWithThePaywallOff() async {
        var asked = 0
        let on = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: true, serverPlanProvider: { asked += 1; return .free }, defaults: isolatedDefaults())
        on.activationDelays = [.milliseconds(1)]
        await on.confirmPlanOnServer()
        let off = SubscriptionStore(automaticallyRefresh: false, paywallEnabled: false, serverPlanProvider: { asked += 1; return .free })
        off.setPurchasedPlanForTesting(.standard)
        await off.confirmPlanOnServer()
        XCTAssertEqual(asked, 0)
    }
}
