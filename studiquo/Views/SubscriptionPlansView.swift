import StoreKit
import SwiftUI

struct SubscriptionPlansView: View {
    @StateObject private var store = SubscriptionStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    currentPlanHeader
                    planCard(
                        plan: .standard,
                        subtitle: "ずっと無料",
                        features: ["月30 AIクレジット", "Gemini 3.5 Flash-Lite", "資料作成・共同編集は無制限"]
                    )
                    planCard(
                        plan: .plus,
                        subtitle: "学習をもっと深く",
                        features: ["月750 AIクレジット", "Haiku・Terra・Sonnet・GPT-6 Sol", "5GBの個人用クラウド同期"]
                    )
                    planCard(
                        plan: .pro,
                        subtitle: "難関課題・研究に",
                        features: ["月2,000 AIクレジット", "Plusの全モデル＋Opus・GPT-6 Astra", "50GBの個人用クラウド同期"]
                    )

                    Button("購入履歴を復元") {
                        Task { await store.restorePurchases() }
                    }
                    .disabled(store.isLoading || store.isPurchasing)

                    Text("購入はApple IDに設定したお支払い方法で行われます。サブスクリプションは解約するまで自動更新され、Apple IDの設定からいつでも管理できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("プラン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .overlay {
                if store.isLoading && store.products.isEmpty {
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
            if store.currentPlan != .standard {
                Text("購入内容はApp Storeからいつでも管理できます")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
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

            if plan == .standard {
                Text("無料")
                    .font(.headline)
            } else if store.products(for: plan).isEmpty {
                Text("App Storeで準備中")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.products(for: plan), id: \.id) { product in
                    purchaseButton(product, plan: plan)
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

    private func purchaseButton(_ product: Product, plan: StudiquoPlan) -> some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            HStack {
                Text(product.id.hasSuffix(".yearly") ? "年額" : "月額")
                Spacer()
                Text(product.displayPrice)
                if product.id.hasSuffix(".yearly") { Text("／年") } else { Text("／月") }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isPurchasing || store.currentPlan == plan)
    }
}
