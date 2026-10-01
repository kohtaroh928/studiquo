import Foundation
import StoreKit

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

@MainActor
final class SubscriptionStore: ObservableObject {
    enum StoreError: LocalizedError {
        case failedVerification

        var errorDescription: String? {
            switch self {
            case .failedVerification:
                "App Storeによる購入情報の確認に失敗しました。"
            }
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var currentPlan: StudiquoPlan = .standard
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published var message: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactionUpdates()
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: SubscriptionProductID.all)
                .sorted(by: Self.productSort)
            await updateEntitlements()
        } catch {
            message = "プラン情報を読み込めませんでした。通信状況を確認して、もう一度お試しください。"
        }
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                await updateEntitlements()
                await transaction.finish()
                message = "(currentPlan.title)プランが利用できるようになりました。"
            case .pending:
                message = "購入の承認を待っています。承認後、自動的にプランが反映されます。"
            case .userCancelled:
                break
            @unknown default:
                message = "購入を完了できませんでした。時間をおいてもう一度お試しください。"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await updateEntitlements()
            message = currentPlan == .standard
                ? "復元できる有効なサブスクリプションはありませんでした。"
                : "(currentPlan.title)プランを復元しました。"
        } catch {
            message = "購入履歴を復元できませんでした。通信状況を確認して、もう一度お試しください。"
        }
    }

    func products(for plan: StudiquoPlan) -> [Product] {
        products.filter { SubscriptionProductID.plan(for: $0.id) == plan }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.verified(update)
                    await self.updateEntitlements()
                    await transaction.finish()
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private func updateEntitlements() async {
        var activeProductIDs: Set<String> = []
        var highestPlan = StudiquoPlan.standard

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  SubscriptionProductID.all.contains(transaction.productID) else { continue }

            activeProductIDs.insert(transaction.productID)
            if let plan = SubscriptionProductID.plan(for: transaction.productID) {
                highestPlan = max(highestPlan, plan)
            }
        }

        purchasedProductIDs = activeProductIDs
        currentPlan = highestPlan
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw StoreError.failedVerification
        }
    }

    private static func productSort(_ lhs: Product, _ rhs: Product) -> Bool {
        let lhsPlan = SubscriptionProductID.plan(for: lhs.id) ?? .standard
        let rhsPlan = SubscriptionProductID.plan(for: rhs.id) ?? .standard
        if lhsPlan != rhsPlan { return lhsPlan < rhsPlan }

        let lhsYearly = lhs.id.hasSuffix(".yearly")
        let rhsYearly = rhs.id.hasSuffix(".yearly")
        return lhsYearly == rhsYearly ? lhs.displayPrice < rhs.displayPrice : !lhsYearly
    }
}
