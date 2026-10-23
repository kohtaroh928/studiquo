import XCTest
@testable import studiquo

final class RAGCitationMetadataTests: XCTestCase {
    private let chunk = String(repeating: "a", count: 64)
    private func metadata(page: Int = 3) -> [String: Any] {
        ["version": 1, "documentNamespace": String(repeating: "b", count: 64),
         "parser": ["name": "docling", "version": "2.139.0", "profile": "native-layout-table-v1"],
         "provenanceScope": "element", "segments": [["chunkId": chunk, "elementId": "#/texts/0", "kind": "text",
             "rangeScope": "stored_chunk_not_excerpt", "start": 10, "end": 20, "offsetUnit": "unicode_codepoint",
             "provenance": [["pageNumber": page, "bbox": ["l": 1, "t": 2, "r": 20, "b": 30, "coordOrigin": "TOPLEFT"], "charspan": [0, 40]]],
             "provenanceTruncated": false]]]
    }
    private func citation(_ extensionValue: Any? = nil, chunkID: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["sourceId": "synthetic-source", "title": "Synthetic fixture", "pageNumber": 3, "chunkId": chunkID ?? chunk]
        if let extensionValue { value["metadata"] = extensionValue }
        return value
    }
    private func decode(_ extensionValue: Any? = nil, chunkID: String? = nil) throws -> RAGCitation {
        let data = try JSONSerialization.data(withJSONObject: citation(extensionValue, chunkID: chunkID))
        return try JSONDecoder().decode(RAGCitation.self, from: data)
    }
    private func editSegment(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var value = metadata()
        var rows = value["segments"] as! [[String: Any]]
        edit(&rows[0])
        value["segments"] = rows
        return value
    }

    func testLegacyInitializersAndPersistenceRemainCompatible() throws {
        let old = RAGCitation(sourceId: "synthetic-source", title: "Synthetic fixture", pageNumber: 3, chunkId: "legacy-chunk")
        XCTAssertNil(old.metadata)
        XCTAssertEqual(try decode(chunkID: "legacy-chunk"), old)
        XCTAssertEqual(try JSONDecoder().decode(RAGCitation.self, from: JSONEncoder().encode(old)), old)
    }
    func testValidEventRetainsMetadataAndOriginalPageNavigation() throws {
        let data = try JSONSerialization.data(withJSONObject: ["citations": [citation(metadata())]])
        let value = try XCTUnwrap(RAGCitation.decodeEvent(data)?.first)
        XCTAssertEqual(value.sourceId, "synthetic-source")
        XCTAssertEqual(value.pageNumber, 3)
        XCTAssertEqual(value.id, chunk)
        XCTAssertEqual(value.metadata?.segments.first?.rangeScope, "stored_chunk_not_excerpt")
        XCTAssertEqual(value.metadata?.provenanceScope, "element")
        XCTAssertEqual(value.metadata?.segments.first?.start, 10)
        XCTAssertEqual(value.metadata?.segments.first?.provenance.first?.bbox?.l, 1)
    }
    func testMetadataPersistsThroughCodableRoundTrip() throws {
        let value = try decode(metadata())
        XCTAssertNotNil(value.metadata)
        XCTAssertEqual(try JSONDecoder().decode(RAGCitation.self, from: JSONEncoder().encode(value)), value)
    }
    func testUnknownVersionAndKeysDropOnlyMetadata() throws {
        for key in ["version", "unexpected"] {
            var value = metadata(); value[key] = 2
            let decoded = try decode(value)
            XCTAssertNil(decoded.metadata)
            XCTAssertEqual(decoded.pageNumber, 3)
            XCTAssertEqual(decoded.sourceId, "synthetic-source")
        }
        var value = metadata(); value["parser"] = ["name": "docling", "version": "2", "profile": "native", "author": "untrusted"]
        XCTAssertNil(try decode(value).metadata)
        XCTAssertNil(try decode(false).metadata)
    }
    func testDifferentPageOrUnrelatedChunkNeverChangesDestination() throws {
        let wrongPage = try decode(metadata(page: 4))
        XCTAssertNil(wrongPage.metadata)
        XCTAssertEqual(wrongPage.pageNumber, 3)
        let differentChunk = editSegment { $0["chunkId"] = String(repeating: "c", count: 64) }
        XCTAssertNil(try decode(differentChunk).metadata)
    }
    func testInvalidRangesAndScopeFallBackToPageCitation() throws {
        for (key, value) in [("start", -1 as Any), ("end", 10 as Any), ("end", 8_000_001 as Any),
                             ("rangeScope", "exact_quote" as Any), ("offsetUnit", "utf16" as Any)] {
            XCTAssertNil(try decode(editSegment { $0[key] = value }).metadata)
        }
    }
    func testSegmentAndProvenanceCountsAreBounded() throws {
        var value = metadata()
        let row = (value["segments"] as! [[String: Any]])[0]
        value["segments"] = Array(repeating: row, count: 4)
        XCTAssertNil(try decode(value).metadata)
        let tooMany = editSegment { row in
            row["provenance"] = Array(repeating: (row["provenance"] as! [[String: Any]])[0], count: 5)
        }
        XCTAssertNil(try decode(tooMany).metadata)
        let duplicate = metadata().merging(["segments": [row, row]]) { _, new in new }
        XCTAssertNil(try decode(duplicate).metadata)
    }
    func testUnknownCoordinatesStayUnknownWithoutInventedPrecision() throws {
        let value = editSegment { row in
            var positions = row["provenance"] as! [[String: Any]]
            positions[0]["bbox"] = ["l": 1, "t": 2, "r": 20, "b": 30, "coordOrigin": "unknown"]
            row["provenance"] = positions
            row["provenanceTruncated"] = true
        }
        let decoded = try decode(value)
        XCTAssertEqual(decoded.metadata?.segments.first?.provenance.first?.bbox?.hasKnownOrigin, false)
        XCTAssertEqual(decoded.metadata?.segments.first?.provenance.first?.bbox?.coordOrigin, "unknown")
        XCTAssertEqual(decoded.metadata?.segments.first?.provenanceTruncated, true)
    }
    func testInvalidBoundingBoxAndCharacterSpanAreRejected() throws {
        for position in [["pageNumber": 3, "bbox": ["l": 1e10, "t": 2, "r": 20, "b": 30]] as [String: Any],
                         ["pageNumber": 3, "bbox": NSNull(), "charspan": [10, 1]],
                         ["pageNumber": 3, "bbox": NSNull(), "charspan": [0, true]]] {
            XCTAssertNil(try decode(editSegment { $0["provenance"] = [position] }).metadata)
        }
    }
    func testOversizedMetadataAndEventAreBounded() throws {
        var value = metadata()
        value["parser"] = ["name": String(repeating: "x", count: 513), "version": "2", "profile": "native"]
        XCTAssertNil(try decode(value).metadata)
        XCTAssertNil(RAGCitation.decodeEvent(Data(repeating: 32, count: 512 * 1024 + 1)))
    }
    func testMaximumNeighborProjectionRetainsTruncationAndPage() throws {
        var value = metadata()
        let original = (value["segments"] as! [[String: Any]])[0]
        value["segments"] = ["a", "c", "d"].map { character -> [String: Any] in
            var row = original
            row["chunkId"] = String(repeating: character, count: 64)
            row["provenance"] = Array(repeating: (original["provenance"] as! [[String: Any]])[0], count: 4)
            row["provenanceTruncated"] = true
            return row
        }
        let decoded = try decode(value)
        XCTAssertEqual(decoded.metadata?.segments.count, 3)
        XCTAssertTrue(decoded.metadata?.segments.allSatisfy { $0.provenance.count == 4 && $0.provenanceTruncated } == true)
    }
    func testExcessiveMetadataDepthFallsBackWithoutChangingCitation() throws {
        var nested: Any = "synthetic"
        for _ in 0..<20 { nested = ["nested": nested] }
        var value = metadata()
        value["unexpected"] = nested
        let decoded = try decode(value)
        XCTAssertNil(decoded.metadata)
        XCTAssertEqual(decoded.pageNumber, 3)
    }

    func testNullOptionalProvenanceRoundTripsWithoutLosingPageCitation() throws {
        let value = editSegment { $0["provenance"] = [["pageNumber": 3, "bbox": NSNull(), "charspan": NSNull()]] }
        let decoded = try decode(value)
        XCTAssertNotNil(decoded.metadata)
        XCTAssertNil(decoded.metadata?.segments.first?.provenance.first?.bbox)
        XCTAssertEqual(decoded.pageNumber, 3)
        XCTAssertEqual(try JSONDecoder().decode(RAGCitation.self, from: JSONEncoder().encode(decoded)), decoded)
    }
}
