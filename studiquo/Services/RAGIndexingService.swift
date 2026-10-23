import Foundation
import CryptoKit
import UIKit
import SwiftData
import Security

struct RAGSearchScope: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case page, notebook, folder, library }
    var kind: Kind
    var sourceId: String? = nil
    var folderId: String? = nil
    var pageNumber: Int? = nil
    var sourceIds: [String]? = nil

    var payload: [String: Any] {
        var value: [String: Any] = ["kind": kind.rawValue]
        if let sourceId { value["sourceId"] = sourceId }
        if let folderId { value["folderId"] = folderId }
        if let pageNumber { value["pageNumber"] = pageNumber }
        if let sourceIds { value["sourceIds"] = sourceIds }
        return value
    }
}

struct RAGCitation: Codable, Equatable, Identifiable {
    let sourceId: String
    let title: String
    let pageNumber: Int
    let chunkId: String
    let metadata: RAGCitationMetadata?
    var id: String { chunkId }

    init(sourceId: String, title: String, pageNumber: Int, chunkId: String, metadata: RAGCitationMetadata? = nil) {
        self.sourceId = sourceId
        self.title = title
        self.pageNumber = pageNumber
        self.chunkId = chunkId
        self.metadata = metadata.flatMap { $0.isValid(pageNumber: pageNumber, chunkId: chunkId) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey { case sourceId, title, pageNumber, chunkId, metadata }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try values.decode(String.self, forKey: .sourceId)
        title = try values.decode(String.self, forKey: .title)
        pageNumber = try values.decode(Int.self, forKey: .pageNumber)
        chunkId = try values.decode(String.self, forKey: .chunkId)
        // A malformed/unknown optional extension must not discard a usable page citation.
        let candidate = try? values.decodeIfPresent(RAGCitationMetadata.self, forKey: .metadata)
        if let candidate, candidate.isValid(pageNumber: pageNumber, chunkId: chunkId) {
            metadata = candidate
        } else {
            metadata = nil
        }
    }

    static func decodeEvent(_ data: Data) -> [Self]? {
        // Bounds citation parsing. The caller's URLSession line buffering is separate.
        guard data.count <= 512 * 1024 else { return nil }
        struct Event: Decodable { let citations: [RAGCitation] }
        return (try? JSONDecoder().decode(Event.self, from: data))?.citations.filter {
            !$0.sourceId.isEmpty && !$0.chunkId.isEmpty && $0.pageNumber > 0
        }
    }
}

/// Search evidence state, independent of the generated answer's correctness.
enum RAGRetrievalStatus: String, CaseIterable {
    case grounded, partial, insufficient, clarification, fallback

    static func decodeEvent(_ data: Data, acceptingRAG: Bool) -> Self? {
        guard acceptingRAG else { return nil }
        struct Event: Decodable { let ragStatus: String }
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
        return Self(rawValue: event.ragStatus)
    }

    var explanation: String {
        switch self {
        case .grounded: return L("参考資料を取得しました。回答と出典を確認してください。")
        case .partial: return L("質問の一部についてのみ参考資料が見つかりました。")
        case .insufficient: return L("取得した抜粋で必要な情報を確認できませんでした。")
        case .clarification: return L("何についての質問か、具体的に教えてください。")
        case .fallback: return L("資料検索を利用できないため、通常のAI回答です。")
        }
    }
}

/// Upload acknowledgement and search visibility are separate states.
enum RAGRegistrationState: String, Decodable {
    case unknown, uploading, waiting, ready, failed, disabled, missing, empty, limited
    var explanation: String {
        switch self {
        case .unknown: return L("登録状況を確認してください。")
        case .uploading: return L("登録中です。本文の読み取りと送信を行っています。")
        case .waiting: return L("検索への反映待ちです。まだ資料が検索で見つからない場合があります。時間を置いて再確認できます。")
        case .ready: return L("検索可能です。検索への反映を確認しました。")
        case .failed: return L("処理に失敗しました。登録中の失敗は更新を、状況確認の失敗は再確認をお試しください。")
        case .disabled: return L("資料検索は現在利用できません。")
        case .missing: return L("この資料は未登録、または検索データが削除されています。")
        case .limited: return L("この資料は大きいため、検索への反映を確認できませんでした。登録済みデータは保持されています。")
        case .empty: return L("検索できる本文がありません。資料の文字認識を確認してください。")
        }
    }
}

enum RAGConsent {
    static let version = "rag-openai-v1"
    static var isGranted: Bool {
        UserDefaults.standard.string(forKey: "ragCloudConsentVersion") == version
    }
    static func grant() { UserDefaults.standard.set(version, forKey: "ragCloudConsentVersion") }
    static func revoke() { UserDefaults.standard.removeObject(forKey: "ragCloudConsentVersion") }
}

/// All uploads are explicit. Opening/importing a notebook never invokes indexing.
@MainActor
final class RAGIndexingService {
    struct PageText: Codable, Equatable { let pageNumber: Int; let text: String }
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private let sleep: () async throws -> Void
    private let recognizer: RAGDocumentTextExtractionService.Recognizer
    private let accountPartition: () -> String?
    struct IndexResult { let reviewPageNumbers: [Int]; let supplementedPages: Int; let sourceId: String; let sourceHash: String }
    init(recognizer: @escaping RAGDocumentTextExtractionService.Recognizer = RAGDocumentTextExtractionService.recognize,
         accountPartition: @escaping () -> String? = RAGDeletionQueue.accountPartition,
         sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(10)) },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.recognizer = recognizer
        self.accountPartition = accountPartition
        self.transport = transport
        self.sleep = sleep
    }
    enum IndexError: LocalizedError {
        case locked, disabled, oversized, accountChanged
        var errorDescription: String? {
            switch self {
            case .locked: return L("保護されたノートは検索用に送信できません。")
            case .disabled: return L("資料検索は現在利用できません。")
            case .accountChanged: return L("アカウントが変更されたため処理を中止しました。")
            case .oversized: return L("ページのテキストが送信上限を超えています。")
            }
        }
    }
    static func batches(_ pages: [PageText]) -> [[PageText]] {
        stride(from: 0, to: pages.count, by: 5).map { Array(pages[$0..<min($0 + 5, pages.count)]) }
    }
    static func sourceHash(_ pages: [PageText]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(pages)).map { String(format: "%02x", $0) }.joined()
    }
    func isEnabled(requiringStructured: Bool = false) async -> Bool {
        guard AIDataDisclosure.hasBeenAcknowledged else { return false }
        do {
            var request = try WorkerAIProvider().request(path: "api/rag/status", body: [:])
            request.httpMethod = "GET"
            request.httpBody = nil
            let data = try await send(request)
            struct Status: Decodable { let enabled: Bool; let structuredIngestVersion: Int? }
            guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return false }
            return status.enabled && (!requiringStructured || status.structuredIngestVersion == 1)
        } catch { return false }
    }
    @discardableResult
    func index(_ notebook: Notebook, onProgress: ((Int, Int) -> Void)? = nil) async throws -> IndexResult {
        let indexingAccount = accountPartition()
        let indexingEndpoint = WorkerAIProvider().baseURL
        let indexingFingerprint = RAGLibrarySyncService.fingerprint(notebook)
        guard !notebook.isLocked, notebook.lockedPDFData == nil, notebook.encryptedContent == nil, !notebook.isTrashed else { throw IndexError.locked }
        guard RAGConsent.isGranted else { throw WorkerAIProvider.ProviderError.consentRequired }
        let prepared = try RAGStructuredAttachment.prepared(notebook)
        guard await isEnabled(requiringStructured: prepared != nil) else { throw IndexError.disabled }
        guard accountPartition() == indexingAccount else { throw IndexError.accountChanged }
        guard WorkerAIProvider().baseURL == indexingEndpoint else { throw IndexError.disabled }
        guard RAGLibrarySyncService.fingerprint(notebook) == indexingFingerprint else { throw IndexError.locked }
        notebook.ensureRAGIdentity()
        notebook.folder?.ensureRAGIdentity()
        try notebook.modelContext?.save()
        let sourceId = notebook.ragID
        if let prepared {
            return try await indexPrepared(prepared, notebook: notebook, account: indexingAccount, sourceId: sourceId, fingerprint: indexingFingerprint, endpoint: indexingEndpoint, onProgress: onProgress)
        }
        let sorted = notebook.sortedPages
        var pages: [PageText] = []
        var reviewPages: [Int] = []
        var supplementedPages = 0
        for (offset, page) in sorted.enumerated() {
            try Task.checkCancellation()
            guard accountPartition() == indexingAccount,
                  RAGConsent.isGranted, !notebook.isLocked, notebook.lockedPDFData == nil,
                  notebook.encryptedContent == nil, !notebook.isTrashed else { throw IndexError.locked }
            // A notebook's recognizedText is an OCR cache and may contain erased ink.
            // PDF page.string remains reusable; editable ink is recognized below.
            var text = page.backgroundImageData == nil ? "" : page.recognizedText
            if let data = page.backgroundImageData {
                let extracted = await RAGDocumentTextExtractionService.extract(nativeText: text, imageData: data, recognizer: recognizer)
                text = extracted.text
                if extracted.needsReview { reviewPages.append(offset + 1) }
                if extracted.supplementedLines > 0 { supplementedPages += 1 }
                try Task.checkCancellation()
                guard accountPartition() == indexingAccount, RAGConsent.isGranted,
                      !notebook.isLocked, notebook.lockedPDFData == nil, notebook.encryptedContent == nil, !notebook.isTrashed else { throw IndexError.locked }
            }
            // Editable ink is recognized fresh so edits do not reuse a stale OCR cache.
            if page.backgroundImageData == nil || page.drawingData != nil {
                let ink = await HandwritingRecognitionService.recognize(
                    drawingData: page.drawingData, pageSize: CGSize(width: page.pageWidth, height: page.pageHeight))
                if !ink.isEmpty { text += "\n" + ink }
            }
            let elements = page.allElements.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            if !elements.isEmpty { text += "\n" + elements }
            pages.append(PageText(pageNumber: offset + 1, text: text))
        }
        let hash = try Self.sourceHash(pages)
        var uploaded = 0
        for batch in Self.batches(pages) {
            try Task.checkCancellation()
            guard accountPartition() == indexingAccount,
                  notebook.ragID == sourceId, !notebook.isLocked, notebook.lockedPDFData == nil, notebook.encryptedContent == nil, !notebook.isTrashed, RAGConsent.isGranted else { throw IndexError.locked }
            var request = try WorkerAIProvider().request(path: "api/rag/index", body: [
                "sourceId": sourceId, "title": notebook.title,
                "kind": notebook.containsPDF ? "pdf" : "notebook",
                "folderId": notebook.folder?.ragID as Any? ?? NSNull(), "sourceHash": hash,
                "totalPages": pages.count,
                "pages": batch.map { ["pageNumber": $0.pageNumber, "text": $0.text] }
            ])
            guard (request.httpBody?.count ?? 0) <= 512_000 else { throw IndexError.oversized }
            request.setValue(RAGConsent.version, forHTTPHeaderField: "X-Studiquo-RAG-Consent")
            _ = try await send(request)
            uploaded += batch.count
            onProgress?(uploaded, pages.count)
            guard accountPartition() == indexingAccount else { throw IndexError.locked }
            if notebook.isLocked || notebook.lockedPDFData != nil || notebook.encryptedContent != nil || notebook.isTrashed || !RAGConsent.isGranted {
                RAGDeletionQueue.enqueue(sourceId)
                throw IndexError.locked
            }
        }
        return IndexResult(reviewPageNumbers: reviewPages, supplementedPages: supplementedPages, sourceId: sourceId, sourceHash: hash)
    }
    private func indexPrepared(_ document: RAGStructuredDocument, notebook: Notebook, account: String?, sourceId: String, fingerprint: String, endpoint: URL?,
                               onProgress: ((Int, Int) -> Void)?) async throws -> IndexResult {
        func check() throws {
            try Task.checkCancellation()
            guard accountPartition() == account else { throw IndexError.accountChanged }
            guard WorkerAIProvider().baseURL == endpoint else { throw IndexError.disabled }
            guard notebook.ragID == sourceId, !notebook.isLocked, notebook.encryptedContent == nil,
                  notebook.lockedPDFData == nil, !notebook.isTrashed, RAGConsent.isGranted,
                  AIDataDisclosure.hasBeenAcknowledged, RAGLibrarySyncService.fingerprint(notebook) == fingerprint else { throw IndexError.locked }
        }
        var uploaded = 0
        do {
            for batch in document.batches {
                try check()
                var body = batch
                body["sourceId"] = sourceId; body["title"] = notebook.title; body["kind"] = "pdf"
                body["folderId"] = notebook.folder?.ragID as Any? ?? NSNull()
                body["sourceHash"] = document.sourceHash
                var request = try WorkerAIProvider().request(path: "api/rag/index", body: body)
                guard (request.httpBody?.count ?? 0) <= 512_000 else { throw IndexError.oversized }
                request.setValue(RAGConsent.version, forHTTPHeaderField: "X-Studiquo-RAG-Consent")
                _ = try await send(request)
                try check()
                uploaded += (batch["pages"] as? [[String: Any]])?.count ?? 0
                onProgress?(uploaded, document.pages.count)
            }
        } catch {
            if accountPartition() == account && WorkerAIProvider().baseURL == endpoint && (notebook.isLocked || notebook.isTrashed || !RAGConsent.isGranted || RAGLibrarySyncService.fingerprint(notebook) != fingerprint) {
                RAGDeletionQueue.enqueue(sourceId)
            }
            throw error
        }
        return IndexResult(reviewPageNumbers: [], supplementedPages: 0, sourceId: sourceId, sourceHash: document.sourceHash)
    }

    /// Reuses the PDF native-text/OCR path without legacy consent or legacy source IDs.
    func extractManaged(_ notebook: Notebook, whileEligible: () throws -> Void) async throws -> [PageText] {
        var result: [PageText] = []
        for (offset, page) in notebook.sortedPages.enumerated() {
            try whileEligible(); try Task.checkCancellation()
            var text = page.backgroundImageData == nil ? "" : page.recognizedText
            if let data = page.backgroundImageData {
                text = await RAGDocumentTextExtractionService.extract(nativeText: text, imageData: data, recognizer: recognizer).text
                try whileEligible(); try Task.checkCancellation()
            }
            if page.backgroundImageData == nil || page.drawingData != nil {
                let ink = await HandwritingRecognitionService.recognize(drawingData: page.drawingData,
                    pageSize: CGSize(width: page.pageWidth, height: page.pageHeight))
                try whileEligible(); try Task.checkCancellation()
                if !ink.isEmpty { text += "\n" + ink }
            }
            let elements = page.allElements.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            if !elements.isEmpty { text += "\n" + elements }
            result.append(PageText(pageNumber: offset + 1, text: text))
        }
        return result
    }
    /// Bounded foreground polling. A timeout stays waiting and never reuploads text.
    func waitUntilSearchable(sourceId: String, expectedHash: String? = nil,
                             maxAttempts: Int = 18,
                             whileEligible: () -> Bool = { true },
                             onState: (RAGRegistrationState) -> Void = { _ in }) async throws -> RAGRegistrationState {
        let owner = accountPartition()
        func guardSession() throws {
            try Task.checkCancellation()
            guard accountPartition() == owner else { throw IndexError.accountChanged }
            guard whileEligible(), RAGConsent.isGranted, AIDataDisclosure.hasBeenAcknowledged else {
                throw WorkerAIProvider.ProviderError.consentRequired
            }
        }
        for attempt in 0..<max(1, min(maxAttempts, 18)) {
            try guardSession()
            var request = try WorkerAIProvider().request(path: "api/rag/sources/\(sourceId)/readiness", body: [:])
            request.httpMethod = "GET"
            request.httpBody = nil
            request.timeoutInterval = 20
            let (data, response) = try await transport(request)
            try guardSession()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 502
            // Old servers do not expose readiness. Never interpret upload completion as ready.
            if code == 404 { onState(.waiting); return .waiting }
            if code != 429 && code != 503 && !(200..<300 ~= code) {
                throw WorkerAIProvider.ProviderError.http(status: code, message: "")
            }
            struct Reply: Decodable { let state: String; let sourceHash: String?; let reason: String? }
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
            let state: RAGRegistrationState
            if code == 429 || code == 503 { state = .waiting }
            else if let reply {
                let decoded = reply.reason == "check_limit" ? .limited : (RAGRegistrationState(rawValue: reply.state) ?? .waiting)
                let validHash = reply.sourceHash?.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
                state = decoded == .ready && (!validHash || (expectedHash != nil && reply.sourceHash != expectedHash)) ? .waiting : decoded
            } else { state = .waiting }
            onState(state)
            if state != .waiting && state != .unknown && state != .uploading { return state }
            if attempt + 1 < max(1, min(maxAttempts, 18)) { try await sleep() }
        }
        return .waiting
    }
    func delete(sourceId: String) async throws {
        var request = try WorkerAIProvider().request(path: "api/rag/source", body: ["sourceId": sourceId], requiresAIConsent: false)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            throw WorkerAIProvider.ProviderError.http(status: status, message: "")
        }
        return data
    }
}

/// Retry metadata contains only stable IDs, never notebook content or credentials.
@MainActor
enum RAGDeletionQueue {
    /// Derive an account partition from the same persisted canonical identity as authentication.
    /// No queue is flushed under another account's bearer token.
    static func accountPartition() -> String? {
        func identity(_ account: String) -> [String: Any]? {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.yabuko.studiquo.authentication",
                kSecAttrAccount as String: account, kSecReturnData as String: true]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        var canonical: String?
        if let value = identity("oauth-identity"), let provider = value["provider"] as? String,
           let subject = value["subject"] as? String {
            canonical = provider == "apple" ? subject : "\(provider):\(subject)"
        } else if let email = identity("passkey-identity")?["email"] as? String {
            canonical = "email:\(email)"
        }
        guard let canonical else { return nil }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static var key: String? {
        accountPartition().map { "ragPendingSourceDeletions-" + $0 }
    }
    static func enqueueNotebook(_ notebook: Notebook, preservingCitations: Bool = true, state: String = "deleted") {
        _ = RAGLibrarySyncService.shared.canSearch // Refresh the account/endpoint before choosing the lifecycle route.
        if RAGLibrarySyncService.shared.isManaged {
            RAGLibrarySyncService.shared.invalidate(notebook: notebook, state: state)
            return
        }
        enqueue(notebook.retireRAGSource(preservingCitations: preservingCitations))
    }
    static func enqueue(_ sourceId: String) {
        guard let key else { return }
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(sourceId) { ids.append(sourceId) }
        UserDefaults.standard.set(ids, forKey: key)
        Task { await flush() }
    }
    static func safeScope(_ scope: RAGSearchScope?) async -> RAGSearchScope? {
        guard let scope else { return nil }
        await flush()
        guard let key, (UserDefaults.standard.stringArray(forKey: key) ?? []).isEmpty else { return nil }
        return scope
    }
    static func flush() async {
        guard let key else { return }
        let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        for id in ids {
            guard Self.key == key else { return }
            do {
                try await RAGIndexingService().delete(sourceId: id)
                var remaining = UserDefaults.standard.stringArray(forKey: key) ?? []
                remaining.removeAll { $0 == id }
                UserDefaults.standard.set(remaining, forKey: key)
            } catch { /* Keep for the next foreground retry. */ }
        }
    }
}

@MainActor
enum RAGCitationNavigation {
    static let notification = Notification.Name("StudiquoOpenRAGCitation")
    static weak var currentPage: NotePage?
    private static var pending: RAGCitation?
    static func resolve(_ citation: RAGCitation, notebooks: [Notebook]) -> (Notebook, Int)? {
        _ = RAGLibrarySyncService.shared.canSearch // Refresh the account/endpoint before choosing the lifecycle route.
        if RAGLibrarySyncService.shared.isManaged {
            return RAGLibrarySyncService.shared.resolve(citation, notebooks: notebooks)
        }
        guard let notebook = notebooks.first(where: { $0.matchesRAGSource(citation.sourceId) && !$0.isTrashed && !$0.isLocked && $0.lockedPDFData == nil }),
              notebook.sortedPages.indices.contains(citation.pageNumber - 1) else { return nil }
        return (notebook, citation.pageNumber - 1)
    }
    static func open(_ citation: RAGCitation) {
        pending = citation
        NotificationCenter.default.post(name: notification, object: citation)
    }
    static func consume(for notebook: Notebook) -> Int? {
        guard let citation = pending, let (_, page) = resolve(citation, notebooks: [notebook]) else { return nil }
        pending = nil
        return page
    }
}
