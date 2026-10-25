import SwiftUI
import SwiftData

/// New automatic consent is an affirmative decision for this account. The old
/// per-document storage toggle never enables this feature.
@MainActor
struct RAGAutomaticLibraryControls: View {
    let notebooks: [Notebook]
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.name) private var folders: [Folder]
    @State private var service = RAGLibrarySyncService.shared
    @State private var scopeKind = "all"
    @State private var folderID = ""
    @State private var includeFuture = false
    @State private var errorMessage = ""
    @State private var working = false

    private var eligible: [Notebook] {
        let candidates = notebooks.filter { $0.containsPDF && !$0.isTrashed && !$0.isLocked && $0.lockedPDFData == nil && $0.encryptedContent == nil }
        if service.isManaged && service.enabled { return candidates.filter { service.isWithinScope($0) } }
        guard scopeKind == "folder" else { return candidates }
        return candidates.filter { notebook in
            var folder = notebook.folder, visited: Set<String> = []
            while let current = folder {
                guard visited.insert(current.ragID).inserted else { return false }
                if current.ragID == folderID { return true }
                folder = current.parent
            }
            return false
        }
    }
    private var selectedScope: RAGLibrarySyncService.Scope {
        scopeKind == "folder" ? .folder(folderID) : .allPDFs
    }
    var body: some View {
        Group {
        Section("ホームのPDFを自動で検索可能にする") {
            Text("許可した範囲のPDFを、アプリ使用中に小分けで自動登録します。本文・文字認識結果・タイトル・ページ番号をCloudflareへ送信し、本文と検索用データを保存します。質問もCloudflareへ送り、関連する抜粋をOpenAIへ送信して回答します。ロック・暗号化・ゴミ箱の資料と通常の手書きノートは対象外です。")
                .font(.footnote)
            Text("この端末の資料には、別アカウントで保存したものが含まれる場合があります。送信する権限があるPDFだけを対象にしてください。初回の許可で従来の手動検索データは失効し、新しい登録へ切り替わります。")
                .font(.footnote)
            Text("構造解析済みの資料では、見出し、要素の種類・位置、解析方式などの情報もCloudflareへ送信し、本文と一緒に保存します。検索で使う位置情報は出典と共にOpenAIへ送信します。原PDFはこの処理では送信しません。")
                .font(.footnote)
            if !service.isManaged || !service.enabled {
                Picker("登録対象", selection: $scopeKind) {
                    Text("ホームのPDF全体").tag("all")
                    Text("選択したフォルダ").tag("folder")
                }.accessibilityIdentifier("rag-auto-scope")
                if scopeKind == "folder" {
                    Picker("対象フォルダ", selection: $folderID) {
                        Text("フォルダを選択").tag("")
                        ForEach(folders) { Text($0.legacyPath).tag($0.ragID) }
                    }
                }
                Toggle("今後追加するPDFも対象にする", isOn: $includeFuture)
                    .accessibilityIdentifier("rag-auto-future")
                Text("現在の保護されていないPDFは\(eligible.count)件です。対象は下の資料一覧で確認してください。")
                    .font(.caption)
                Button("対象PDFの自動登録を許可") {
                    working = true; errorMessage = ""
                    Task { @MainActor in
                        defer { working = false }
                        do { try await service.grant(scope: selectedScope, includeFuture: includeFuture, context: context, notebooks: notebooks) }
                        catch { errorMessage = L("自動登録を開始できませんでした。通信と送信許可を確認してください。") }
                    }
                }
                .disabled(working || !service.available || !AIDataDisclosure.hasBeenAcknowledged || (scopeKind == "folder" && folderID.isEmpty))
                .accessibilityIdentifier("rag-auto-grant")
            } else {
                Text("許可した範囲のPDFを自動登録しています。未登録の資料は、まだ回答の検索対象になりません。")
                    .font(.footnote)
                Button("自動登録と資料検索の許可を取り消す", role: .destructive) {
                    Task { @MainActor in await service.revoke() }
                }.accessibilityIdentifier("rag-auto-revoke")
                Text("取り消すとこの端末の登録・検索を直ちに止めます。通信回復後にサーバーへ反映し、保存データの削除を再試行します。送信済みの抜粋は回収できません。")
                    .font(.caption)
            }
            if !service.available {
                Text("自動登録は現在利用できません。通常のAIチャットは利用できます。")
                    .font(.footnote)
            }
            if service.busy { ProgressView("PDFの登録を処理中") }
            Text("登録済み：\(service.registeredCount)件・検索可能：\(service.searchableCount)件・検索反映待ち：\(service.waitingCount)件・未登録：\(service.pendingCount)件")
                .font(.caption)
                .accessibilityIdentifier("rag-auto-progress")
            if let message = service.errorMessage { Text(message).font(.footnote) }
            if !errorMessage.isEmpty { Text(errorMessage).font(.footnote) }
        }
        if service.isManaged {
            Section("対象PDF・除外") {
                ForEach(eligible) { notebook in
                    HStack {
                        Text(notebook.title)
                        Spacer()
                        if service.isExcluded(notebook) || service.sourceID(for: notebook) == nil {
                            Button("このPDFを再許可") {
                                Task { await service.manualEnqueue(notebook, context: context) }
                            }.accessibilityIdentifier("rag-auto-include-\(notebook.ragDocumentID)")
                        } else {
                            Button("検索から除外", role: .destructive) {
                                service.invalidate(notebook: notebook, state: "excluded")
                            }.accessibilityIdentifier("rag-auto-exclude-\(notebook.ragDocumentID)")
                        }
                    }
                }
                Text("除外の反映を待っている間は資料検索を停止します。必要な資料だけを再許可する場合は「このPDFを再許可」を選んでください。")
                    .font(.caption)
            }
        }
        }
        .task {
            for folder in folders { folder.ensureRAGIdentity() }
            await service.refreshAvailability()
        }
    }
}

/// Keep library reconciliation out of ContentView's large body. Registration
/// runs in the foreground and reacts to lightweight model metadata changes.
@MainActor
struct RAGLibrarySyncModifier: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: \Notebook.updatedAt) private var notebooks: [Notebook]
    private var signal: String {
        notebooks.map { "\($0.ragID):\($0.updatedAt.timeIntervalSince1970):\($0.isLocked):\($0.isTrashed):\($0.containsPDF):\($0.lockedPDFData != nil):\($0.encryptedContent != nil):\($0.folder?.ragID ?? ""):\($0.pages?.count ?? 0)" }.joined(separator: "|") + phase.descriptionForRAG
    }
    func body(content: Content) -> some View {
        content
            .task(id: signal) {
                RAGLibrarySyncService.shared.setForeground(phase == .active)
                guard phase == .active else { return }
                await RAGLibrarySyncService.shared.reconcile(notebooks: notebooks, context: context)
            }
            .onChange(of: phase) { _, phase in
                RAGLibrarySyncService.shared.setForeground(phase == .active)
            }
            .onReceive(NotificationCenter.default.publisher(for: RAGLibrarySyncService.changeNotification)) { _ in
                guard phase == .active else { return }
                Task { @MainActor in
                    await RAGLibrarySyncService.shared.reconcile(notebooks: notebooks, context: context)
                }
            }
    }
}
private extension ScenePhase {
    var descriptionForRAG: String { self == .active ? "active" : (self == .inactive ? "inactive" : "background") }
}
