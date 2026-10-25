import XCTest
import CryptoKit
@testable import studiquo

final class RAGStructuredDocumentTests: XCTestCase {
    private let pdf = Data("%PDF-1.7\nSynthetic only".utf8)
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func fixture(count: Int = 1, body: String = "Synthetic 漢字 😀") throws -> [String: Any] {
        let parser: [String: Any] = ["name": "docling", "version": "2.139.0", "profile": "native-layout-table-v1"]
        let pdfHash = hash(pdf)
        let namespace = hash(try json(["parser": parser, "pdfSha256": pdfHash]))
        let document: [String: Any] = ["parser": parser, "pdfSha256": pdfHash, "strategy": "structure-semantic-recursive-v1", "semanticApplied": false, "semanticModel": NSNull(), "semanticFallbackReason": "no_vectors", "maxEstimatedTokens": 400, "maxOverlapEstimatedTokens": 65, "semanticDistanceThreshold": 0.35, "namespaceScope": "document_parser_only_not_authentication", "offsetUnit": "unicode_codepoint", "provenanceScope": "element"]
        let structure: [String: Any] = ["version": 1, "document": document, "documentNamespace": namespace]
        var batches: [[String: Any]] = []
        for start in stride(from: 1, through: count, by: 5) {
            let pages: [[String: Any]] = (start...min(count, start + 4)).map { number in
                let metadata: [String: Any] = ["documentNamespace": namespace, "kind": "text", "elementId": "#/texts/\(number)", "localId": "body:\(number)", "idSource": "docling_self_ref", "pageNumbers": [number], "provenanceScope": "element", "provenance": [["pageNumber": number, "bbox": ["l": 1, "t": 2, "r": 3, "b": 4, "coordOrigin": "TOPLEFT"], "charspan": [0, body.unicodeScalars.count]]], "coordinateState": "known", "headingPath": ["state": "unknown", "reason": "no_explicit_heading", "items": []], "contextRefs": [], "review": ["needsReview": false, "needsOCR": false, "reviewRequired": false, "oversized": false], "source": ["start": 0, "end": body.unicodeScalars.count, "offsetUnit": "unicode_codepoint", "textSha256": hash(Data(body.utf8))]]
                return ["pageNumber": number, "text": body, "structured": ["version": 1, "records": [["text": body, "metadata": metadata]]]]
            }
            batches.append(["structure": structure, "totalPages": count, "pages": pages])
        }
        return ["version": 1, "integration": "prepared_only_no_upload", "batches": batches]
    }
    private func validate(_ root: [String: Any]) throws -> RAGStructuredDocument { try RAGStructuredDocument(manifestData: json(root), originalPDFData: pdf) }
    private func mutateRecord(_ root: inout [String: Any], _ mutate: (inout [String: Any]) -> Void) {
        var batches = root["batches"] as! [[String: Any]], pages = batches[0]["pages"] as! [[String: Any]]
        var structured = pages[0]["structured"] as! [String: Any], rows = structured["records"] as! [[String: Any]]
        var metadata = rows[0]["metadata"] as! [String: Any]; mutate(&metadata)
        rows[0]["metadata"] = metadata; structured["records"] = rows; pages[0]["structured"] = structured; batches[0]["pages"] = pages; root["batches"] = batches
    }
    func testPreservesMetadataAndUsesSeparateTextHash() throws {
        let root = try fixture(), result = try validate(root)
        XCTAssertEqual(try result.manifestData, try json(root))
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pdfSHA256, hash(pdf))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(result.sourceHash, hash(try encoder.encode(result.pages)))
        XCTAssertNotEqual(result.sourceHash, result.pdfSHA256)
        XCTAssertEqual(try RAGStructuredDocument(manifestData: result.manifestData, expectedPDFSHA256: hash(pdf)).sourceHash, result.sourceHash)
    }
    func testRejectsPDFMismatchAndInvalidMagic() throws {
        let data = try json(fixture())
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: data, originalPDFData: Data("%PDF-Changed".utf8)))
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: data, originalPDFData: Data("not PDF".utf8)))
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: data, expectedPDFSHA256: String(repeating: "A", count: 64)))
    }
    func testAll100PagesAreRetainedInOrder() throws {
        let result = try validate(fixture(count: 100))
        XCTAssertEqual(result.pages.map(\.pageNumber), Array(1...100))
        XCTAssertEqual(result.batches.count, 20)
    }
    func testRejectsUnknownFieldsAndPicture() throws {
        var root = try fixture(); root["extra"] = true
        XCTAssertThrowsError(try validate(root))
        for mutation in ["picture", "unknown"] {
            root = try fixture(); mutateRecord(&root) { $0["kind"] = mutation }
            XCTAssertThrowsError(try validate(root))
        }
        root = try fixture(); mutateRecord(&root) { $0["extra"] = "no" }
        XCTAssertThrowsError(try validate(root))
    }
    func testRejectsReviewAndBooleanNumberConfusion() throws {
        var root = try fixture(); mutateRecord(&root) { $0["review"] = ["needsReview": 0, "needsOCR": false, "reviewRequired": false, "oversized": false] }
        XCTAssertThrowsError(try validate(root))
        root = try fixture(); root["version"] = true
        XCTAssertThrowsError(try validate(root))
        root = try fixture(); mutateRecord(&root) { $0["review"] = ["needsReview": true, "needsOCR": false, "reviewRequired": false, "oversized": false] }
        XCTAssertThrowsError(try validate(root))
    }
    func testRejectsBadHashCodepointRangeAndPageBinding() throws {
        for field in ["hash", "range", "page", "coordinates", "unknownHeading"] {
            var root = try fixture()
            mutateRecord(&root) { m in
                switch field {
                case "hash": var s = m["source"] as! [String: Any]; s["textSha256"] = String(repeating: "0", count: 64); m["source"] = s
                case "range": var s = m["source"] as! [String: Any]; s["end"] = 1; m["source"] = s
                case "page": m["pageNumbers"] = [2]
                case "coordinates": m["coordinateState"] = "unknown"
                default: m["headingPath"] = ["state": "unknown", "reason": "no_explicit_heading", "items": [["elementId": "h", "text": "H", "level": 1]]]
                }
            }
            XCTAssertThrowsError(try validate(root), field)
        }
    }
    func testRejectsSemanticFlagMismatch() throws {
        var root = try fixture(), batches = root["batches"] as! [[String: Any]]
        var structure = batches[0]["structure"] as! [String: Any], document = structure["document"] as! [String: Any]
        document["semanticApplied"] = true; structure["document"] = document; batches[0]["structure"] = structure; root["batches"] = batches
        XCTAssertThrowsError(try validate(root))
    }
    func testRejectsDuplicateIDsAcrossBatchesAndMissingPages() throws {
        var root = try fixture(count: 6), batches = root["batches"] as! [[String: Any]]
        var second: [String: Any] = ["batches": [batches[1]]]
        mutateRecord(&second) { $0["localId"] = "body:1" }
        batches[1] = (second["batches"] as! [[String: Any]])[0]; root["batches"] = batches
        XCTAssertThrowsError(try validate(root))
        root = try fixture(count: 6); batches = root["batches"] as! [[String: Any]]; batches.removeLast(); root["batches"] = batches
        XCTAssertThrowsError(try validate(root))
    }
    func testTokenParityECMAScriptWhitespaceAndAstralUnicode() throws {
        XCTAssertEqual(try RAGStructuredDocument.workerTokenCount("漢字 abc 😀"), 4)
        XCTAssertEqual(try RAGStructuredDocument.workerTokenCount("\u{feff}a\u{feff}"), 1)
        XCTAssertEqual(try RAGStructuredDocument.workerTokenCount("\u{85}"), 1)
        XCTAssertEqual(try RAGStructuredDocument.workerTokenCount("\u{180e}"), 1)
        XCTAssertEqual(try RAGStructuredDocument.workerTokenCount("\u{2000}\u{2028}"), 0)
        XCTAssertThrowsError(try validate(fixture(body: String(repeating: "! ", count: 501))))
        XCTAssertNoThrow(try validate(fixture(body: "e\u{301} 😀 𠀀")))
    }
    func testRejectsDuplicateEscapedJSONKeys() throws {
        let data = try json(fixture())
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"integration\":", with: "\"integrati\\u006fn\":\"prepared_only_no_upload\",\"integration\":")
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: Data(text.utf8), originalPDFData: pdf))
    }
    func testRejectsSizeLimitsAndMalformedJSON() throws {
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: Data(repeating: 32, count: 32 * 1024 * 1024 + 1), originalPDFData: pdf))
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: json(fixture()), originalPDFData: Data(repeating: 32, count: 100 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try RAGStructuredDocument(manifestData: Data("{bad}".utf8), originalPDFData: pdf))
    }
}
