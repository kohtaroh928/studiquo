import SwiftUI

/// One place for the terms, the privacy policy and the data-sharing explanations. The permission
/// screens keep only a short summary and link here for the full text.
struct LegalHubView: View {
    private enum Destination: String, Identifiable {
        case terms, privacy, ai, rag
        var id: String { rawValue }
    }
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination?
    @State private var aiAllowed = AIDataDisclosure.hasBeenAcknowledged
    @State private var ragAllowed = RAGConsent.isGranted

    var body: some View {
        NavigationStack {
            List {
                Section("規約") {
                    Button("利用規約") { destination = .terms }
                    Button("プライバシーポリシー") { destination = .privacy }
                }
                Section {
                    Button("AI機能とデータ送信について") { destination = .ai }
                    LabeledContent("AI機能の許可", value: aiAllowed ? "許可済み" : "未許可")
                } header: {
                    Text("AI機能")
                } footer: {
                    Text("許可はいつでも取り消せます。取り消しても、ノートなどの基本機能は使えます。")
                }
                Section {
                    Button("資料検索のデータ送信について") { destination = .rag }
                    LabeledContent("資料検索の許可", value: ragAllowed ? "許可済み" : "未許可")
                } header: {
                    Text("資料検索")
                } footer: {
                    Text("許可の変更や、保存した検索データの削除は、設定の「資料検索の保存データと許可」で行えます。")
                }
            }
            .navigationTitle("規約・プライバシー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .sheet(item: $destination, onDismiss: refresh) { item in
                switch item {
                case .terms: TermsOfUseView()
                case .privacy: PrivacyPolicyView()
                case .ai:
                    AIDataDisclosureView(onAcknowledge: { band in
                        AIDataDisclosure.acknowledge(ageBand: band); destination = nil
                    }, onDecline: {
                        AIDataDisclosure.revoke(); destination = nil
                    })
                case .rag: RAGDisclosureView()
                }
            }
            .onAppear(perform: refresh)
        }
    }
    private func refresh() {
        aiAllowed = AIDataDisclosure.hasBeenAcknowledged
        ragAllowed = RAGConsent.isGranted
    }
}

/// The full document-search data explanation (the text lives in `RAGDisclosureText`).
struct RAGDisclosureView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("資料検索のデータ送信について").font(.title3.bold())
                    Text(RAGDisclosureText.automaticSummary).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(RAGDisclosureText.automaticDetails.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.subheadline)
                    }
                    Divider()
                    Text("従来の手動登録").font(.headline)
                    Text(RAGDisclosureText.manualSummary).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(RAGDisclosureText.manualDetails.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.subheadline)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("rag-disclosure-full")
            .navigationTitle("資料検索のデータ送信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

/// A short summary with a link to the full text, shown where document search is allowed.
struct RAGDisclosureSummary: View {
    let summary: String
    let identifier: String
    @State private var showsFull = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).font(.footnote)
            Button("詳細を見る") { showsFull = true }
                .font(.footnote)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(identifier)
        }
        .sheet(isPresented: $showsFull) { RAGDisclosureView() }
    }
}
