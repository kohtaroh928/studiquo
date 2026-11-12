import XCTest
import SwiftData
@testable import studiquo

@MainActor
final class RAGLibrarySyncTests: XCTestCase {
    private var previousDisclosureDefaults: UserDefaults!
    private var oldConsent = false
    /// Waits for `condition` against the clock, not a fixed number of yields: a loaded
    /// CI runner can need far more than 1000 turns of the main actor before a
    /// background task gets to run. A passing test returns as soon as it holds.
    private func waitUntil(_ description: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for: \(description)")
    }

    override func setUp() {
        super.setUp()
        previousDisclosureDefaults = AIDataDisclosure.defaults
        AIDataDisclosure.defaults = UserDefaults(suiteName: UUID().uuidString)!
        AIDataDisclosure.acknowledge(ageBand: .adult); oldConsent = RAGConsent.isGranted; RAGConsent.grant()
    }
    override func tearDown() {
        AIDataDisclosure.defaults = previousDisclosureDefaults
        if oldConsent { RAGConsent.grant() } else { RAGConsent.revoke() }
        super.tearDown()
    }
    private func pdf(_ text: String = "sample") -> Notebook {
        let notebook = Notebook(title: "Synthetic PDF")
        notebook.ensureRAGIdentity()
        let page = NotePage(order: 0, backgroundImageData: Data([1]))
        page.recognizedText = text; notebook.addPage(page); notebook.refreshLibraryMetadata()
        return notebook
    }
    func testDefaultOffDoesNotAdoptLegacyConsent() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("rag-openai-v1", forKey: "ragCloudConsentVersion")
        let service = RAGLibrarySyncService(defaults: defaults, partition: { "test-owner" })
        XCTAssertFalse(service.enabled); XCTAssertFalse(service.isManaged)
        XCTAssertNil(service.sourceID(for: pdf()))
    }
    func testOldAutomaticConsentDoesNotResumeAfterProcessorChange() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var state = RAGLibrarySyncState()
        state.enabled = true; state.consentEpoch = 1; state.scope = .allPDFs
        state.includeFuture = true
        defaults.set(try JSONEncoder().encode(state), forKey: "ragManaged-owner")
        let service = RAGLibrarySyncService(defaults: defaults, partition: { "owner" })
        XCTAssertTrue(service.isManaged)
        XCTAssertFalse(service.enabled)
        XCTAssertFalse(service.canSearch)
    }
    func testFingerprintDetectsNativeTextInkOrderAndTitle() {
        let notebook = pdf(); let original = RAGLibrarySyncService.fingerprint(notebook)
        notebook.sortedPages[0].recognizedText += " edited"
        XCTAssertNotEqual(original, RAGLibrarySyncService.fingerprint(notebook))
        let textVersion = RAGLibrarySyncService.fingerprint(notebook)
        notebook.sortedPages[0].drawingData = Data([2])
        XCTAssertNotEqual(textVersion, RAGLibrarySyncService.fingerprint(notebook))
        let inkVersion = RAGLibrarySyncService.fingerprint(notebook)
        notebook.sortedPages[0].order = 5
        XCTAssertNotEqual(inkVersion, RAGLibrarySyncService.fingerprint(notebook))
        let ordered = RAGLibrarySyncService.fingerprint(notebook)
        notebook.title = "Renamed"
        XCTAssertNotEqual(ordered, RAGLibrarySyncService.fingerprint(notebook))
    }
    func testLockTrashAndProtectedPDFExclude() {
        let notebook = pdf(); XCTAssertTrue(RAGLibrarySyncService.eligible(notebook))
        notebook.isLocked = true; XCTAssertFalse(RAGLibrarySyncService.eligible(notebook))
        notebook.isLocked = false; notebook.isTrashed = true; XCTAssertFalse(RAGLibrarySyncService.eligible(notebook))
        notebook.isTrashed = false; notebook.lockedPDFData = Data([3]); XCTAssertFalse(RAGLibrarySyncService.eligible(notebook))
        notebook.lockedPDFData = nil; notebook.encryptedContent = Data([4]); XCTAssertFalse(RAGLibrarySyncService.eligible(notebook))
    }
    func testStableDocumentIdentitySurvivesLegacySourceRotation() {
        let notebook = pdf(); let document = notebook.ragDocumentID
        _ = notebook.retireRAGSource()
        XCTAssertEqual(document, notebook.ragDocumentID)
        XCTAssertNotEqual(document, pdf().ragDocumentID)
    }

    func testGrantPreparationLeavesExcludedAndOutOfScopeNotebooksUntouched() {
        let included = pdf()
        included.ragID = ""; included.ragDocumentID = ""
        let locked = pdf()
        locked.ragID = ""; locked.ragDocumentID = ""; locked.isLocked = true
        let trashed = pdf()
        trashed.ragID = ""; trashed.ragDocumentID = ""; trashed.isTrashed = true
        let service = RAGLibrarySyncService(defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" })

        service.prepareIdentities(for: [included, locked, trashed], scope: .allPDFs)

        XCTAssertFalse(included.ragID.isEmpty)
        XCTAssertFalse(included.ragDocumentID.isEmpty)
        XCTAssertTrue(locked.ragID.isEmpty)
        XCTAssertTrue(locked.ragDocumentID.isEmpty)
        XCTAssertTrue(trashed.ragID.isEmpty)
        XCTAssertTrue(trashed.ragDocumentID.isEmpty)
    }
    func testRetryMetadataContainsNoContentOrTitle() throws {
        var state = RAGLibrarySyncState()
        state.entries["document"] = .init(fingerprint: String(repeating: "a", count: 64))
        let data = try JSONEncoder().encode(state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Synthetic PDF")); XCTAssertFalse(text.contains("sample"))
        XCTAssertFalse(text.contains("token")); XCTAssertFalse(text.contains("recognizedText"))
    }
    func testControlUsesServerBearerOwnerAndNeverBodyAccount() async throws {
        var observed: URLRequest?
        let client = RAGControlClient(transport: { request in
            observed = request
            return (Data("{\"enabled\":false,\"consentEpoch\":2}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        })
        let response = try await client.setConsent(enabled: false, epoch: 1)
        XCTAssertEqual(response.consentEpoch, 2)
        let body = try XCTUnwrap(observed?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["expectedEpoch"] as? Int, 1)
        XCTAssertNil(object["accountId"]); XCTAssertNil(object["accountKey"])
    }
    func testOfflineRevokePersistsAndSuppressesSearchAfterRestart() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = RAGControlClient(transport: { _ in throw URLError(.notConnectedToInternet) }, requestFactory: { path, _, _ in
            URLRequest(url: URL(string: "https://example.invalid/" + path)!)
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "test-owner" })
        await service.revoke()
        XCTAssertFalse(service.enabled); XCTAssertTrue(service.isManaged)
        let restarted = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "test-owner" })
        XCTAssertFalse(restarted.enabled); XCTAssertGreaterThan(restarted.pendingCount, 0)
        let scope = await restarted.safeScope(.init(kind: .library), notebooks: [])
        XCTAssertNil(scope)
        let other = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "other-owner" })
        XCTAssertFalse(other.isManaged); XCTAssertEqual(other.pendingCount, 0)
    }
    func testOldServerWithoutAvailabilityFailsClosed() async {
        let client = RAGControlClient(transport: { request in
            (Data("{\"enabled\":true,\"consentEpoch\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" })
        await service.refreshAvailability()
        XCTAssertFalse(service.available); XCTAssertFalse(service.enabled)
    }
    func testHundredPageManagedUploadResumesWithoutDuplicateCompletedBatch() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let notebook = Notebook(title: "Synthetic hundred pages")
        notebook.cachedContainsPDF = true
        for index in 0..<100 {
            let page = NotePage(order: index, backgroundImageData: Data([1]))
            page.recognizedText = "Synthetic page \(index + 1)"; notebook.addPage(page)
        }
        context.insert(notebook); try context.save()
        var preparedHash = ""
        var epoch = 0, generation = 0, uploads: [[Int]] = [], failOnce = true, prepareRequests: [String] = []
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = RAGControlClient(transport: { request in
            let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let path = request.url!.path
            var reply: [String: Any]
            if path.hasSuffix("/consent") {
                if request.httpMethod != "GET" { epoch += 1 }
                reply = ["enabled": epoch > 0, "consentEpoch": epoch, "available": true, "managed": epoch > 0]
            } else if path.hasSuffix("/readiness") {
                reply = ["state": "ready", "sourceHash": preparedHash]
            } else if path.hasSuffix("/prepare") {
                preparedHash = object["sourceHash"] as! String
                let id = object["requestId"] as! String; prepareRequests.append(id)
                generation = 1
                reply = ["generation": 1, "consentEpoch": epoch, "sourceId": "managed-source"]
            } else if path.hasSuffix("/index") {
                let pages = object["pages"] as! [[String: Any]]
                if uploads.count == 3 && failOnce { failOnce = false; throw URLError(.notConnectedToInternet) }
                uploads.append(pages.map { $0["pageNumber"] as! Int }); reply = [:]
                XCTAssertLessThanOrEqual(request.httpBody!.count, 512_000)
                XCTAssertNotNil(object["control"])
            } else { reply = ["generation": generation, "state": generation == 0 ? "missing" : "eligible"] }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "synthetic-owner" })
        try await service.grant(scope: .allPDFs, includeFuture: false, context: context, notebooks: [notebook])
        await service.reconcile(notebooks: [notebook], context: context)
        XCTAssertEqual(uploads.count, 3); XCTAssertEqual(service.registeredCount, 0)
        let restarted = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "synthetic-owner" })
        await restarted.reconcile(notebooks: [notebook], context: context)
        XCTAssertEqual(uploads.count, 20)
        XCTAssertEqual(uploads.flatMap { $0 }, Array(1...100))
        XCTAssertEqual(Set(prepareRequests).count, 1)
        XCTAssertEqual(restarted.sourceID(for: notebook), "managed-source")
        notebook.sortedPages[0].recognizedText += " changed"
        XCTAssertNil(restarted.sourceID(for: notebook))
    }

    func testRevokeDuringGrantNeverRestoresLocalConsent() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var epoch = 0
        var service: RAGLibrarySyncService?
        let client = RAGControlClient(transport: { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let enabling = body["enabled"] as? Bool
            if enabling != nil { epoch += 1 }
            let responseEpoch = epoch
            if enabling == true { await service?.revoke() }
            let reply: [String: Any] = ["enabled": enabling ?? false, "consentEpoch": responseEpoch, "available": true]
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" })
        do {
            try await service!.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [])
            XCTFail("An obsolete grant must fail")
        } catch { }
        XCTAssertFalse(service!.enabled); XCTAssertFalse(service!.canSearch)
    }

    func testLockedPDFScopeInvalidationNeverRestoresEligibility() async throws {
        let notebook = pdf(); let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState()
        saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.consentEpoch = 1; saved.scope = .allPDFs; saved.includeFuture = true
        saved.entries[notebook.ragDocumentID] = .init(fingerprint: RAGLibrarySyncService.fingerprint(notebook), sourceId: "managed-source", completed: true, searchState: "ready")
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        let offlineClient = RAGControlClient(transport: { _ in throw URLError(.notConnectedToInternet) },
            requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: offlineClient, defaults: defaults, partition: { "owner" })
        notebook.isLocked = true
        let scope = await service.safeScope(.init(kind: .library), notebooks: [notebook])
        XCTAssertNil(scope)
        let updated = try JSONDecoder().decode(RAGLibrarySyncState.self, from: defaults.data(forKey: "ragManaged-owner")!)
        XCTAssertEqual(updated.entries[notebook.ragDocumentID]?.pendingState, "locked")
        XCTAssertFalse(service.canSearch)
    }
    func testSearchAllowListContainsOnlyCurrentLocalEligibleSources() async throws {
        let notebook = pdf(); let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState()
        saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.consentEpoch = 1; saved.scope = .allPDFs; saved.includeFuture = true
        saved.entries[notebook.ragDocumentID] = .init(fingerprint: RAGLibrarySyncService.fingerprint(notebook), sourceId: "current-source", completed: true, searchState: "ready")
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        let client = RAGControlClient(transport: { request in
            (Data("{\"enabled\":true,\"consentEpoch\":1,\"available\":true}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" })
        let scope = await service.safeScope(.init(kind: .library), notebooks: [notebook])
        XCTAssertEqual(scope?.sourceIds, ["current-source"])
        XCTAssertNil(service.resolve(.init(sourceId: "unknown-other-device-source", title: "Synthetic", pageNumber: 1, chunkId: "chunk"), notebooks: [notebook]))
    }

    func testRemoteLockedDocumentCannotBeAutomaticallyRestoredFromStaleUnlockedDevice() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let notebook = pdf(); container.mainContext.insert(notebook)
        var epoch = 0, restoreCalls = 0, uploadCalls = 0, prepareCalls = 0
        let client = RAGControlClient(transport: { request in
            let path = request.url!.path
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var reply: [String: Any]
            if path.hasSuffix("/consent") {
                if request.httpMethod != "GET" { epoch += 1 }
                reply = ["enabled": epoch > 0, "consentEpoch": epoch, "available": true]
            } else if path.hasSuffix("/state") {
                if body["state"] as? String == "eligible" { restoreCalls += 1 }
                reply = ["generation": 7, "state": "locked", "sourceId": NSNull()]
            } else if path.hasSuffix("/prepare") {
                prepareCalls += 1; reply = ["generation": 8, "sourceId": "new-source"]
            } else { uploadCalls += 1; reply = [:] }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" })
        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [notebook])
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        XCTAssertEqual(restoreCalls, 0); XCTAssertEqual(prepareCalls, 0); XCTAssertEqual(uploadCalls, 0)
        XCTAssertNil(service.sourceID(for: notebook))
    }

    func testLockInvalidationRunsWhileUploadIsSuspended() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let notebook = pdf(); container.mainContext.insert(notebook)
        var epoch = 0, generation = 0, remoteState = "missing", invalidations = 0
        var releaseUpload: CheckedContinuation<Void, Never>?
        let client = RAGControlClient(transport: { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var reply: [String: Any]
            if request.url!.path.hasSuffix("/consent") {
                if request.httpMethod != "GET" { epoch += 1 }
                reply = ["enabled": true, "consentEpoch": epoch, "available": true]
            } else if request.url!.path.hasSuffix("/prepare") {
                generation = 1; remoteState = "eligible"; reply = ["generation": generation, "sourceId": "managed-source"]
            } else if request.url!.path.hasSuffix("/state") {
                if let next = body["state"] as? String { invalidations += 1; generation += 1; remoteState = next }
                reply = ["generation": generation, "state": remoteState]
            } else {
                await withCheckedContinuation { releaseUpload = $0 }
                reply = [:]
            }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" })
        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [notebook])
        let upload = Task { await service.reconcile(notebooks: [notebook], context: container.mainContext) }
        await waitUntil("the upload to start") { releaseUpload != nil }
        guard let release = releaseUpload else { upload.cancel(); XCTFail("Upload did not begin"); return }
        notebook.isLocked = true
        service.invalidate(notebook: notebook, state: "locked")
        await waitUntil("the invalidation to be sent") { invalidations > 0 }
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(remoteState, "locked")
        release.resume(); await upload.value
        XCTAssertNil(service.sourceID(for: notebook)); XCTAssertEqual(service.registeredCount, 0)
    }

    func testUploadCompleteWaitsForReadinessWithoutReupload() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let notebook = pdf(); container.mainContext.insert(notebook)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let hash = String(repeating: "a", count: 64)
        var saved = RAGLibrarySyncState(); saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.consentEpoch = 1; saved.scope = .allPDFs; saved.includeFuture = true
        saved.entries[notebook.ragDocumentID] = .init(fingerprint: RAGLibrarySyncService.fingerprint(notebook), sourceHash: hash, sourceId: "source", completed: true, searchState: "waiting")
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        var ready = false, readinessCalls = 0, uploadCalls = 0
        var currentTime = Date(timeIntervalSince1970: 100)
        let client = RAGControlClient(transport: { request in
            var reply: [String: Any]
            if request.url!.path.hasSuffix("/readiness") {
                readinessCalls += 1; reply = ["state": ready ? "ready" : "waiting", "sourceHash": hash]
            } else if request.url!.path.hasSuffix("/consent") {
                reply = ["enabled": true, "consentEpoch": 1, "available": true]
            } else { uploadCalls += 1; reply = [:] }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" }, now: { currentTime }, sleep: { _ in throw CancellationError() })
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        XCTAssertEqual(service.waitingCount, 1); XCTAssertNil(service.sourceID(for: notebook))
        let waitingScope = await service.safeScope(.init(kind: .library), notebooks: [notebook])
        XCTAssertNil(waitingScope); XCTAssertEqual(service.waitingCount, 1); XCTAssertEqual(uploadCalls, 0)
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        XCTAssertEqual(readinessCalls, 1)
        currentTime = currentTime.addingTimeInterval(20); ready = true
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        XCTAssertEqual(service.searchableCount, 1); XCTAssertEqual(service.sourceID(for: notebook), "source")
        XCTAssertEqual(readinessCalls, 2); XCTAssertEqual(uploadCalls, 0)
        service.setForeground(false)
    }
    func testRateLimitedUploadAutomaticallyResumesWithInjectedBackoff() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let notebook = pdf(); container.mainContext.insert(notebook)
        var epoch = 0, generation = 0, uploadCalls = 0, sourceHash = ""
        var currentTime = Date(timeIntervalSince1970: 100), delays: [TimeInterval] = []
        let client = RAGControlClient(transport: { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var reply: [String: Any], status = 200
            let path = request.url!.path
            if path.hasSuffix("/consent") {
                if request.httpMethod != "GET" { epoch += 1 }; reply = ["enabled": true, "consentEpoch": epoch, "available": true]
            } else if path.hasSuffix("/readiness") { reply = ["state": "ready", "sourceHash": sourceHash] }
            else if path.hasSuffix("/state") { reply = ["state": generation == 0 ? "missing" : "eligible", "generation": generation] }
            else if path.hasSuffix("/prepare") {
                generation = 1; sourceHash = body["sourceHash"] as! String; reply = ["sourceId": "source", "generation": 1]
            } else { uploadCalls += 1; status = uploadCalls == 1 ? 429 : 200; reply = [:] }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "owner" }, now: { currentTime }, sleep: { delay in
            delays.append(delay); currentTime = currentTime.addingTimeInterval(delay); await Task.yield()
        })
        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [notebook])
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        await waitUntil("the rate-limited upload to resume") { service.searchableCount == 1 }
        XCTAssertEqual(uploadCalls, 2); XCTAssertEqual(delays, [60])
        XCTAssertEqual(service.searchableCount, 1)
        service.setForeground(false)
    }

    func testFolderScopeIncludesDescendantsButExcludesFutureAndOtherFolders() throws {
        let parent = Folder(name: "Synthetic parent"), child = Folder(name: "Synthetic child")
        parent.ensureRAGIdentity(); child.ensureRAGIdentity(); child.parent = parent
        let notebook = pdf(); notebook.folder = child
        let future = pdf(); future.folder = child
        let unrelated = pdf(); unrelated.folder = Folder(name: "Synthetic unrelated")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState(); saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.scope = .folder(parent.ragID)
        saved.selectedAtGrant = [notebook.ragDocumentID]
        for document in [notebook, future, unrelated] {
            saved.entries[document.ragDocumentID] = .init(fingerprint: RAGLibrarySyncService.fingerprint(document), sourceId: document.ragDocumentID, completed: true, searchState: "ready")
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        let service = RAGLibrarySyncService(defaults: defaults, partition: { "owner" })
        XCTAssertTrue(service.isWithinScope(notebook)); XCTAssertFalse(service.isWithinScope(unrelated))
        XCTAssertNotNil(service.sourceID(for: notebook)); XCTAssertNil(service.sourceID(for: future)); XCTAssertNil(service.sourceID(for: unrelated))
    }
    func testAccountAndEndpointPartitionNeverAdoptPreviousMapping() throws {
        let notebook = pdf(); let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState(); saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.scope = .allPDFs; saved.includeFuture = true
        saved.entries[notebook.ragDocumentID] = .init(fingerprint: RAGLibrarySyncService.fingerprint(notebook), sourceId: "owner-a-source", completed: true, searchState: "ready")
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-account-a-endpoint-a")
        var owner = "account-a-endpoint-a"
        let service = RAGLibrarySyncService(defaults: defaults, partition: { owner })
        XCTAssertNotNil(service.sourceID(for: notebook))
        owner = "account-b-endpoint-a"; XCTAssertNil(service.sourceID(for: notebook)); XCTAssertFalse(service.canSearch)
        owner = "account-a-endpoint-b"; XCTAssertNil(service.sourceID(for: notebook)); XCTAssertFalse(service.canSearch)
    }
    func testControlRateLimitAutomaticallyRetriesWithoutDocument() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState(); saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.consentEpoch = 1
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        var calls = 0, currentTime = Date(timeIntervalSince1970: 100), delays: [TimeInterval] = []
        let client = RAGControlClient(transport: { request in
            calls += 1
            return (Data("{\"enabled\":true,\"consentEpoch\":1,\"available\":true}".utf8), HTTPURLResponse(url: request.url!, statusCode: calls == 1 ? 429 : 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" }, now: { currentTime }, sleep: { delay in
            delays.append(delay); currentTime = currentTime.addingTimeInterval(delay); await Task.yield()
        })
        await service.reconcile(notebooks: [], context: container.mainContext)
        await waitUntil("both calls to finish") { calls == 2 && !service.busy }
        XCTAssertEqual(calls, 2); XCTAssertEqual(delays, [60]); XCTAssertTrue(service.enabled)
        service.setForeground(false)
    }

    func testManualGrantClearsPreviousControlRetryAndContactsConsentService() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState()
        saved.controlRetryAfter = Date(timeIntervalSince1970: 160)
        saved.controlRetryAttempts = 2
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        var requests = 0, epoch = 0
        let client = RAGControlClient(transport: { request in
            requests += 1
            if request.httpMethod != "GET" { epoch += 1 }
            let reply: [String: Any] = ["enabled": epoch > 0, "consentEpoch": epoch, "available": true]
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" }, now: { Date(timeIntervalSince1970: 100) })

        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [])

        XCTAssertEqual(requests, 2)
        XCTAssertTrue(service.enabled)
        let updated = try JSONDecoder().decode(RAGLibrarySyncState.self, from: try XCTUnwrap(defaults.data(forKey: "ragManaged-owner")))
        XCTAssertNil(updated.controlRetryAfter)
        XCTAssertEqual(updated.controlRetryAttempts, 0)
    }

    func testManualGrantDoesNotRequireOldInvalidationQueueToReachConsentService() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState()
        saved.entries["stale-document"] = .init(pendingState: "deleted")
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        var requests: [String] = [], epoch = 0
        let client = RAGControlClient(transport: { request in
            requests.append(request.url!.path)
            if request.url!.path.contains("documents/stale-document") {
                throw WorkerAIProvider.ProviderError.http(status: 503, message: "")
            }
            if request.httpMethod != "GET" { epoch += 1 }
            let reply: [String: Any] = ["enabled": epoch > 0, "consentEpoch": epoch, "available": true]
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" })

        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [])

        XCTAssertEqual(requests, ["/api/rag/consent", "/api/rag/consent"])
        XCTAssertTrue(service.enabled)
    }

    func testBackgroundCancelsScheduledControlRetry() async throws {
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState(); saved.processorConsentVersion = RAGConsent.version; saved.enabled = true; saved.consentEpoch = 1
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")
        var calls = 0
        var releaseSleep: CheckedContinuation<Void, Never>?
        let client = RAGControlClient(transport: { request in
            calls += 1
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, _, _ in URLRequest(url: URL(string: "https://example.invalid/" + path)!) })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" }, sleep: { _ in
            await withCheckedContinuation { releaseSleep = $0 }
        })
        await service.reconcile(notebooks: [], context: container.mainContext)
        await waitUntil("the backoff sleep to start") { releaseSleep != nil }
        guard let release = releaseSleep else { service.setForeground(false); XCTFail("Retry was not scheduled"); return }
        service.setForeground(false)
        release.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(defaults.data(forKey: "ragManaged-owner") != nil)
    }

    func testUnmanagedForegroundCycleNeverUpgradesLegacyAccount() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = RAGLibrarySyncService(defaults: defaults, partition: { "legacy-owner" })
        service.setForeground(false); service.setForeground(true)
        XCTAssertFalse(service.isManaged); XCTAssertFalse(service.enabled); XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNil(defaults.data(forKey: "ragManaged-legacy-owner"))
    }

    func testGrantErrorLocalPersistenceDescriptionAndGrantPropagatesServerFailureWithoutEnabling() async throws {
        XCTAssertEqual(
            RAGLibrarySyncService.GrantError.localPersistence.errorDescription,
            L("この端末の資料情報を保存できなかったため、自動登録を開始しませんでした。資料を閉じてからもう一度お試しください。")
        )

        let container = try ModelContainer(
            for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let client = RAGControlClient(transport: { request in
            if request.httpMethod == "GET" {
                let reply: [String: Any] = ["enabled": false, "consentEpoch": 0, "available": true]
                return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let errBody = #"{"error":"AI機能は公開準備中です。学習資料は送信されません。"}"#
            return (Data(errBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" }, now: { Date(timeIntervalSince1970: 200) })

        do {
            try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [])
            XCTFail("Expected server 503 to be thrown")
        } catch let WorkerAIProvider.ProviderError.http(status, _) {
            XCTAssertEqual(status, 503)
        }

        XCTAssertFalse(service.enabled)
        let saved = try JSONDecoder().decode(RAGLibrarySyncState.self, from: try XCTUnwrap(defaults.data(forKey: "ragManaged-owner")))
        XCTAssertFalse(saved.enabled)
        XCTAssertTrue(saved.pendingRevoke, "interrupted grant persists pendingRevoke so remote consent is cleaned up")
    }

    func testRevokeFailureFollowedByManualGrantDrainsPendingRevokeThenEnablesCleanly() async throws {
        let container = try ModelContainer(
            for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var saved = RAGLibrarySyncState()
        saved.processorConsentVersion = RAGConsent.version
        saved.enabled = true
        saved.consentEpoch = 2
        defaults.set(try JSONEncoder().encode(saved), forKey: "ragManaged-owner")

        var failDisableOnce = true
        var epoch = 2
        var remoteEnabled = true
        var postedStates: [Bool] = []
        let client = RAGControlClient(transport: { request in
            if request.httpMethod == "GET" {
                let reply: [String: Any] = ["enabled": remoteEnabled, "consentEpoch": epoch, "available": true]
                return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let targetEnabled = body?["enabled"] as? Bool ?? false
            if !targetEnabled && failDisableOnce {
                failDisableOnce = false
                throw WorkerAIProvider.ProviderError.http(status: 503, message: "temporary outage")
            }
            remoteEnabled = targetEnabled
            epoch += 1
            postedStates.append(targetEnabled)
            let reply: [String: Any] = ["enabled": remoteEnabled, "consentEpoch": epoch, "available": true]
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: defaults, partition: { "owner" })

        // 1. User revokes while server is temporarily down -> local enabled is false and pendingRevoke is true.
        await service.revoke()
        XCTAssertFalse(service.enabled)
        let afterFailedRevoke = try JSONDecoder().decode(RAGLibrarySyncState.self, from: try XCTUnwrap(defaults.data(forKey: "ragManaged-owner")))
        XCTAssertTrue(afterFailedRevoke.pendingRevoke)

        // 2. User manually grants again once connectivity returns -> drains the pending revoke (false) and then grants (true).
        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [])
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(postedStates, [false, true], "must complete pending revoke first and then enable consent")
        let afterRegrant = try JSONDecoder().decode(RAGLibrarySyncState.self, from: try XCTUnwrap(defaults.data(forKey: "ragManaged-owner")))
        XCTAssertTrue(afterRegrant.enabled)
        XCTAssertFalse(afterRegrant.pendingRevoke)
        XCTAssertEqual(afterRegrant.consentEpoch, 4)
    }

}
