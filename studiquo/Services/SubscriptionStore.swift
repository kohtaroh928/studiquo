import Foundation
import RevenueCat

/// Which paid tier the signed-in student is on.
///
/// `rawValue` ordering is load-bearing: `Comparable` is used throughout the
/// app (model-picker gating, storage-limit lookup) to mean "at least this
/// plan", so a newly-added plan must slot in at the correct rank, not just
/// get appended.
enum StudiquoPlan: Int, CaseIterable, Comparable, Sendable {
    case standard = 0
    case plus = 1
    case pro = 2

    static func < (lhs: StudiquoPlan, rhs: StudiquoPlan) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
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
    static let plusMonthly = "com.yabuko.studiquo.plus.monthly"
    static let plusYearly = "com.yabuko.studiquo.plus.yearly"
    static let proMonthly = "com.yabuko.studiquo.pro.monthly"
    static let proYearly = "com.yabuko.studiquo.pro.yearly"

    static let all: Set<String> = [plusMonthly, plusYearly, proMonthly, proYearly]

    static func plan(for productID: String) -> StudiquoPlan? {
        switch productID {
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
    static let plus = "plus"
    static let pro = "pro"
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
    @Published private(set) var currentPlan: StudiquoPlan = .standard
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

    init(automaticallyRefresh: Bool = true) {
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
            message = "\(currentPlan.title)プランが利用できるようになりました。"
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
            message = currentPlan == .standard
                ? "復元できる有効なサブスクリプションはありませんでした。"
                : "\(currentPlan.title)プランを復元しました。"
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
        currentPlan = Self.plan(forActiveEntitlementIDs: active)
    }

    static func plan(forActiveEntitlementIDs active: Set<String>) -> StudiquoPlan {
        active.contains(SubscriptionEntitlementID.pro) ? .pro
            : active.contains(SubscriptionEntitlementID.plus) ? .plus
            : .standard
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
        let lhsPlan = SubscriptionProductID.plan(for: lhsID) ?? .standard
        let rhsPlan = SubscriptionProductID.plan(for: rhsID) ?? .standard
        if lhsPlan != rhsPlan { return lhsPlan < rhsPlan }

        let lhsYearly = lhsID.hasSuffix(".yearly")
        let rhsYearly = rhsID.hasSuffix(".yearly")
        return lhsYearly == rhsYearly ? lhsPrice < rhsPrice : !lhsYearly
    }
}
