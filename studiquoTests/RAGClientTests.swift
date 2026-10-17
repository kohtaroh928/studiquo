import XCTest
import SwiftData
import UIKit
@testable import studiquo

@MainActor
final class RAGClientTests: XCTestCase {
    private var defaults: UserDefaults!
    private var oldDefaults: UserDefaults!
    private var consentWasGranted = false
    override func setUp() {
        super.setUp()
        oldDefaults = AIDataDisclosure.defaults
        defaults = UserDefaults(suiteName: "RAGClientTests-\(UUID().uuidString)")!
        AIDataDisclosure.defaults = defaults
        AIDataDisclosure.acknowledge(ageBand: .adult)
        consentWasGranted = RAGConsent.isGranted
        RAGConsent.grant()
    }
    override func tearDown() {
        AIDataDisclosure.defaults = oldDefaults
        if consentWasGranted { RAGConsent.grant() } else { RAGConsent.revoke() }
        super.tearDown()
    }
    private func response(_ request: URLRequest, json: String = "{}") -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func testOldRAGConsentDoesNotAuthorizeOpenAI() {
        UserDefaults.standard.set("rag-v1", forKey: "ragCloudConsentVersion")
        defer { RAGConsent.grant() }
        XCTAssertFalse(RAGConsent.isGranted)
    }
    func testHundredPagePDFUploadsTwentyBatchesWithCorrectPageNumbers() async throws {
        let notebook = Notebook(title: "Generated PDF fixture")
        notebook.cachedContainsPDF = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rag-synthetic-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 180, height: 100))
        try renderer.writePDF(to: url) { context in
            for index in 0..<100 {
                context.beginPage()
                ("Synthetic page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 10, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
            }
        }
        let extracted = PDFImportService.extractPages(from: url, scale: 0.5)
        XCTAssertEqual(extracted.count, 100)
        for (index, item) in extracted.enumerated() {
            XCTAssertTrue(item.text.contains("Synthetic page \(index + 1)"))
            let page = NotePage(order: index, backgroundImageData: item.imageData)
            page.recognizedText = item.text
            notebook.addPage(page)
        }
        var uploads: [[String: Any]] = []
        let service = RAGIndexingService { request in
            if request.httpMethod == "GET" { return self.response(request, json: "{\"enabled\":true}") }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-RAG-Consent"), "rag-openai-v1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-AI-Consent"), "openai-v1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-Age"), "adult")
            uploads.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
            return self.response(request)
        }
        var progress: [Int] = []
        let result = try await service.index(notebook) { sent, total in
            XCTAssertEqual(total, 100)
            progress.append(sent)
        }
        XCTAssertEqual(progress, Array(stride(from: 5, through: 100, by: 5)))
        XCTAssertEqual(result.sourceId, notebook.ragID)
        XCTAssertEqual(result.sourceHash, uploads.first?["sourceHash"] as? String)
        XCTAssertEqual(uploads.count, 20)
        let pages = uploads.flatMap { $0["pages"] as! [[String: Any]] }
        XCTAssertEqual(pages.map { $0["pageNumber"] as! Int }, Array(1...100))
        XCTAssertTrue(uploads.allSatisfy { ($0["pages"] as! [Any]).count == 5 })
        XCTAssertEqual(Set(uploads.map { $0["sourceHash"] as! String }).count, 1)
        XCTAssertTrue(uploads.allSatisfy { $0["accountId"] == nil && $0["accountKey"] == nil })
    }
    func testEditableNotebookDoesNotUploadStaleRecognizedTextAfterInkErasure() async throws {
        let notebook = Notebook(title: "Synthetic fixture")
        let page = NotePage(order: 0)
        page.recognizedText = "Synthetic erased ink cache"
        notebook.addPage(page)
        var uploadedText: String?
        let service = RAGIndexingService { request in
            if request.httpMethod == "GET" { return self.response(request, json: "{\"enabled\":true}") }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            uploadedText = (body["pages"] as! [[String: Any]]).first?["text"] as? String
            return self.response(request)
        }
        try await service.index(notebook)
        XCTAssertEqual(uploadedText, "")
    }

    func testSourceHashStableAndSensitiveToPageChanges() throws {
        let pages = [RAGIndexingService.PageText(pageNumber: 1, text: "Synthetic text")]
        XCTAssertEqual(try RAGIndexingService.sourceHash(pages), try RAGIndexingService.sourceHash(pages))
        XCTAssertNotEqual(try RAGIndexingService.sourceHash(pages), try RAGIndexingService.sourceHash([.init(pageNumber: 1, text: "Changed synthetic text")]))
    }
    func testLockedNotebookExcludedEvenWhenContentIsUnlocked() async {
        let notebook = Notebook(title: "Protected synthetic fixture")
        notebook.isLocked = true
        notebook.encryptedContent = nil
        var requests = 0
        let service = RAGIndexingService { request in requests += 1; return self.response(request) }
        do { try await service.index(notebook); XCTFail("Must reject locked notebooks") }
        catch { XCTAssertEqual(requests, 0) }
    }
    func testPasswordProtectedPDFIsExcludedAfterLocalUnlock() async {
        let notebook = Notebook(title: "Protected synthetic fixture")
        notebook.lockedPDFData = Data([0])
        var requests = 0
        let service = RAGIndexingService { request in requests += 1; return self.response(request) }
        do { try await service.index(notebook); XCTFail("Must reject password protected PDFs") }
        catch { XCTAssertEqual(requests, 0) }
    }

    func testDisabledDoesNotUpload() async {
        var uploads = 0
        let service = RAGIndexingService { request in
            if request.httpMethod != "GET" { uploads += 1 }
            return self.response(request, json: "{\"enabled\":false}")
        }
        do { try await service.index(Notebook(title: "Synthetic fixture")); XCTFail("Expected disabled") }
        catch { XCTAssertEqual(uploads, 0) }
    }
    func testScopePayloadPreservesNotebookFolderAndOneBasedPage() {
        let folder = RAGSearchScope(kind: .folder, folderId: "folder-fixture")
        XCTAssertEqual(folder.payload["folderId"] as? String, "folder-fixture")
        XCTAssertNil(folder.payload["sourceId"])
        let page = RAGSearchScope(kind: .page, sourceId: "source-fixture", pageNumber: 7)
        XCTAssertEqual(page.payload["pageNumber"] as? Int, 7)
    }
    func testCitationNavigationResolvesCorrectSourceAndPageAndRejectsLocked() {
        let first = Notebook(title: "First synthetic fixture")
        let second = Notebook(title: "Second synthetic fixture")
        for index in 0..<4 { second.addPage(NotePage(order: index)) }
        let citation = RAGCitation(sourceId: second.ragID, title: second.title, pageNumber: 3, chunkId: "chunk-fixture")
        let result = RAGCitationNavigation.resolve(citation, notebooks: [first, second])
        XCTAssertTrue(result?.0 === second)
        XCTAssertEqual(result?.1, 2)
        RAGCitationNavigation.open(citation)
        XCTAssertNil(RAGCitationNavigation.consume(for: first))
        XCTAssertEqual(RAGCitationNavigation.consume(for: second), 2)
        XCTAssertNil(RAGCitationNavigation.consume(for: second))
        second.isLocked = true
        XCTAssertNil(RAGCitationNavigation.resolve(citation, notebooks: [second]))
    }
    func testDeletedSourceRotatesIdentityButHistoricalCitationsStillResolve() {
        let notebook = Notebook(title: "Synthetic fixture")
        notebook.addPage(NotePage(order: 0))
        let previous = notebook.retireRAGSource()
        XCTAssertNotEqual(previous, notebook.ragID)
        let citation = RAGCitation(sourceId: previous, title: notebook.title, pageNumber: 1, chunkId: "synthetic-chunk")
        XCTAssertEqual(RAGCitationNavigation.resolve(citation, notebooks: [notebook])?.1, 0)
    }

    func testPageStructuralChangesInvalidateHistoricalCitations() {
        let notebook = Notebook(title: "Synthetic fixture")
        for index in 0..<4 { notebook.addPage(NotePage(order: index)) }
        let previous = notebook.retireRAGSource()
        let citation = RAGCitation(sourceId: previous, title: notebook.title, pageNumber: 3, chunkId: "synthetic-chunk")
        _ = notebook.retireRAGSource(preservingCitations: false)
        notebook.pages?.removeFirst()
        XCTAssertNil(RAGCitationNavigation.resolve(citation, notebooks: [notebook]))
    }

    func testCitationEventPersistenceAndPageValidation() {
        let event = Data("{\"citations\":[{\"sourceId\":\"source-fixture\",\"title\":\"Synthetic\",\"pageNumber\":2,\"chunkId\":\"chunk-fixture\"}]}".utf8)
        let message = AIChatMessage(text: "Synthetic reply", role: .assistant)
        message.ragCitations = RAGCitation.decodeEvent(event) ?? []
        XCTAssertEqual(message.ragCitations.first?.pageNumber, 2)
        XCTAssertNotNil(message.ragCitationsData)
    }
    func testSourceDeletionUsesAuthenticatedDeleteWithoutCloudStorageConsent() async throws {
        RAGConsent.revoke()
        AIDataDisclosure.revoke()
        var sent: URLRequest?
        let service = RAGIndexingService { request in sent = request; return self.response(request) }
        try await service.delete(sourceId: "synthetic-source")
        XCTAssertEqual(sent?.httpMethod, "DELETE")
        XCTAssertTrue(sent?.url?.path.hasSuffix("api/rag/source") == true)
        XCTAssertTrue(sent?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }
    func testRetrievalStatusDecodesAllKnownStatesAndRejectsUnknownOrLegacyEvents() {
        for status in RAGRetrievalStatus.allCases {
            let data = Data("{\"ragStatus\":\"\(status.rawValue)\"}".utf8)
            XCTAssertEqual(RAGRetrievalStatus.decodeEvent(data, acceptingRAG: true), status)
            XCTAssertNil(RAGRetrievalStatus.decodeEvent(data, acceptingRAG: false))
            XCTAssertFalse(status.explanation.isEmpty)
        }
        for json in ["{\"ragStatus\":\"future-state\"}", "{\"text\":\"Synthetic answer\"}", "{\"ragStatus\":null}", "invalid"] {
            XCTAssertNil(RAGRetrievalStatus.decodeEvent(Data(json.utf8), acceptingRAG: true))
        }
    }

    func testRetrievalStatusConsentRevocationStopsAcceptingEvents() {
        let event = Data("{\"ragStatus\":\"grounded\"}".utf8)
        XCTAssertEqual(RAGRetrievalStatus.decodeEvent(event, acceptingRAG: RAGConsent.isGranted), .grounded)
        RAGConsent.revoke()
        XCTAssertNil(RAGRetrievalStatus.decodeEvent(event, acceptingRAG: RAGConsent.isGranted))
    }

    func testRetrievalStatusPersistsAndLegacyMessagesRemainWithoutStatus() throws {
        let container = try ModelContainer(for: AIChatThread.self, AIChatMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let message = AIChatMessage(text: "Synthetic evidence reply", role: .assistant)
        XCTAssertNil(message.ragStatus)
        message.ragStatus = .partial
        context.insert(message)
        try context.save()
        let fetched = try ModelContext(container).fetch(FetchDescriptor<AIChatMessage>())
        XCTAssertEqual(fetched.first?.ragStatus, .partial)
        XCTAssertEqual(fetched.first?.ragStatusRawValue, "partial")
        message.ragStatusRawValue = "future-state"
        XCTAssertNil(message.ragStatus)
        message.ragStatus = nil
        XCTAssertNil(message.ragStatusRawValue)
    }

    func testStatusOverloadKeepsLegacyProviderBehaviorAndEmitsNoStatus() async throws {
        let provider: any AIProvider = LegacyRAGTestProvider()
        var text = ""
        var statuses: [RAGRetrievalStatus] = []
        var citations: [RAGCitation] = []
        try await provider.streamChat(turns: [.init(role: .user, text: "Synthetic question")],
                                      noteContext: "", images: [], expectsImages: false,
                                      ragScope: .init(kind: .library), onCitations: { citations += $0 },
                                      onRAGStatus: { statuses.append($0) }, onDelta: { text += $0 })
        XCTAssertEqual(text, "Synthetic legacy reply")
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(citations.isEmpty)
    }


    func testReadinessWaitsForVisibilityAndDoesNotReuploadText() async throws {
        var requests = 0
        var states: [RAGRegistrationState] = []
        let hash = String(repeating: "a", count: 64)
        let service = RAGIndexingService(sleep: {}) { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertTrue(request.url!.path.hasSuffix("/sources/synthetic-source/readiness"))
            return self.response(request, json: requests == 1 ? "{\"state\":\"waiting\"}" :
                "{\"state\":\"ready\",\"sourceHash\":\"\(hash)\"}")
        }
        let final = try await service.waitUntilSearchable(sourceId: "synthetic-source", expectedHash: hash,
                                                          maxAttempts: 3, onState: { states.append($0) })
        XCTAssertEqual(final, .ready)
        XCTAssertEqual(states, [.waiting, .ready])
        XCTAssertEqual(requests, 2)
    }
    func testReadinessOldServerAndUnknownReplyNeverClaimReady() async throws {
        for (code, json) in [(404, "{}"), (200, "{\"complete\":1}"),
                              (200, "{\"state\":\"future\"}"), (200, "{\"state\":\"ready\"}")] {
            let service = RAGIndexingService(sleep: {}) { request in
                (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            let state = try await service.waitUntilSearchable(sourceId: "synthetic-source", maxAttempts: 1)
            XCTAssertEqual(state, .waiting)
        }
    }
    func testReadinessWrongRevisionAndTimeoutStayWaiting() async throws {
        var requests = 0
        let service = RAGIndexingService(sleep: {}) { request in
            requests += 1
            return self.response(request, json: "{\"state\":\"ready\",\"sourceHash\":\"\(String(repeating: "b", count: 64))\"}")
        }
        let state = try await service.waitUntilSearchable(sourceId: "synthetic-source", expectedHash: String(repeating: "a", count: 64), maxAttempts: 2)
        XCTAssertEqual(state, .waiting)
        XCTAssertEqual(requests, 2)
    }
    func testReadinessRateLimitAndOutageRetryWithinBound() async throws {
        for code in [429, 503] {
            var requests = 0
            let service = RAGIndexingService(sleep: {}) { request in
                requests += 1
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            let state = try await service.waitUntilSearchable(sourceId: "synthetic-source", maxAttempts: 2)
            XCTAssertEqual(state, .waiting)
            XCTAssertEqual(requests, 2)
        }
    }
    func testReadinessAccountChangeDropsLateReadyResponse() async throws {
        var owner: String? = "synthetic-first"
        var states: [RAGRegistrationState] = []
        let service = RAGIndexingService(accountPartition: { owner }, sleep: {}) { request in
            owner = "synthetic-second"
            return self.response(request, json: "{\"state\":\"ready\",\"sourceHash\":\"\(String(repeating: "a", count: 64))\"}")
        }
        do {
            _ = try await service.waitUntilSearchable(sourceId: "synthetic-source", onState: { states.append($0) })
            XCTFail("Account change must stop polling")
        } catch { XCTAssertTrue(states.isEmpty) }
    }
    func testReadinessConsentRevocationAndSourceChangeDropLateResponse() async throws {
        for revoke in [true, false] {
            RAGConsent.grant()
            var eligible = true
            var states: [RAGRegistrationState] = []
            let service = RAGIndexingService(sleep: {}) { request in
                if revoke { RAGConsent.revoke() } else { eligible = false }
                return self.response(request, json: "{\"state\":\"ready\",\"sourceHash\":\"\(String(repeating: "a", count: 64))\"}")
            }
            do {
                _ = try await service.waitUntilSearchable(sourceId: "synthetic-source", whileEligible: { eligible }, onState: { states.append($0) })
                XCTFail("Invalidated operation must stop polling")
            } catch { XCTAssertTrue(states.isEmpty) }
        }
    }
    func testReadinessCancellationDoesNotEmitReady() async throws {
        var states: [RAGRegistrationState] = []
        let service = RAGIndexingService(sleep: { throw CancellationError() }) { request in
            self.response(request, json: "{\"state\":\"waiting\"}")
        }
        do {
            _ = try await service.waitUntilSearchable(sourceId: "synthetic-source", maxAttempts: 2, onState: { states.append($0) })
            XCTFail("Expected cancellation")
        } catch is CancellationError { XCTAssertEqual(states, [.waiting]) }
    }
    func testReadinessCancelledDuringTransportDropsLateReady() async throws {
        var states: [RAGRegistrationState] = []
        let service = RAGIndexingService(sleep: {}) { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return self.response(request, json: "{\"state\":\"ready\",\"sourceHash\":\"\(String(repeating: "a", count: 64))\"}")
        }
        let task = Task { @MainActor in
            try await service.waitUntilSearchable(sourceId: "synthetic-source", onState: { states.append($0) })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation before publishing ready") }
        catch is CancellationError { XCTAssertTrue(states.isEmpty) }
    }
    func testRegistrationStateDescriptionsAndTerminalStates() async throws {
        for state in [RAGRegistrationState.disabled, .missing, .empty] {
            XCTAssertFalse(state.explanation.isEmpty)
            let service = RAGIndexingService(sleep: {}) { request in self.response(request, json: "{\"state\":\"\(state.rawValue)\"}") }
            let result = try await service.waitUntilSearchable(sourceId: "synthetic-source")
            XCTAssertEqual(result, state)
        }
    }
    func testReadinessOversizedCheckStopsWithoutClaimingReadyOrReuploading() async throws {
        var requests = 0
        let service = RAGIndexingService(sleep: {}) { request in
            requests += 1
            return self.response(request, json: "{\"state\":\"waiting\",\"reason\":\"check_limit\"}")
        }
        let state = try await service.waitUntilSearchable(sourceId: "synthetic-source")
        XCTAssertEqual(state, .limited)
        XCTAssertEqual(requests, 1)
    }
    func testReadinessTransportFailureSurfacesWithoutReupload() async {
        let service = RAGIndexingService(sleep: {}) { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await service.waitUntilSearchable(sourceId: "synthetic-source"); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

}

private struct LegacyRAGTestProvider: AIProvider {
    let isConfigured = true
    let displayName = "Synthetic legacy provider"
    func streamChat(turns: [AITurn], noteContext: String, images: [UIImage], expectsImages: Bool,
                    onDelta: @escaping (String) -> Void) async throws {
        onDelta("Synthetic legacy reply")
    }
    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric { .init(criteria: []) }
    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        .init(score: 0, maxScore: 0, verdict: "", criteria: [], issues: [])
    }
    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        .init(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    }
}
