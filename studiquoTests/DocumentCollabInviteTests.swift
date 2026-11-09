import XCTest
@testable import studiquo

final class DocumentCollabInviteTests: XCTestCase {
    func testPendingInviteListIsDecodedWithTheRoomAsItsIdentity() throws {
        let json = #"[{"roomID":"aaaa","role":"editor","inviterName":"田中","createdAt":1700000000000},{"roomID":"bbbb","role":"reviewer","inviterName":null,"createdAt":1700000001000}]"#
        let invites = try JSONDecoder().decode([DocumentCollabService.PendingInvite].self, from: Data(json.utf8))
        XCTAssertEqual(invites.map(\.id), ["aaaa", "bbbb"])
        XCTAssertEqual(invites[0].inviterName, "田中")
        XCTAssertNil(invites[1].inviterName)
        XCTAssertEqual(invites[1].role, "reviewer")
    }

    func testInviteAnswerCarriesTheStatusTheServerSends() throws {
        let joined = try JSONDecoder().decode(DocumentCollabService.InviteAnswer.self, from: Data(#"{"status":"joined","role":"editor"}"#.utf8))
        XCTAssertEqual(joined.status, "joined")
        XCTAssertEqual(joined.role, "editor")
        let declined = try JSONDecoder().decode(DocumentCollabService.InviteAnswer.self, from: Data(#"{"status":"declined"}"#.utf8))
        XCTAssertEqual(declined.status, "declined")
        XCTAssertNil(declined.role)
    }
}

final class CollabInviteImporterTests: XCTestCase {
    private func state() -> DocumentCollabService.RoomState {
        DocumentCollabService.RoomState(blocks: [
            .init(order: 5, kind: "paragraph", text: "後ろの段落", listKind: nil, listLevel: 0, paragraphStyle: nil),
            .init(order: 1, kind: "table", text: "", listKind: nil, listLevel: 0, paragraphStyle: nil),
            .init(order: 2, kind: "paragraph", text: "最初の段落", listKind: "bullet", listLevel: 1, paragraphStyle: "heading1"),
        ], pendingChanges: [])
    }

    func testImportKeepsParagraphsAtTheRoomsOrderAndDropsOtherKinds() {
        let blocks = CollabInviteImporter.makeBlocks(from: state())
        XCTAssertEqual(blocks.map(\.order), [2, 5])
        XCTAssertEqual(blocks[0].listKindRawValue, "bullet")
        XCTAssertEqual(blocks[0].listLevel, 1)
        XCTAssertEqual(blocks[0].paragraphStyleRawValue, "heading1")
    }

    func testImportedDocumentIsBoundToTheRoomAndReadsBackItsText() {
        let document = CollabInviteImporter.makeDocument(roomID: "room1", inviterName: "田中", state: state())
        XCTAssertEqual(document.collabRoomID, "room1")
        XCTAssertTrue(document.isMigratedToBlocks)
        XCTAssertEqual(document.sortedBlocks.map(\.order), [2, 5])
        XCTAssertEqual(document.plainText, "最初の段落\n後ろの段落")
        XCTAssertTrue(document.title.contains("田中"))
        XCTAssertFalse(CollabInviteImporter.title(inviterName: nil).isEmpty)
    }
}
