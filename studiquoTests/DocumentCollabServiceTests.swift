import XCTest
@testable import studiquo

/// Coverage for the purely local pieces of `DocumentCollabService` — the
/// networking calls themselves hit a live Cloudflare Worker (see
/// mcp-server/src/document-collab.test.js for that side's coverage) and
/// aren't exercised here, the same way FriendChatService's own network calls
/// have no client-side unit tests either.
final class DocumentCollabServiceTests: XCTestCase {
    func testMintRoomIDIsSixtyFourLowercaseHexCharacters() {
        let roomID = DocumentCollabService.mintRoomID()
        XCTAssertEqual(roomID.count, 64)
        XCTAssertNotNil(roomID.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
    }

    func testMintRoomIDIsDifferentEachTime() {
        XCTAssertNotEqual(DocumentCollabService.mintRoomID(), DocumentCollabService.mintRoomID())
    }
}

/// Coverage for the collaboration-related additions to `DocumentChangeRecord`
/// — the id that ties a local change record to its server-side proposal.
final class DocumentChangeRecordCollabTests: XCTestCase {
    func testANewlyCreatedRecordHasNoCollabChangeIDByDefault() {
        let block = DocumentBlock(order: 0, kind: .paragraph)
        let record = DocumentChangeRecord(
            author: "テスト", kind: .edit, previousText: "旧", newText: "新", anchorBlock: block
        )
        XCTAssertNil(record.collabChangeID)
    }

    func testCollabChangeIDCanBeSetAfterProposingToARoom() {
        let block = DocumentBlock(order: 0, kind: .paragraph)
        let record = DocumentChangeRecord(
            author: "テスト", kind: .edit, previousText: "旧", newText: "新", anchorBlock: block
        )
        record.collabChangeID = 42
        XCTAssertEqual(record.collabChangeID, 42)
    }
}
