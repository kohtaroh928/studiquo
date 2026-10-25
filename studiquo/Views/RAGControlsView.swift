import SwiftUI
import SwiftData

/// Scoped retrieval and cloud indexing require a separate affirmative decision.
struct RAGControlsView: View {
    @ObservedObject var store: AIChatStore
    @Query private var notebooks: [Notebook]
    @State private var selectedID = ""
    @State private var kind = RAGSearchScope.Kind.library
    @State private var pageNumber = 1
    @State private var showingStructuredImport = false
    @State private var consent = RAGConsent.isGranted
    @State private var busy = false
    @State private var status = ""
    @State private var registration = RAGRegistrationState.unknown
    @State private var reviewNotice = ""
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    private var eligible: [Notebook] { notebooks.filter { !$0.isLocked && $0.lockedPDFData == nil && !$0.isTrashed && $0.encryptedContent == nil } }
    private var selected: Notebook? { eligible.first { $0.ragID == selectedID } }

    var body: some View {
        Form {
            RAGAutomaticLibraryControls(notebooks: notebooks)
            Section("解析済みの資料") {
                Button("解析済みPDFを追加") { showingStructuredImport = true }
                if let selected, selected.ragStructuredData != nil {
                    Text(selected.ragStructuredFingerprint == RAGStructuredAttachment.fingerprint(selected)
                         ? "構造を保持した解析結果を使用します。" : "資料が編集されたため、現在の本文を使用します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !RAGLibrarySyncService.shared.isManaged {
            Section("資料検索のクラウド送信") {
                RAGDetailDisclosure(
                    summary: "選択したノート・PDFの本文などをCloudflareへ送信して検索用データを作り、回答のため関連する抜粋をOpenAIへ送信します。送信内容と保存期間は「詳細」で確認できます。",
                    details: [
                        "選択したノート・PDFの本文、文字認識した本文、タイトル、ページ番号をCloudflareへ送信します。構造解析済みの資料では、見出し、要素の種類・位置、解析方式などの情報も送信し、本文と一緒に保存します。CloudflareのAIで検索用データを作成し、質問との関連度を評価します。本文と検索用データは資料の検索データ削除またはアカウント削除まで保存されます。検索時には質問もCloudflareへ送り、曖昧な質問では直前の質問も検索に使います。検索で見つかった抜粋と出典の位置情報は回答のためOpenAIへ送信します。原PDFはこの処理では送信しません。保護されたノートは対象外です。"
                    ],
                    identifier: "rag-cloud-detail")
                Toggle("資料検索の保存・AI処理を許可する", isOn: $consent)
                    .onChange(of: consent) { _, value in
                        if value { RAGConsent.grant() } else { RAGConsent.revoke(); store.ragScope = nil; cancelOperation() }
                    }
                Text("許可を取り消しても保存済みの検索データは残ります。下の削除操作で資料ごとに削除できます。")
                    .font(.caption)
            }
            }
            Section("検索範囲") {
                if !RAGLibrarySyncService.shared.isManaged && RAGDeletionQueue.hasUnresolvedLegacyDeletions() {
                    Text("以前の削除予約の送信先を確認できないため、資料検索を停止しています。予約は保持され、接続先を切り替えても自動で送信されません。データやアプリを削除せず、サポートにお問い合わせください。安全に復旧する操作は現在この画面にはありません。")
                        .font(.footnote)
                }
                Picker("資料", selection: $selectedID) {
                    Text("資料を選択").tag("")
                    ForEach(eligible) { Text($0.title).tag($0.ragID) }
                }
                Picker("範囲", selection: $kind) {
                    Text("現在のページ").tag(RAGSearchScope.Kind.page)
                    Text("ノート").tag(RAGSearchScope.Kind.notebook)
                    Text("フォルダ").tag(RAGSearchScope.Kind.folder)
                    Text("ライブラリ").tag(RAGSearchScope.Kind.library)
                }
                if kind == .page, let selected {
                    Stepper("ページ \(pageNumber)", value: $pageNumber, in: 1...max(1, selected.sortedPages.count))
                }
                Button("この範囲で検索する") {
                    store.ragScope = RAGSearchScope(kind: kind,
                        sourceId: kind == .page || kind == .notebook ? selected.map { RAGLibrarySyncService.shared.isManaged ? RAGLibrarySyncService.shared.sourceID(for: $0) : $0.ragID } ?? nil : nil,
                        folderId: kind == .folder ? selected?.folder?.ragID : nil,
                        pageNumber: kind == .page ? pageNumber : nil)
                    status = L("検索範囲を設定しました。")
                }
                .disabled(!(consent || RAGLibrarySyncService.shared.enabled) || busy || (kind != .library && selected == nil) || (kind == .folder && selected?.folder == nil) || (RAGLibrarySyncService.shared.isManaged && (kind == .page || kind == .notebook) && selected.flatMap { RAGLibrarySyncService.shared.sourceID(for: $0) } == nil))
                Button("通常のAIチャットに戻す") { store.ragScope = nil }
            }
            if !RAGLibrarySyncService.shared.isManaged {
            Section("選択した資料の検索データ") {
                Button("本文を送信して検索用データを更新") {
                    guard let selected else { return }
                    beginRegistration(selected, upload: true)
                }.disabled(!consent || busy || selected == nil)
                Button("登録状況を再確認") {
                    guard let selected else { return }
                    beginRegistration(selected, upload: false)
                }.disabled(!consent || busy || selected == nil)
                Text(registration.explanation)
                    .font(.footnote)
                    .accessibilityIdentifier("rag-registration-\(registration.rawValue)")
                if !reviewNotice.isEmpty { Text(reviewNotice).font(.footnote) }
                Button("保存済みの検索データを削除", role: .destructive) {
                    guard let selected else { return }
                    cancelOperation()
                    registration = .unknown
                    busy = true
                    let account = RAGDeletionQueue.accountPartition()
                    let endpoint = WorkerAIProvider().baseURL
                    Task { @MainActor in
                        defer { busy = false }
                        let oldSource = selected.retireRAGSource()
                        store.ragScope = nil
                        selectedID = selected.ragID
                        do { try await RAGIndexingService().delete(sourceId: oldSource, account: account, endpoint: endpoint); status = L("検索データを削除しました。") }
                        catch { RAGDeletionQueue.enqueue(oldSource, account: account, endpoint: endpoint); status = L("削除を予約しました。通信回復後に再試行します。") }
                    }
                }.disabled(busy || selected == nil)
                if busy {
                    ProgressView()
                    if registration == .waiting {
                        Button("状況確認を停止") { cancelOperation(); registration = .waiting }
                    }
                }
                if !status.isEmpty { Text(status).font(.footnote) }
            }
            }
        }
        .navigationTitle("資料検索")
        .sheet(isPresented: $showingStructuredImport) { RAGStructuredImportView() }
        .onAppear {
            for notebook in eligible {
                notebook.ensureRAGIdentity()
                notebook.folder?.ensureRAGIdentity()
            }
            if let page = RAGCitationNavigation.currentPage, let notebook = page.notebook,
               !notebook.isLocked && notebook.lockedPDFData == nil && !notebook.isTrashed,
               let index = notebook.sortedPages.firstIndex(where: { $0 === page }) {
                selectedID = notebook.ragID
                kind = .page
                pageNumber = index + 1
            }
        }
        .onDisappear { cancelOperation() }
        .onChange(of: selectedID) { _, _ in
            cancelOperation()
            registration = .unknown
            status = ""
            reviewNotice = ""
            if let page = RAGCitationNavigation.currentPage, page.notebook?.ragID == selectedID,
               let index = page.notebook?.sortedPages.firstIndex(where: { $0 === page }) {
                pageNumber = index + 1
            } else { pageNumber = 1 }
        }
    }

    private func cancelOperation() {
        if operation != nil { busy = false }
        operation?.cancel()
        operation = nil
        operationID = UUID()
        registration = .unknown
    }
    private func beginRegistration(_ notebook: Notebook, upload: Bool) {
        cancelOperation()
        let id = operationID
        let sourceId = notebook.ragID
        busy = true
        status = ""
        registration = upload ? .uploading : .waiting
        operation = Task { @MainActor in
            defer { if operationID == id { busy = false; operation = nil } }
            do {
                let service = RAGIndexingService()
                var expectedHash: String?
                if upload {
                    let result = try await service.index(notebook) { sent, total in
                        if operationID == id { status = String(format: L("%d / %dページを送信しました。"), sent, total) }
                    }
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    expectedHash = result.sourceHash
                    reviewNotice = result.reviewPageNumbers.isEmpty ? "" :
                        String(format: L("%dページは文字認識や数式の確認が必要です。出典の原本で確認してください。"), result.reviewPageNumbers.count)
                    status = ""
                }
                _ = try await service.waitUntilSearchable(sourceId: sourceId, expectedHash: expectedHash,
                    whileEligible: {
                        operationID == id && notebook.ragID == sourceId && !notebook.isLocked &&
                        notebook.lockedPDFData == nil && notebook.encryptedContent == nil && !notebook.isTrashed
                    }, onState: { state in
                        if operationID == id { registration = state }
                    })
            } catch is CancellationError {
                if operationID == id { registration = .unknown }
            } catch {
                if operationID == id { registration = .failed; status = error.localizedDescription }
            }
        }
    }
}

struct RAGCitationLinks: View {
    let citations: [RAGCitation]
    var body: some View {
        if !citations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("出典").font(.caption).foregroundStyle(.secondary)
                ForEach(citations) { citation in
                    Button { RAGCitationNavigation.open(citation) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("\(citation.title) · \(citation.pageNumber)ページ", systemImage: "doc.text.magnifyingglass")
                            if let metadata = citation.metadata {
                                Text(metadata.segments.contains(where: { $0.kind == "table" }) ? "表を含む出典" : "元の資料の出典")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("rag-citation-\(citation.pageNumber)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RAGRetrievalStatusNotice: View {
    let status: RAGRetrievalStatus?
    var body: some View {
        if let status {
            Text(status.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("rag-status-\(status.rawValue)")
        }
    }
}
