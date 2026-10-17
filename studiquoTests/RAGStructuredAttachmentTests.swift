import XCTest
import CryptoKit
import UIKit
import SwiftData
@testable import studiquo

@MainActor
final class RAGStructuredAttachmentTests: XCTestCase {
    private func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func fixture() throws -> (Data, Data) {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 180, height: 100)).pdfData { renderer in
            renderer.beginPage()
            ("Original synthetic text" as NSString).draw(at: CGPoint(x: 5, y: 5), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
        }
        let body = "Prepared synthetic text"
        let parser = ["name": "docling", "version": "2.139.0", "profile": "native-layout-table-v1"]
        let namespace = digest(try json(["parser": parser, "pdfSha256": digest(pdf)]))
        let document: [String: Any] = ["parser": parser, "pdfSha256": digest(pdf), "strategy": "structure-semantic-recursive-v1", "semanticApplied": false, "semanticModel": NSNull(), "semanticFallbackReason": "no_vectors", "maxEstimatedTokens": 400, "maxOverlapEstimatedTokens": 65, "semanticDistanceThreshold": 0.35, "namespaceScope": "document_parser_only_not_authentication", "offsetUnit": "unicode_codepoint", "provenanceScope": "element"]
        let metadata: [String: Any] = ["documentNamespace": namespace, "kind": "text", "elementId": "#/texts/1", "localId": "body:1", "idSource": "docling_self_ref", "pageNumbers": [1], "provenanceScope": "element", "provenance": [["pageNumber": 1, "bbox": ["l": 1, "t": 2, "r": 3, "b": 4, "coordOrigin": "TOPLEFT"], "charspan": [0, body.unicodeScalars.count]]], "coordinateState": "known", "headingPath": ["state": "unknown", "reason": "no_explicit_heading", "items": []], "contextRefs": [], "review": ["needsReview": false, "needsOCR": false, "reviewRequired": false, "oversized": false], "source": ["start": 0, "end": body.unicodeScalars.count, "offsetUnit": "unicode_codepoint", "textSha256": digest(Data(body.utf8))]]
        let page: [String: Any] = ["pageNumber": 1, "text": body, "structured": ["version": 1, "records": [["text": body, "metadata": metadata]]]]
        let batch: [String: Any] = ["structure": ["version": 1, "document": document, "documentNamespace": namespace], "totalPages": 1, "pages": [page]]
        return (pdf, try json(["version": 1, "integration": "prepared_only_no_upload", "batches": [batch]]))
    }
    func testNewPDFImportVerifiesBytesAndEditingInvalidatesPackage() throws {
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        XCTAssertEqual(try RAGStructuredAttachment.prepared(notebook)?.pages.first?.text, "Prepared synthetic text")
        notebook.sortedPages[0].recognizedText += " edited"
        XCTAssertNil(try RAGStructuredAttachment.prepared(notebook))
        XCTAssertThrowsError(try RAGStructuredAttachment.importNotebook(pdfData: pdf + Data([0]), manifestData: manifest, title: "Wrong"))
    }
    func testLockSealsAllPackageFieldsAndUnlockRestores() throws {
        let service = "RAGStructuredAttachmentTests-\(UUID().uuidString)"
        defer { NotebookEncryptionKeyStore.deleteKey(service: service) }
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        let data = notebook.ragStructuredData, hash = notebook.ragOriginalPDFHash, fingerprint = notebook.ragStructuredFingerprint
        NotebookEncryptionService.lock(notebook, keyService: service)
        XCTAssertNotNil(notebook.encryptedContent)
        XCTAssertNil(notebook.ragStructuredData); XCTAssertNil(notebook.ragStructuredFingerprint); XCTAssertNil(notebook.ragOriginalPDFHash)
        XCTAssertNil(try RAGStructuredAttachment.prepared(notebook))
        XCTAssertTrue(NotebookEncryptionService.unlock(notebook, keyService: service))
        XCTAssertEqual(notebook.ragStructuredData, data); XCTAssertEqual(notebook.ragOriginalPDFHash, hash)
        XCTAssertEqual(notebook.ragStructuredFingerprint, fingerprint)
        XCTAssertNotNil(try RAGStructuredAttachment.prepared(notebook))
    }
    func testManualUploadSendsStructuredDataAndStopsOnEdit() async throws {
        let granted = RAGConsent.isGranted, oldDefaults = AIDataDisclosure.defaults
        let defaults = UserDefaults(suiteName: "RAGStructuredAttachmentTests-\(UUID().uuidString)")!
        AIDataDisclosure.defaults = defaults; AIDataDisclosure.acknowledge(ageBand: .adult); RAGConsent.grant()
        defer { AIDataDisclosure.defaults = oldDefaults; if granted { RAGConsent.grant() } else { RAGConsent.revoke() } }
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        var uploads: [[String: Any]] = [], editDuringUpload = false
        let service = RAGIndexingService(accountPartition: { "synthetic" }) { request in
            let reply: String
            if request.httpMethod == "GET" { reply = "{\"enabled\":true,\"structuredIngestVersion\":1}" }
            else {
                uploads.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]); reply = "{}"
                if editDuringUpload { notebook.sortedPages[0].recognizedText += " edited" }
            }
            return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await service.index(notebook)
        XCTAssertEqual(uploads.count, 1); XCTAssertNotNil(uploads[0]["structure"])
        let pages = uploads[0]["pages"] as! [[String: Any]]
        XCTAssertEqual(pages[0]["text"] as? String, "Prepared synthetic text")
        XCTAssertNotNil(pages[0]["structured"])
        editDuringUpload = true
        do { _ = try await service.index(notebook); XCTFail("An edit during upload must stop the operation") }
        catch { XCTAssertNil(try RAGStructuredAttachment.prepared(notebook)) }
    }
    func testImageOnlyEditInvalidatesBothAttachmentAndManagedFingerprint() throws {
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        let element = PageElement(kind: .image, imageData: Data([1]))
        notebook.sortedPages[0].elements = [element]
        element.page = notebook.sortedPages[0]
        notebook.ragStructuredFingerprint = RAGStructuredAttachment.fingerprint(notebook)
        let before = RAGLibrarySyncService.fingerprint(notebook)
        element.imageData = Data([2])
        XCTAssertNotEqual(before, RAGLibrarySyncService.fingerprint(notebook))
        XCTAssertNil(try RAGStructuredAttachment.prepared(notebook))
    }
    func testPreparedUploadRefusesOldWorkerBeforePostingContent() async throws {
        let granted = RAGConsent.isGranted, old = AIDataDisclosure.defaults
        AIDataDisclosure.defaults = UserDefaults(suiteName: UUID().uuidString)!
        AIDataDisclosure.acknowledge(ageBand: .adult); RAGConsent.grant()
        defer { AIDataDisclosure.defaults = old; if granted { RAGConsent.grant() } else { RAGConsent.revoke() } }
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        var posts = 0
        let service = RAGIndexingService { request in
            if request.httpMethod != "GET" { posts += 1 }
            return (Data("{\"enabled\":true}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await service.index(notebook); XCTFail("Missing structured capability must stop upload") }
        catch { XCTAssertEqual(posts, 0) }
    }
    func testManagedUploadUsesVerifiedStructureAndControlProof() async throws {
        let old = AIDataDisclosure.defaults, granted = RAGConsent.isGranted
        AIDataDisclosure.defaults = UserDefaults(suiteName: UUID().uuidString)!
        AIDataDisclosure.acknowledge(ageBand: .adult)
        defer { AIDataDisclosure.defaults = old; if granted { RAGConsent.grant() } else { RAGConsent.revoke() } }
        let container = try ModelContainer(for: Notebook.self, NotePage.self, Folder.self, PageElement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        container.mainContext.insert(notebook); try container.mainContext.save()
        var epoch = 0, generation = 0, uploads: [[String: Any]] = [], preparedHash = ""
        let client = RAGControlClient(transport: { request in
            let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let path = request.url!.path
            let reply: [String: Any]
            if path.hasSuffix("/consent") {
                if request.httpMethod != "GET" { epoch += 1 }
                reply = ["enabled": epoch > 0, "consentEpoch": epoch, "available": true, "managed": epoch > 0]
            } else if path.hasSuffix("/status") { reply = ["enabled": true, "structuredIngestVersion": 1] }
            else if path.hasSuffix("/prepare") {
                generation = 1; preparedHash = object["sourceHash"] as! String
                reply = ["generation": generation, "consentEpoch": epoch, "sourceId": "synthetic-managed"]
            } else if path.hasSuffix("/readiness") { reply = ["state": "ready", "sourceHash": preparedHash] }
            else if path.hasSuffix("/state") { reply = ["documentId": notebook.ragDocumentID, "state": generation == 0 ? "missing" : "eligible", "generation": generation, "consentEpoch": epoch] }
            else { uploads.append(object); reply = [:] }
            return (try JSONSerialization.data(withJSONObject: reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, requestFactory: { path, body, _ in
            var request = URLRequest(url: URL(string: "https://example.invalid/" + path)!)
            request.httpBody = try JSONSerialization.data(withJSONObject: body); return request
        })
        let service = RAGLibrarySyncService(client: client, defaults: UserDefaults(suiteName: UUID().uuidString)!, partition: { "synthetic-owner" })
        try await service.grant(scope: .allPDFs, includeFuture: true, context: container.mainContext, notebooks: [notebook])
        await service.reconcile(notebooks: [notebook], context: container.mainContext)
        XCTAssertEqual(uploads.count, 1)
        XCTAssertNotNil(uploads.first?["structure"]); XCTAssertNotNil(uploads.first?["control"])
        XCTAssertEqual(uploads.first?["sourceId"] as? String, "synthetic-managed")
    }

    func testEditingDuringCapabilityCheckPreventsAllContentPosts() async throws {
        let granted = RAGConsent.isGranted, old = AIDataDisclosure.defaults
        AIDataDisclosure.defaults = UserDefaults(suiteName: UUID().uuidString)!
        AIDataDisclosure.acknowledge(ageBand: .adult); RAGConsent.grant()
        defer { AIDataDisclosure.defaults = old; if granted { RAGConsent.grant() } else { RAGConsent.revoke() } }
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        var posts = 0
        let service = RAGIndexingService(accountPartition: { "synthetic" }) { request in
            if request.httpMethod == "GET" { notebook.sortedPages[0].recognizedText += " edited during status" }
            else { posts += 1 }
            return (Data("{\"enabled\":true,\"structuredIngestVersion\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await service.index(notebook); XCTFail("Stale prepared data must not be sent") }
        catch { XCTAssertEqual(posts, 0) }
    }

    func testChangingEndpointDuringCapabilityCheckPreventsContentPost() async throws {
        let granted = RAGConsent.isGranted, old = AIDataDisclosure.defaults
        let oldEndpoint = UserDefaults.standard.string(forKey: "mcpCloudEndpoint")
        AIDataDisclosure.defaults = UserDefaults(suiteName: UUID().uuidString)!
        AIDataDisclosure.acknowledge(ageBand: .adult); RAGConsent.grant()
        defer {
            UserDefaults.standard.set(oldEndpoint, forKey: "mcpCloudEndpoint")
            AIDataDisclosure.defaults = old; if granted { RAGConsent.grant() } else { RAGConsent.revoke() }
        }
        let (pdf, manifest) = try fixture()
        let notebook = try RAGStructuredAttachment.importNotebook(pdfData: pdf, manifestData: manifest, title: "Synthetic")
        var posts = 0
        let service = RAGIndexingService(accountPartition: { "synthetic" }) { request in
            if request.httpMethod == "GET" { UserDefaults.standard.set("https://synthetic-endpoint.invalid", forKey: "mcpCloudEndpoint") }
            else { posts += 1 }
            return (Data("{\"enabled\":true,\"structuredIngestVersion\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await service.index(notebook); XCTFail("Capability from another endpoint must not be reused") }
        catch { XCTAssertEqual(posts, 0) }
    }

}
