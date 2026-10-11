import Foundation
import RevenueCat

/// Which paid tier the signed-in student is on.
///
/// `rawValue` ordering is load-bearing: `Comparable` is used throughout the
/// app (model-picker gating, storage-limit lookup) to mean "at least this
/// plan", so a newly-added plan must slot in at the correct rank, not just
/// get appended.
enum StudiquoPlan: Int, CaseIterable, Comparable, Sendable {
    /// No active subscription and no grandfathered access. Only reachable
    /// while `PaywallConfiguration.isEnabled`; otherwise everyone is at least
    /// `.standard`.
    case free = 0
    case standard = 1
    case plus = 2
    case pro = 3

    static func < (lhs: StudiquoPlan, rhs: StudiquoPlan) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .free: "未加入"
        case .standard: "Standard"
        case .plus: "Plus"
        case .pro: "Pro"
        }
    }
}

/// App Store product identifiers. RevenueCat's dashboard is configured to
/// resell exactly these as `Package`s, so this mapping still needs to exist
/// on the client — kept hand-synced with `PRODUCT_PLAN_MAP` in
/// `mcp-server/src/entitlements.js` on the server, the same "two places kept
/// in step by hand" pattern `legal.js`'s own doc comment describes.
enum SubscriptionProductID {
    static let standardYearly = "com.yabuko.studiquo.standard.yearly"
    static let plusMonthly = "com.yabuko.studiquo.plus.monthly"
    static let plusYearly = "com.yabuko.studiquo.plus.yearly"
    static let proMonthly = "com.yabuko.studiquo.pro.monthly"
    static let proYearly = "com.yabuko.studiquo.pro.yearly"

    static let all: Set<String> = [standardYearly, plusMonthly, plusYearly, proMonthly, proYearly]

    static func plan(for productID: String) -> StudiquoPlan? {
        switch productID {
        case standardYearly: .standard
        case plusMonthly, plusYearly: .plus
        case proMonthly, proYearly: .pro
        default: nil
        }
    }
}

/// RevenueCat entitlement identifiers, as configured in the RevenueCat
/// dashboard's Entitlements tab — distinct from the App Store product IDs
/// above. `CustomerInfo.entitlements.active` is keyed by these strings, not
/// by product ID (one entitlement can be granted by several products, e.g.
/// monthly or yearly). Hand-synced with the dashboard, same as
/// `SubscriptionProductID` is hand-synced with App Store Connect.
enum SubscriptionEntitlementID {
    static let standard = "standard"
    static let plus = "plus"
    static let pro = "pro"
}

/// Whether Standard is a paid plan. Off until the App Store products, the
/// RevenueCat entitlement and the Worker's `PAYWALL_ENABLED` are all in place
/// (docs/releases/paid-standard-plan.md). While it is off nothing changes for
/// anyone: every signed-in account is treated as Standard, no paywall is
/// shown and no Standard purchase button is offered. Delete this flag, and
/// the `.standard` fallbacks it guards, after launch.
enum PaywallConfiguration {
    static let isEnabled = false
}

/// RevenueCat configuration. The public SDK key is safe to ship inside the
/// app binary (unlike a server secret key) — it only identifies which
/// RevenueCat project this app talks to.
///
/// *** ACTION REQUIRED ***: `publicAPIKey` below is a placeholder. Create a
/// project in the RevenueCat dashboard (https://app.revenuecat.com), add the
/// App Store app, and copy its "public" API key (Project settings → API
/// keys → Apple App Store) in here before shipping — purchases, restores,
/// and entitlement checks all silently fail against the placeholder.
enum RevenueCatConfiguration {
    static let publicAPIKey = "REVENUECAT_API_KEY_PLACEHOLDER"
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var packages: [Package] = []
    /// What the student may use: the higher of their purchase and the plan
    /// the Worker reports (which includes the grandfathered Standard grant).
    @Published private(set) var currentPlan: StudiquoPlan
    /// What RevenueCat says they bought, ignoring any grandfathered grant.
    @Published private(set) var purchasedPlan: StudiquoPlan = .free
    /// False until the plan is actually known, so a slow or offline launch
    /// never flashes the paywall at someone who is entitled.
    @Published private(set) var hasResolvedPlan = false
    @Published private(set) var activeEntitlementIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published var message: String?

    /// Starts the RevenueCat SDK. Call exactly once, as early as possible
    /// during app launch (see `StudiquoApp.init`) — every `Purchases.shared`
    /// call below (including the one `SubscriptionStore.init` itself makes)
    /// assumes this has already run.
    static func configureSDK() {
        #if DEBUG
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: RevenueCatConfiguration.publicAPIKey)
    }

    let paywallEnabled: Bool
    private let serverPlanProvider: () async -> StudiquoPlan?
    private var serverPlan: StudiquoPlan?

    /// True when the paywall must block the app: the paywall is on, the plan
    /// is known, and it is `.free`.
    var requiresSubscription: Bool { paywallEnabled && hasResolvedPlan && currentPlan == .free }

    init(
        automaticallyRefresh: Bool = true,
        paywallEnabled: Bool = PaywallConfiguration.isEnabled,
        serverPlanProvider: @escaping () async -> StudiquoPlan? = { await ServerPlanClient.fetch() }
    ) {
        self.paywallEnabled = paywallEnabled
        self.serverPlanProvider = serverPlanProvider
        self.currentPlan = paywallEnabled ? .free : .standard
        if automaticallyRefresh {
            Task { await refresh() }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            packages = (offerings.current?.availablePackages ?? []).sorted(by: Self.packageSort)
            let info = try await Purchases.shared.customerInfo()
            apply(info)
        } catch {
            message = "プラン情報を読み込めませんでした。通信状況を確認して、もう一度お試しください。"
        }
        if paywallEnabled, let fetched = await serverPlanProvider() {
            serverPlan = fetched
            recomputePlan()
        }
    }

    func purchase(_ package: Package) async {
        await performPurchase {
            let result = try await Purchases.shared.purchase(package: package)
            return (result.userCancelled, result.customerInfo)
        }
    }

    func performPurchase(
        operation: () async throws -> (userCancelled: Bool, customerInfo: CustomerInfo)
    ) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await operation()
            guard !result.userCancelled else { return }
            apply(result.customerInfo)
            message = "\(purchasedPlan.title)プランが利用できるようになりました。"
        } catch {
            message = error.localizedDescription
        }
    }

    func restorePurchases() async {
        await restorePurchases {
            try await Purchases.shared.restorePurchases()
        }
    }

    func restorePurchases(operation: () async throws -> CustomerInfo) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await operation()
            apply(info)
            message = purchasedPlan == .free
                ? "復元できる有効なサブスクリプションはありませんでした。"
                : "\(purchasedPlan.title)プランを復元しました。"
        } catch {
            message = "購入履歴を復元できませんでした。通信状況を確認して、もう一度お試しください。"
        }
    }

    func packages(for plan: StudiquoPlan) -> [Package] {
        packages.filter { SubscriptionProductID.plan(for: $0.storeProduct.productIdentifier) == plan }
    }

    /// Maps RevenueCat's active entitlements onto `StudiquoPlan` — the
    /// highest plan among every active entitlement wins, mirroring the old
    /// StoreKit-era `updateEntitlements()`'s "highest active product wins"
    /// behaviour. Entitlement identifiers (not product IDs) are what
    /// RevenueCat actually grants, so this is the only place that needs to
    /// know the dashboard's entitlement naming.
    private func apply(_ info: CustomerInfo) {
        let active = Set(info.entitlements.active.keys)
        activeEntitlementIDs = active
        purchasedPlan = Self.plan(forActiveEntitlementIDs: active)
        recomputePlan()
    }

    private func recomputePlan() {
        currentPlan = Self.effectivePlan(purchased: purchasedPlan, server: serverPlan, paywallEnabled: paywallEnabled)
        hasResolvedPlan = serverPlan != nil || purchasedPlan >= .standard || !paywallEnabled
    }

    /// Highest plan among every active entitlement; `.free` when none.
    static func plan(forActiveEntitlementIDs active: Set<String>) -> StudiquoPlan {
        active.contains(SubscriptionEntitlementID.pro) ? .pro
            : active.contains(SubscriptionEntitlementID.plus) ? .plus
            : active.contains(SubscriptionEntitlementID.standard) ? .standard
            : .free
    }

    /// With the paywall off everyone is at least Standard (the free-Standard
    /// behaviour). With it on, the plan is the better of the purchase and the
    /// Worker's answer, and `.free` while the Worker has not answered.
    static func effectivePlan(purchased: StudiquoPlan, server: StudiquoPlan?, paywallEnabled: Bool) -> StudiquoPlan {
        guard paywallEnabled else { return max(purchased, .standard) }
        return max(purchased, server ?? .free)
    }

    private static func packageSort(_ lhs: Package, _ rhs: Package) -> Bool {
        productComesBefore(
            lhsID: lhs.storeProduct.productIdentifier,
            lhsPrice: lhs.storeProduct.price,
            rhsID: rhs.storeProduct.productIdentifier,
            rhsPrice: rhs.storeProduct.price
        )
    }

    static func productComesBefore(
        lhsID: String,
        lhsPrice: Decimal,
        rhsID: String,
        rhsPrice: Decimal
    ) -> Bool {
        let lhsPlan = SubscriptionProductID.plan(for: lhsID) ?? .free
        let rhsPlan = SubscriptionProductID.plan(for: rhsID) ?? .free
        if lhsPlan != rhsPlan { return lhsPlan < rhsPlan }

        let lhsYearly = lhsID.hasSuffix(".yearly")
        let rhsYearly = rhsID.hasSuffix(".yearly")
        return lhsYearly == rhsYearly ? lhsPrice < rhsPrice : !lhsYearly
    }
}

/// Asks the Worker which plan this account has. The app sees purchases
/// through RevenueCat but not the server-only grandfathered-Standard grant,
/// so with the paywall on this is what keeps existing users in. `nil` on any
/// failure — the caller then keeps what it already knows.
enum ServerPlanClient {
    static func fetch() async -> StudiquoPlan? {
        guard let baseURL = WorkerAIProvider().baseURL else { return nil }
        var request = URLRequest(url: baseURL.appending(path: "api/plan"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return plan(fromResponse: data)
    }

    static func plan(fromResponse data: Data) -> StudiquoPlan? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["plan"] as? String else { return nil }
        switch name {
        case "free": return .free
        case "standard": return .standard
        case "plus": return .plus
        case "pro": return .pro
        default: return nil
        }
    }
}
