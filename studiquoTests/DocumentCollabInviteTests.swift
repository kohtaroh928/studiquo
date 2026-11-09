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

final class CollabRemoteChangeTests: XCTestCase {
    func testHeaderAndFooterUseReservedOrdersThatRoundTrip() {
        XCTAssertEqual(DocumentCollabService.blockOrder(forTarget: "header"), DocumentCollabService.headerBlockOrder)
        XCTAssertEqual(DocumentCollabService.blockOrder(forTarget: "footer"), DocumentCollabService.footerBlockOrder)
        XCTAssertNil(DocumentCollabService.blockOrder(forTarget: nil))
        XCTAssertEqual(DocumentCollabService.target(forBlockOrder: DocumentCollabService.headerBlockOrder), "header")
        XCTAssertEqual(DocumentCollabService.target(forBlockOrder: DocumentCollabService.footerBlockOrder), "footer")
        XCTAssertNil(DocumentCollabService.target(forBlockOrder: 3))
    }

    func testAcceptingARemoteHeaderChangeWritesTheHeader() {
        let document = TextDocument(title: "d")
        let record = DocumentChangeRecord(author: "a", kind: .edit, previousText: "", newText: "新しいヘッダー", anchorBlock: nil)
        record.collabTarget = "header"
        record.isRemote = true
        record.applyRemoteChange(to: document)
        XCTAssertEqual(document.header?.text, "新しいヘッダー")
        XCTAssertNil(document.footer)
    }

    func testAcceptingARemoteParagraphChangeWritesThatBlockOnly() {
        let document = TextDocument(title: "d")
        let block = DocumentBlock(order: 0)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "古い"))
        block.document = document
        document.blocks = [block]
        let record = DocumentChangeRecord(author: "a", kind: .edit, previousText: "古い", newText: "新しい", anchorBlock: block)
        record.isRemote = true
        record.applyRemoteChange(to: document)
        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "新しい")
    }

    func testALocalChangeIsNotReappliedAndRejectingARemoteOneRevertsNothing() {
        let document = TextDocument(title: "d")
        let block = DocumentBlock(order: 0)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "今"))
        let local = DocumentChangeRecord(author: "a", kind: .edit, previousText: "前", newText: "後", anchorBlock: block)
        local.applyRemoteChange(to: document)
        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "今")
        let remote = DocumentChangeRecord(author: "a", kind: .edit, previousText: "前", newText: "後", anchorBlock: block)
        remote.isRemote = true
        remote.reject()
        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "今")
        XCTAssertEqual(remote.status, .rejected)
    }

    func testImportedDocumentCarriesTheRoomsHeaderAndFooter() {
        let state = DocumentCollabService.RoomState(blocks: [
            .init(order: 0, kind: "paragraph", text: "本文", listKind: nil, listLevel: 0, paragraphStyle: nil),
            .init(order: DocumentCollabService.headerBlockOrder, kind: "header", text: "ヘッダー", listKind: nil, listLevel: 0, paragraphStyle: nil),
            .init(order: DocumentCollabService.footerBlockOrder, kind: "footer", text: "", listKind: nil, listLevel: 0, paragraphStyle: nil),
        ], pendingChanges: [])
        let document = CollabInviteImporter.makeDocument(roomID: "r", inviterName: nil, state: state)
        XCTAssertEqual(document.header?.text, "ヘッダー")
        XCTAssertNil(document.footer)
        XCTAssertEqual(document.sortedBlocks.count, 1)
    }
}
