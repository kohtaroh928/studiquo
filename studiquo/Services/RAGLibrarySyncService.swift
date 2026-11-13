import Foundation
import CryptoKit
import SwiftData
import Observation

/// Foreground-only, opt-in owned PDF synchronization. All authorization is checked again by the Worker.
@Observable @MainActor
final class RAGLibrarySyncService {
    enum GrantError: LocalizedError {
        case localPersistence

        var errorDescription: String? {
            switch self {
            case .localPersistence:
                return L("この端末の資料情報を保存できなかったため、自動登録を開始しませんでした。資料を閉じてからもう一度お試しください。")
            }
        }
    }
    static let shared = RAGLibrarySyncService()
    static let changeNotification = Notification.Name("StudiquoRAGLibrarySyncChanged")
    typealias Scope = RAGLibrarySyncState.Scope
    private let client: RAGControlClient
    private let defaults: UserDefaults
    private let partition: () -> String?
    private let extractor: RAGIndexingService
    private var loadedPartition: String?
    private var state = RAGLibrarySyncState()
    private var operation = 0
    private var controlTask: Task<Void, Never>?
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = 0
    private var foreground = true
    private var pendingReconciliation: ([Notebook], ModelContext)?
    private(set) var available = false
    private(set) var controlChecked = false
    private(set) var busy = false
    /// Stage text for the busy indicator (page text extraction / upload). Never contains document content.
    private(set) var progressText: String?
    private var transientAttempts = 0
    /// In-memory 0...1 progress per document id while it is being registered (text reading 0-50%, upload 50-100%).
    private(set) var liveProgress: [String: Double] = [:]
    enum DocumentStatus: Equatable {
        case excluded, queued, inProgress(Double), waiting, ready
    }
    func status(for notebook: Notebook) -> DocumentStatus {
        load()
        let id = notebook.ragDocumentID
        if state.excluded.contains(id) { return .excluded }
        let entry = state.entries[id]
        if entry?.pendingState != nil { return .queued }
        if entry?.completed == true { return entry?.searchState == "ready" ? .ready : .waiting }
        // The first run has no entry until text reading finishes, so live progress comes first.
        if let live = liveProgress[id] { return .inProgress(live) }
        guard let entry else { return .queued }
        if entry.nextPage > 0, let total = entry.totalPages, total > 0 {
            return .inProgress(0.5 + 0.5 * min(1, Double(entry.nextPage) / Double(total)))
        }
        return .queued
    }
    private(set) var errorMessage: String?
    private(set) var isManaged = false
    var enabled: Bool { state.enabled && !state.pendingRevoke && state.processorConsentVersion == RAGConsent.version && RAGConsent.isGranted && AIDataDisclosure.hasBeenAcknowledged }
    var canSearch: Bool { load(); return enabled && !state.entries.values.contains(where: { $0.pendingState != nil }) }
    var pendingCount: Int { state.entries.values.filter { $0.pendingState != nil || !$0.completed }.count + (state.pendingRevoke ? 1 : 0) }
    var waitingCount: Int { state.entries.values.filter { $0.completed && $0.searchState != "ready" && $0.pendingState == nil }.count }
    var searchableCount: Int { state.entries.values.filter { $0.completed && $0.searchState == "ready" && $0.pendingState == nil }.count }
    var registeredCount: Int { state.entries.values.filter { $0.completed && $0.pendingState == nil }.count }
    var stateSummary: String { enabled ? "検索可能 \(searchableCount)件・検索反映待ち \(waitingCount)件・登録待ち \(pendingCount)件" : (state.pendingRevoke ? "停止処理の反映待ち" : "自動資料検索はオフ") }
    init(client: RAGControlClient? = nil, defaults: UserDefaults = .standard,
         partition: @escaping () -> String? = RAGLibrarySyncService.defaultPartition,
         extractor: RAGIndexingService? = nil,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now; self.sleep = sleep
        self.client = client ?? RAGControlClient(); self.defaults = defaults; self.partition = partition; self.extractor = extractor ?? RAGIndexingService()
        load()
    }
    static func defaultPartition() -> String? {
        guard let account = RAGDeletionQueue.accountPartition() else { return nil }
        guard let endpoint = LaunchStoreEnvironment.endpoint else { return nil }
        return account + "-" + digest(Data(endpoint.absoluteString.utf8))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func load() {
        let owner = partition()
        guard owner != loadedPartition else { return }
        loadedPartition = owner
        retryGeneration += 1; retryTask?.cancel(); retryTask = nil
        operation += 1
        let data = owner.flatMap { defaults.data(forKey: "ragManaged-" + $0) }
        state = data.flatMap { try? JSONDecoder().decode(RAGLibrarySyncState.self, from: $0) } ?? RAGLibrarySyncState()
        isManaged = data != nil; available = false; controlChecked = false; errorMessage = nil
    }
    @discardableResult private func save() -> Bool {
        guard let owner = loadedPartition, partition() == owner, let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: "ragManaged-" + owner)
        guard defaults.data(forKey: "ragManaged-" + owner) == data else {
            state.enabled = false; errorMessage = "安全な保存を確認できないため停止しました。"; return false
        }
        isManaged = true
        return true
    }
    private func notify() { NotificationCenter.default.post(name: Self.changeNotification, object: nil) }
    func refreshAvailability() async {
        load(); let owner = loadedPartition, refreshOperation = operation
        guard owner != nil else { return }
        do { let reply = try await client.consent(); guard owner == partition(), loadedPartition == owner, operation == refreshOperation else { load(); return }
            controlChecked = true
            available = reply.available == true
            if reply.managed == true && !isManaged { state.enabled = false; _ = save() }
            // Never infer local consent from an existing remote or legacy consent.
            if state.enabled && (!reply.enabled || reply.consentEpoch != state.consentEpoch) { state.enabled = false; _ = save() }
        } catch { available = false; controlChecked = false }
    }
    func grant(scope: Scope, includeFuture: Bool, context: ModelContext, notebooks: [Notebook]) async throws {
        load(); guard let owner = loadedPartition, !busy, AIDataDisclosure.hasBeenAcknowledged else { throw RAGIndexingService.IndexError.disabled }
        operation += 1; let grantOperation = operation
        if state.pendingRevoke { await drainRevoke() }
        guard !state.pendingRevoke, owner == partition(), operation == grantOperation else { throw RAGIndexingService.IndexError.disabled }
        // A person explicitly granting permission must not be held behind a
        // retry deadline created by an earlier background reconciliation.
        // The next request is still subject to the server's rate limit.
        state.controlRetryAfter = nil; state.controlRetryAttempts = 0
        guard save() else { throw RAGIndexingService.IndexError.disabled }
        // The consent update below invalidates every previous remote source as
        // one server-side generation change. Do not make a fresh, explicit
        // grant depend on an old local invalidation queue: that queue can
        // belong to a prior registration and may be temporarily unavailable.
        prepareIdentities(for: notebooks, scope: scope)
        do { try context.save() }
        catch { throw GrantError.localPersistence }
        let current = try await client.consent()
        guard owner == partition(), operation == grantOperation, current.available == true else { throw RAGIndexingService.IndexError.disabled }
        // Persist a pending revoke first: an interrupted grant is recovered by disabling remote consent.
        state.pendingRevoke = true; state.enabled = false
        guard save() else { throw RAGIndexingService.IndexError.disabled }
        let reply = try await client.setConsent(enabled: true, epoch: current.consentEpoch)
        guard owner == partition(), operation == grantOperation else { throw RAGIndexingService.IndexError.accountChanged }
        state.processorConsentVersion = RAGConsent.version
        state.enabled = true; state.pendingRevoke = false; state.consentEpoch = reply.consentEpoch
        state.scope = scope; state.includeFuture = includeFuture
        state.selectedAtGrant = notebooks.filter { Self.eligible($0) && matches(scope, $0) }.map(\.ragDocumentID)
        state.entries = [:]
        guard save() else { throw RAGIndexingService.IndexError.disabled }
        RAGConsent.grant(); available = true; notify()
    }

    /// Only the PDFs included in the new grant need stable identities. Touching
    /// every library record here made an unrelated legacy record able to block
    /// a user's explicit registration request before any network call.
    func prepareIdentities(for notebooks: [Notebook], scope: Scope) {
        for notebook in notebooks where Self.eligible(notebook) && matches(scope, notebook) {
            notebook.ensureRAGIdentity()
            var folder = notebook.folder, visited: Set<String> = []
            while let current = folder {
                current.ensureRAGIdentity()
                guard visited.insert(current.ragID).inserted else { break }
                folder = current.parent
            }
        }
    }
    func revoke() async {
        load(); retryGeneration += 1; retryTask?.cancel(); retryTask = nil; operation += 1; state.enabled = false; state.pendingRevoke = true
        guard save() else { return }; notify()
        await drainRevoke()
    }
    private func drainRevoke() async {
        let owner = loadedPartition, revokeOperation = operation
        do { let remote = try await client.consent(); guard owner == partition(), operation == revokeOperation else { return }
            let reply = try await client.setConsent(enabled: false, epoch: remote.consentEpoch)
            guard owner == partition(), operation == revokeOperation else { return }
            state.consentEpoch = reply.consentEpoch; state.pendingRevoke = false
            if let owner { RAGOCRPageCache.removeAll(owner: owner) }
            for key in state.entries.keys {
                state.entries[key]?.sourceId = nil; state.entries[key]?.completed = false
                if state.entries[key]?.pendingState == "eligible" { state.entries[key]?.pendingState = nil }
            }
            _ = save(); notify()
        } catch WorkerAIProvider.ProviderError.http(let status, _) where status == 429 {
            guard owner == partition(), loadedPartition == owner, operation == revokeOperation else { return }
            _ = recordRateLimit(document: nil)
            errorMessage = "停止要求は保存済みです。混雑後に再試行します。"
        } catch { errorMessage = "停止要求は保存済みです。接続時に再試行します。" }
    }
    private func matches(_ scope: Scope, _ notebook: Notebook) -> Bool {
        switch scope { case .allPDFs: return true
        case .folder(let id):
            var folder = notebook.folder
            var seen: Set<String> = []
            while let current = folder {
                current.ensureRAGIdentity()
                if current.ragID == id { return true }
                guard seen.insert(current.ragID).inserted else { return false }
                folder = current.parent
            }
            return false
        case .selected(let ids): return ids.contains(notebook.ragDocumentID) }
    }
    static func eligible(_ notebook: Notebook) -> Bool {
        notebook.containsPDF && !notebook.isLocked && !notebook.isTrashed && notebook.lockedPDFData == nil && notebook.encryptedContent == nil
    }
    private func selected(_ notebook: Notebook) -> Bool {
        Self.eligible(notebook) && !state.excluded.contains(notebook.ragDocumentID) && matches(state.scope, notebook)
            && (state.includeFuture || state.selectedAtGrant.contains(notebook.ragDocumentID))
    }
    /// Hash the actual current material, including order, ink, text and scope metadata.
    static func fingerprint(_ notebook: Notebook) -> String {
        var hash = SHA256()
        func add(_ data: Data) { var length = UInt64(data.count).bigEndian; withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }; hash.update(data: data) }
        add(Data(notebook.title.utf8)); add(Data((notebook.folder?.ragID ?? "").utf8))
        if let package = notebook.ragStructuredData { add(Data(SHA256.hash(data: package))) }
        for page in notebook.sortedPages {
            add(Data("\(page.order):\(page.pageWidth):\(page.pageHeight)".utf8))
            add(page.backgroundImageData ?? Data()); add(page.drawingData ?? Data()); add(Data(page.recognizedText.utf8))
            for element in page.allElements { add(Data(element.text.utf8)); add(element.imageData ?? Data()) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func sourceID(for notebook: Notebook) -> String? {
        load(); guard canSearch, selected(notebook), let entry = state.entries[notebook.ragDocumentID], entry.completed, entry.searchState == "ready",
              entry.pendingState == nil, entry.fingerprint == Self.fingerprint(notebook) else { return nil }
        return entry.sourceId
    }
    func resolve(_ citation: RAGCitation, notebooks: [Notebook]) -> (Notebook, Int)? {
        guard let notebook = notebooks.first(where: { sourceID(for: $0) == citation.sourceId }),
              notebook.sortedPages.indices.contains(citation.pageNumber - 1) else { return nil }
        return (notebook, citation.pageNumber - 1)
    }
    func invalidate(notebook: Notebook, state target: String) {
        load(); guard isManaged else { return }; notebook.ensureRAGIdentity()
        var entry = state.entries[notebook.ragDocumentID] ?? .init()
        guard entry.pendingState != target, entry.settledState != target || entry.sourceId != nil else { return }
        entry.pendingState = target; entry.completed = false; entry.sourceId = nil
        state.entries[notebook.ragDocumentID] = entry
        if target == "excluded", !state.excluded.contains(notebook.ragDocumentID) { state.excluded.append(notebook.ragDocumentID) }
        if target == "excluded", let owner = loadedPartition { RAGOCRPageCache.removeAll(owner: owner) }
        _ = save(); notify()
        startInvalidationFlush()
    }
    private func startInvalidationFlush() {
        guard controlTask == nil, !state.pendingRevoke, state.entries.values.contains(where: { $0.pendingState != nil }) else { return }
        let controlOwner = loadedPartition, controlOperation = operation
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer { self.controlTask = nil }
            do { try await self.drainInvalidations() }
            catch WorkerAIProvider.ProviderError.http(let status, _) where status == 429 {
                guard self.partition() == controlOwner, self.loadedPartition == controlOwner, self.operation == controlOperation else { return }
                _ = self.recordRateLimit(document: nil)
                self.errorMessage = "停止要求は保存済みです。混雑後に再試行します。"
            }
            catch { self.errorMessage = "停止要求は保存済みです。接続時に再試行します。" }
        }
    }
    private func flushInvalidations() async throws {
        if let controlTask { await controlTask.value }
        if let deadline = state.controlRetryAfter, deadline > now() {
            throw WorkerAIProvider.ProviderError.http(status: 429, message: "")
        }
        try await drainInvalidations()
    }
    private func drainInvalidations() async throws {
        let owner = loadedPartition, invalidateOperation = operation
        for (id, entry) in state.entries where entry.pendingState != nil {
            let remote = try await client.document(id); guard owner == partition(), loadedPartition == owner, operation == invalidateOperation else { throw RAGIndexingService.IndexError.accountChanged }
            let consent = try await client.consent(); guard owner == partition(), loadedPartition == owner, operation == invalidateOperation else { throw RAGIndexingService.IndexError.accountChanged }
            if remote.state != "deleted" {
                _ = try await client.invalidate(id, state: entry.pendingState!, generation: remote.generation, epoch: consent.consentEpoch)
                guard owner == partition(), loadedPartition == owner, operation == invalidateOperation else { throw RAGIndexingService.IndexError.accountChanged }
            }
            // Do not erase a new invalidation that arrived during this await.
            if state.entries[id]?.pendingState == entry.pendingState {
                state.entries[id]?.pendingState = nil; state.entries[id]?.settledState = entry.pendingState
                state.entries[id]?.requestId = ""; state.entries[id]?.nextPage = 0
                _ = save()
            }
        }
    }
    func reconcile(notebooks: [Notebook], context: ModelContext) async {
        load(); guard loadedPartition != nil, foreground else { return }
        if busy { pendingReconciliation = (notebooks, context); return }
        busy = true
        defer {
            busy = false; progressText = nil; liveProgress.removeAll()
            if let next = pendingReconciliation {
                pendingReconciliation = nil
                Task { await self.reconcile(notebooks: next.0, context: next.1) }
            }
        }
        var activeDocument: String?
        let reconciliationOperation = operation
        do {
            if let retry = state.controlRetryAfter, retry > now() {
                scheduleRetry(notebooks: notebooks, context: context, delay: retry.timeIntervalSince(now())); return
            }
            if state.pendingRevoke {
                await drainRevoke()
                if let retry = state.controlRetryAfter, state.pendingRevoke {
                    scheduleRetry(notebooks: notebooks, context: context, delay: max(0, retry.timeIntervalSince(now())))
                }
                return
            }
            guard enabled else { try await flushInvalidations(); return }
            for notebook in notebooks {
                notebook.ensureRAGIdentity()
                var folder = notebook.folder, visited: Set<String> = []
                while let current = folder {
                    current.ensureRAGIdentity()
                    guard visited.insert(current.ragID).inserted else { break }
                    folder = current.parent
                }
            }
            try context.save()
            let present = Set(notebooks.map(\.ragDocumentID))
            for id in state.entries.keys where !present.contains(id) && state.entries[id]?.settledState != "deleted" {
                state.entries[id]?.pendingState = "deleted"; state.entries[id]?.completed = false
            }
            for notebook in notebooks where state.entries[notebook.ragDocumentID] != nil && !selected(notebook) {
                invalidate(notebook: notebook, state: notebook.isTrashed ? "trashed" : notebook.isLocked || notebook.lockedPDFData != nil || notebook.encryptedContent != nil ? "locked" : "excluded")
            }
            guard save() else { return }; try await flushInvalidations()
            let reconciliationOwner = loadedPartition
            let remote = try await client.consent()
            guard reconciliationOwner == partition(), loadedPartition == reconciliationOwner, operation == reconciliationOperation else { load(); return }
            guard remote.enabled, remote.consentEpoch == state.consentEpoch, remote.available == true else { state.enabled = false; _ = save(); return }
            for notebook in notebooks where selected(notebook) {
                try Task.checkCancellation()
                var id = notebook.ragDocumentID
                activeDocument = id
                if let retry = state.entries[id]?.retryAfter, retry > now() {
                    scheduleRetry(notebooks: notebooks, context: context, delay: retry.timeIntervalSince(now()))
                    return
                }
                do {
                    if let entry = state.entries[id], entry.completed, entry.pendingState == nil,
                       entry.fingerprint == Self.fingerprint(notebook) {
                        try await refreshReadiness(id)
                    } else {
                        try await sync(notebook)
                        id = notebook.ragDocumentID  // a re-allowed PDF may have received a new document ID
                        activeDocument = id
                        try await refreshReadiness(id)
                    }
                } catch RAGIndexingService.IndexError.locked {
                    // This PDF cannot be registered right now (excluded, changed or tombstoned). It must not
                    // block the PDFs queued behind it.
                    continue
                }
                state.entries[id]?.retryAfter = nil; state.entries[id]?.retryAttempts = 0; _ = save()
                if state.entries[id]?.completed == true, state.entries[id]?.searchState != "ready",
                   (state.entries[id]?.readinessAttempts ?? 0) <= 3 {
                    scheduleRetry(notebooks: notebooks, context: context, delay: 15)
                }
            }
            state.controlRetryAfter = nil; state.controlRetryAttempts = 0; _ = save()
            errorMessage = nil; transientAttempts = 0
        } catch is CancellationError { /* Cursor remains durable; retry next foreground. */ }
        catch WorkerAIProvider.ProviderError.http(let status, _) where status == 429 {
            guard operation == reconciliationOperation else { return }
            errorMessage = "登録の混雑を待っています。自動で再試行します。"
            if let delay = recordRateLimit(document: activeDocument) {
                scheduleRetry(notebooks: notebooks, context: context, delay: delay)
            }
        }
        catch WorkerAIProvider.ProviderError.http(let status, _) where (500...599).contains(status) {
            // A transient server failure (for example a busy model) must not leave a long registration
            // stalled until the next app launch; the upload resumes from the last confirmed page.
            guard operation == reconciliationOperation else { return }
            transientAttempts += 1
            if transientAttempts <= 6 {
                errorMessage = "サーバーが一時的に混み合っています。自動で再試行します。"
                scheduleRetry(notebooks: notebooks, context: context, delay: min(60, 5 * pow(2.0, Double(transientAttempts - 1))))
            } else {
                errorMessage = "登録は完了していません。次の接続時に再試行します。"
            }
        }
        catch { errorMessage = "登録は完了していません。次の接続時に再試行します。" }
    }
    private func recordRateLimit(document id: String?) -> TimeInterval? {
        let existing = id.flatMap { state.entries[$0]?.retryAfter } ?? (id == nil ? state.controlRetryAfter : nil)
        if let existing, existing > now() { return existing.timeIntervalSince(now()) }
        let attempts = (id.flatMap { state.entries[$0]?.retryAttempts } ?? (id == nil ? state.controlRetryAttempts : nil) ?? 0) + 1
        let delay = min(120.0, 60.0 * pow(2.0, Double(attempts - 1)))
        if let id {
            if state.entries[id] == nil { state.entries[id] = .init() }
            state.entries[id]?.retryAttempts = attempts; state.entries[id]?.retryAfter = now().addingTimeInterval(delay)
        } else {
            state.controlRetryAttempts = attempts; state.controlRetryAfter = now().addingTimeInterval(delay)
        }
        guard save(), attempts <= 3 else { errorMessage = "混雑が続いています。接続を確認し、再試行してください。"; return nil }
        return delay
    }
    func setForeground(_ value: Bool) {
        let wasForeground = foreground
        foreground = value
        if !value { retryGeneration += 1; retryTask?.cancel(); retryTask = nil }
        else if !wasForeground {
            load()
            guard isManaged else { return }
            state.controlRetryAfter = nil; state.controlRetryAttempts = 0
            for id in state.entries.keys { state.entries[id]?.retryAttempts = 0; state.entries[id]?.retryAfter = nil; state.entries[id]?.readinessAttempts = 0; state.entries[id]?.readinessAfter = nil }
            _ = save()
        }
    }
    private func scheduleRetry(notebooks: [Notebook], context: ModelContext, delay: TimeInterval) {
        guard (state.controlRetryAttempts ?? 0) <= 3,
              !state.entries.values.contains(where: { $0.retryAfter != nil && ($0.retryAttempts ?? 0) > 3 }),
              retryTask == nil, foreground, (enabled || state.pendingRevoke || state.entries.values.contains(where: { $0.pendingState != nil })) else { return }
        let owner = loadedPartition, epoch = state.consentEpoch
        retryGeneration += 1; let scheduledGeneration = retryGeneration
        retryTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(max(0, delay)); try Task.checkCancellation() }
            catch { if self.retryGeneration == scheduledGeneration { self.retryTask = nil }; return }
            guard self.retryGeneration == scheduledGeneration else { return }
            self.retryTask = nil
            guard self.foreground, self.partition() == owner, self.loadedPartition == owner, (self.enabled || self.state.pendingRevoke || self.state.entries.values.contains(where: { $0.pendingState != nil })), self.state.consentEpoch == epoch else { return }
            await self.reconcile(notebooks: notebooks, context: context)
        }
    }
    private func refreshReadiness(_ id: String) async throws {
        guard let entry = state.entries[id], entry.completed, let source = entry.sourceId else { return }
        if entry.searchState == "ready" || (entry.readinessAttempts ?? 0) > 3 { return }
        if let deadline = entry.readinessAfter, deadline > now() { return }
        let owner = loadedPartition, epoch = state.consentEpoch, readinessOperation = operation
        let reply = try await client.readiness(source)
        guard foreground, owner == partition(), loadedPartition == owner, operation == readinessOperation, enabled, state.consentEpoch == epoch,
              state.entries[id]?.sourceId == source, state.entries[id]?.pendingState == nil else { return }
        let expected = entry.sourceHash
        state.entries[id]?.searchState = reply.state == "ready" && reply.sourceHash == expected && expected.count == 64 ? "ready" : "waiting"
        state.entries[id]?.readinessAttempts = (entry.readinessAttempts ?? 0) + 1
        state.entries[id]?.readinessAfter = now().addingTimeInterval(15)
        _ = save()
    }
    private func sync(_ notebook: Notebook) async throws {
        let owner = loadedPartition, epoch = state.consentEpoch, syncOperation = operation, fingerprint = Self.fingerprint(notebook)
        var id = notebook.ragDocumentID
        func check() throws {
            guard partition() == owner, loadedPartition == owner, operation == syncOperation else { throw RAGIndexingService.IndexError.accountChanged }
            guard foreground, enabled, state.consentEpoch == epoch else { throw RAGIndexingService.IndexError.locked }
            guard selected(notebook), fingerprint == Self.fingerprint(notebook) else {
                let target = notebook.isTrashed ? "trashed" : notebook.isLocked || notebook.lockedPDFData != nil || notebook.encryptedContent != nil ? "locked" : selected(notebook) ? "eligible" : "excluded"
                invalidate(notebook: notebook, state: target)
                throw RAGIndexingService.IndexError.locked
            }
            guard state.entries[id]?.pendingState == nil else { throw RAGIndexingService.IndexError.locked }
        }
        try check()
        // Retire the published generation before OCR of changed material; old excerpts
        // must not remain searchable while a lengthy scan is being processed.
        if let previous = state.entries[id], previous.fingerprint != fingerprint, previous.sourceId != nil {
            let current = try await client.document(id); try check()
            _ = try await client.invalidate(id, state: "eligible", generation: current.generation, epoch: epoch)
            try check(); state.entries[id]?.sourceId = nil; state.entries[id]?.completed = false
            guard save() else { throw RAGIndexingService.IndexError.disabled }
        }
        // A deleted document ID is a permanent server tombstone and can never be restored. Find out
        // before the long text reading, and give a re-allowed PDF a fresh document identity.
        let preflight = try await client.document(id); try check()
        if preflight.state == "deleted" {
            guard state.entries[id]?.restoreRequested == true else { throw RAGIndexingService.IndexError.locked }
            try rotateDocumentIdentity(notebook, from: id)
            id = notebook.ragDocumentID
            try check()
        }
        let structured = try RAGStructuredAttachment.prepared(notebook)
        if structured != nil {
            guard try await client.supportsStructuredIngest() else { throw RAGIndexingService.IndexError.disabled }
            try check()
        }
        let structuredPages = structured.map(RAGStructuredAttachment.pagePayloads)
        let pages: [RAGIndexingService.PageText]
        if let structured { pages = structured.pages.map { .init(pageNumber: $0.pageNumber, text: $0.text) } }
        else {
            let ocrCache = owner.map { RAGOCRPageCache(owner: $0, fingerprint: fingerprint) }
            ocrCache?.pruneStale()
            pages = try await extractor.extractManaged(notebook, whileEligible: check, onProgress: { [weak self] done, total in
                self?.progressText = "ページの文字を読み取り中 \(done)/\(total)ページ"
                self?.liveProgress[id] = 0.5 * Double(done) / Double(max(1, total))
            }, cache: ocrCache)
            progressText = nil; liveProgress[id] = 0.5
        }
        try check()
        let hash = try RAGIndexingService.sourceHash(pages)
        let remote = try await client.document(id); try check()
        if let remoteState = remote.state, remoteState != "eligible" && remoteState != "missing" {
            guard remoteState != "deleted", state.entries[id]?.restoreRequested == true else { throw RAGIndexingService.IndexError.locked }
            _ = try await client.invalidate(id, state: "eligible", generation: remote.generation, epoch: epoch); try check()
            state.entries[id]?.requestId = ""; state.entries[id]?.nextPage = 0
            guard save() else { throw RAGIndexingService.IndexError.disabled }
        }
        var entry = state.entries[id] ?? .init()
        let sameRevision = (entry.sourceId != nil && remote.generation == entry.generation)
            || (remote.generation == entry.expectedGeneration + 1 && remote.requestId == entry.requestId)
            || (entry.sourceId == nil && remote.generation == entry.expectedGeneration)
        let resumable = entry.fingerprint == fingerprint && entry.sourceHash == hash && !entry.requestId.isEmpty && sameRevision
        if !resumable {
            let latest = try await client.document(id); try check()
            entry = .init(); entry.fingerprint = fingerprint; entry.sourceHash = hash
            entry.requestId = UUID().uuidString; entry.expectedGeneration = latest.generation
            state.entries[id] = entry; guard save() else { throw RAGIndexingService.IndexError.disabled }
        }
        let prepared = try await client.prepare(id, requestId: entry.requestId, generation: entry.expectedGeneration,
            epoch: epoch, hash: hash, title: notebook.title, folder: notebook.folder?.ragID, total: pages.count)
        try check(); guard let source = prepared.sourceId else { throw WorkerAIProvider.ProviderError.malformedResponse }
        entry.totalPages = pages.count; entry.sourceId = source; entry.generation = prepared.generation; entry.settledState = nil; entry.restoreRequested = nil; state.entries[id] = entry
        guard save() else { throw RAGIndexingService.IndexError.disabled }
        while entry.nextPage < pages.count {
            try check(); try Task.checkCancellation()
            // JSON framing/UTF-8 bytes are included, not a character-count estimate.
            var batch: [RAGIndexingService.PageText] = []
            func body(_ batch: [RAGIndexingService.PageText]) -> [String: Any] {
                var value: [String: Any] = ["sourceId": source, "title": notebook.title, "kind": "pdf", "folderId": notebook.folder?.ragID as Any? ?? NSNull(),
                 "sourceHash": hash, "totalPages": pages.count, "pages": batch.map { ["pageNumber": $0.pageNumber, "text": $0.text] },
                 "control": ["documentId": id, "consentEpoch": epoch, "generation": prepared.generation]]
                if let structured, let structuredPages {
                    value["structure"] = structured.batches.first?["structure"]
                    value["pages"] = batch.map { structuredPages[$0.pageNumber] as Any }
                }
                return value
            }
            for page in pages[entry.nextPage..<min(entry.nextPage + 5, pages.count)] {
                let proposed = batch + [page]
                guard try JSONSerialization.data(withJSONObject: body(proposed)).count <= 512_000, page.text.count <= 100_000 else { break }
                batch = proposed
            }
            guard !batch.isEmpty else { throw RAGIndexingService.IndexError.oversized }
            try await client.upload(body(batch)); try check()
            entry.nextPage += batch.count; state.entries[id] = entry
            progressText = "送信中 \(entry.nextPage)/\(pages.count)ページ"
            liveProgress[id] = 0.5 + 0.5 * Double(entry.nextPage) / Double(max(1, pages.count))
            guard save() else { throw RAGIndexingService.IndexError.disabled }
        }
        if let owner { RAGOCRPageCache(owner: owner, fingerprint: fingerprint).removeAll() }
        try check(); entry.completed = true; entry.searchState = "waiting"; state.entries[id] = entry; _ = save()
    }
    func manualEnqueue(_ notebook: Notebook, context: ModelContext) async {
        load(); guard enabled else { return }
        notebook.ensureRAGIdentity()
        if state.entries[notebook.ragDocumentID] == nil { state.entries[notebook.ragDocumentID] = .init() }
        state.controlRetryAfter = nil; state.controlRetryAttempts = 0
        state.entries[notebook.ragDocumentID]?.restoreRequested = true
        state.entries[notebook.ragDocumentID]?.readinessAfter = nil; state.entries[notebook.ragDocumentID]?.readinessAttempts = 0
        state.entries[notebook.ragDocumentID]?.retryAfter = nil; state.entries[notebook.ragDocumentID]?.retryAttempts = 0
        state.excluded.removeAll { $0 == notebook.ragDocumentID }
        state.selectedAtGrant.append(notebook.ragDocumentID)
        if case .selected(var ids) = state.scope { ids.append(notebook.ragDocumentID); state.scope = .selected(ids) }
        _ = save()
        guard let all = try? context.fetch(FetchDescriptor<Notebook>()) else { return }
        await reconcile(notebooks: all, context: context)
    }
    func safeScope(_ requested: RAGSearchScope?, notebooks: [Notebook]) async -> RAGSearchScope? {
        load(); guard let requested, enabled, !state.pendingRevoke,
            !state.entries.values.contains(where: { $0.pendingState != nil }) else { return nil }
        let present = Set(notebooks.map(\.ragDocumentID))
        for (id, entry) in state.entries where entry.completed && !present.contains(id) {
            state.entries[id]?.pendingState = "deleted"; state.entries[id]?.completed = false
            guard save() else { return nil }; notify(); return nil
        }
        for notebook in notebooks where state.entries[notebook.ragDocumentID]?.completed == true {
            if !selected(notebook) || state.entries[notebook.ragDocumentID]?.fingerprint != Self.fingerprint(notebook) {
                let target = notebook.isTrashed ? "trashed" : notebook.isLocked || notebook.lockedPDFData != nil || notebook.encryptedContent != nil ? "locked" : selected(notebook) ? "eligible" : "excluded"
                invalidate(notebook: notebook, state: target); return nil
            }
        }
        let owner = loadedPartition, searchOperation = operation
        guard let remote = try? await client.consent(), owner == partition(), loadedPartition == owner, operation == searchOperation, remote.enabled,
              remote.consentEpoch == state.consentEpoch, canSearch else { return nil }
        if requested.kind == .notebook || requested.kind == .page {
            guard notebooks.contains(where: { sourceID(for: $0) == requested.sourceId }) else { return nil }
        }
        let allowed = Array(Set(notebooks.compactMap { sourceID(for: $0) }))
        guard !allowed.isEmpty, allowed.count <= 1000 else { return nil }
        var narrowed = requested
        narrowed.sourceIds = allowed.sorted()
        return narrowed
    }
    /// The server keeps a deleted document ID as a permanent tombstone. A PDF the user re-allowed gets a
    /// new ID (the old entry is dropped; the server already holds it as deleted) and keeps its place in the registration scope.
    private func rotateDocumentIdentity(_ notebook: Notebook, from old: String) throws {
        let new = UUID().uuidString
        notebook.ragDocumentID = new
        state.entries[old] = nil
        var fresh = RAGLibrarySyncState.Entry(); fresh.restoreRequested = nil
        state.entries[new] = fresh
        state.selectedAtGrant = state.selectedAtGrant.map { $0 == old ? new : $0 }
        state.excluded = state.excluded.filter { $0 != old }
        try notebook.modelContext?.save()
        guard save() else { throw RAGIndexingService.IndexError.disabled }
    }
    func isWithinScope(_ notebook: Notebook) -> Bool {
        load(); return matches(state.scope, notebook)
    }
    func isExcluded(_ notebook: Notebook) -> Bool {
        load(); return state.excluded.contains(notebook.ragDocumentID)
    }
}
