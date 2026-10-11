import RevenueCat
import SwiftUI

struct SubscriptionPlansView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsTermsOfUse = false
    @State private var showsPrivacyPolicy = false
    /// Presented by the paywall gate: no way to dismiss it without a plan.
    var isBlocking = false

    init(isBlocking: Bool = false) {
        self.isBlocking = isBlocking
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    currentPlanHeader
                    planCard(plan: .standard, subtitle: store.paywallEnabled ? "学習の基本プラン" : "ずっと無料", features: standardFeatures)
                    planCard(plan: .plus, subtitle: "学習をもっと深く", features: plusFeatures)
                    planCard(plan: .pro, subtitle: "難関課題・研究に", features: proFeatures)

                    if isBlocking { PaywallExits() }

                    Button("購入履歴を復元") {
                        Task { await store.restorePurchases() }
                    }
                    .disabled(store.isLoading || store.isPurchasing)

                    Text("購入はApple IDに設定したお支払い方法で行われます。サブスクリプションは解約するまで自動更新され、Apple IDの設定からいつでも管理できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // App Store Review Guideline 3.1.2 requires an
                    // auto-renewable subscription's purchase screen to link
                    // to both the Terms of Use (EULA) and Privacy Policy,
                    // not just list them elsewhere in the app.
                    HStack(spacing: 16) {
                        Button("利用規約") { showsTermsOfUse = true }
                        Button("プライバシーポリシー") { showsPrivacyPolicy = true }
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("プラン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isBlocking {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                    }
                }
            }
            .overlay {
                if store.isLoading && store.packages.isEmpty {
                    ProgressView("プランを読み込み中…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Studiquo", isPresented: messageIsPresented) {
                Button("OK") { store.message = nil }
            } message: {
                Text(store.message ?? "")
            }
            .sheet(isPresented: $showsTermsOfUse) {
                TermsOfUseView()
            }
            .sheet(isPresented: $showsPrivacyPolicy) {
                PrivacyPolicyView()
            }
            .task { await store.refresh() }
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )
    }

    private var currentPlanHeader: some View {
        VStack(spacing: 6) {
            Text("現在のプラン")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(store.currentPlan.title)
                .font(.largeTitle.bold())
            if store.purchasedPlan != .free {
                Text("購入内容はApp Storeからいつでも管理できます")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Feature copy

    /// Pulled from `AIModelCatalog` rather than hardcoded, so the models
    /// listed here can never drift from the ones the chat model picker (and
    /// the Worker's own plan gate) actually offer.
    private var standardFeatures: [String] {
        let models = AIModelCatalog.offered.filter { $0.requiredPlan == .standard }.map(\.displayName)
        return ["月30 AIクレジット", models.joined(separator: "・"), "資料作成・共同編集は無制限"]
    }

    private var plusFeatures: [String] {
        return ["月750 AIクレジット", "GoogleのAIモデル"]
    }

    private var proFeatures: [String] {
        return ["月2,000 AIクレジット", "GoogleのAIモデル"]
    }

    private func planCard(plan: StudiquoPlan, subtitle: String, features: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title).font(.title2.bold())
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if store.currentPlan == plan {
                    Text("利用中")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            ForEach(features, id: \.self) { feature in
                Label(feature, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary, Color.accentColor)
            }

            if plan == .standard && !store.paywallEnabled {
                Text("無料")
                    .font(.headline)
            } else if store.packages(for: plan).isEmpty {
                Text("App Storeで準備中")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.packages(for: plan), id: \.identifier) { package in
                    purchaseButton(package, plan: plan)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(store.currentPlan == plan ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: store.currentPlan == plan ? 2 : 1)
        }
    }

    private func purchaseButton(_ package: Package, plan: StudiquoPlan) -> some View {
        let isYearly = package.storeProduct.productIdentifier.hasSuffix(".yearly")
        return Button {
            Task { await store.purchase(package) }
        } label: {
            HStack {
                Text(Self.periodLabel(for: package, isYearly: isYearly))
                Spacer()
                Text(package.storeProduct.localizedPriceString)
                Text(isYearly ? "／年" : "／月")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isPurchasing || store.purchasedPlan == plan)
    }

    /// "7日間無料のあと 年額" when the App Store product carries a free-trial
    /// introductory offer the student is still eligible for; otherwise
    /// "年額"/"月額". The trial itself is configured in App Store Connect.
    private static func periodLabel(for package: Package, isYearly: Bool) -> String {
        let base = isYearly ? "年額" : "月額"
        guard let offer = package.storeProduct.introductoryDiscount, offer.paymentMode == .freeTrial else { return base }
        let period = offer.subscriptionPeriod
        let days: Int = switch period.unit {
        case .day: period.value
        case .week: period.value * 7
        case .month: period.value * 30
        case .year: period.value * 365
        @unknown default: period.value
        }
        return "\(days)日間無料のあと \(base)"
    }
}

/// What a student can still do from the blocking paywall besides buying:
/// reload the plan (a purchase or grant may not have reached the Worker yet),
/// sign out, or delete the account. Without these the paywall would be a
/// dead end for anyone it shows to by mistake, and App Store Review
/// Guideline 5.1.1(v) requires account deletion to stay reachable in-app.
private struct PaywallExits: View {
    @EnvironmentObject private var store: SubscriptionStore
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var showsAccountDeletion = false

    var body: some View {
        VStack(spacing: 10) {
            Button("プランを再読み込み") {
                Task { await store.refresh() }
            }
            .disabled(store.isLoading || store.isPurchasing)
            HStack(spacing: 16) {
                Button("ログアウト") { authentication.logout() }
                Button(AccountDeletionUI.accountButtonTitle, role: .destructive) { showsAccountDeletion = true }
            }
            .font(.footnote)
        }
        .sheet(isPresented: $showsAccountDeletion) {
            DeleteAccountView()
        }
    }
}

/// Blocks the app behind the plans screen when the paywall is on and the
/// account has no plan. Never shows while `PaywallConfiguration.isEnabled`
/// is false, or while the plan is still unknown (offline launch).
struct PaywallGate: ViewModifier {
    @EnvironmentObject private var store: SubscriptionStore

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: .constant(store.requiresSubscription)) {
            SubscriptionPlansView(isBlocking: true)
                .environmentObject(store)
                .interactiveDismissDisabled()
        }
    }
}

#if DEBUG
/// DEBUG builds only: lets the paywall be looked at without App Store
/// products or a Worker that has PAYWALL_ENABLED. Not compiled into release.
struct PaywallDebugSection: View {
    @AppStorage(PaywallConfiguration.debugEnabledKey) private var enabled = false
    @AppStorage(PaywallConfiguration.debugServerPlanKey) private var serverPlan = ""

    var body: some View {
        Section {
            Toggle("有料Standardを有効にする", isOn: $enabled)
            Picker("サーバーのプラン", selection: $serverPlan) {
                Text("実サーバーに聞く").tag("")
                Text("free(ペイウォールが出る)").tag("free")
                Text("standard(既存ユーザー相当)").tag("standard")
            }
        } header: {
            Text("開発用(UI確認用)")
        } footer: {
            Text("DEBUGビルドだけの項目です。変更はアプリを再起動すると反映されます。")
        }
    }
}
#endif
