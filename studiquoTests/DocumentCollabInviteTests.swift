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

    @MainActor
    func testSnapshotImportUsesSnapshotTitleWhenPresentAndInviterFallbackWhenBlank() {
        installInMemoryCollabState()
        let body = DocumentBody.encode(NSAttributedString(string: "共有本文", attributes: DocumentBody.defaultAttributes()))
        let imageBytes = Data([0x10, 0x20, 0x30])
        let hash = DocumentSnapshotCodec.sha256Hex(imageBytes)
        let snapshotWithTitle = DocumentSnapshot(
            title: "共同レポート", pageSize: "a4", columnCount: 2,
            header: .init(body: body, showsPageNumber: true),
            footer: nil,
            blocks: [
                .init(id: "b1", kind: "paragraph", body: body, imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
                .init(id: "b2", kind: "image", body: nil, imageHash: hash, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
            ]
        )
        let doc = CollabInviteImporter.makeDocument(
            roomID: "room-snap", inviterName: "佐藤",
            snapshot: snapshotWithTitle, revision: 4, assets: [hash: imageBytes]
        )
        XCTAssertEqual(doc.title, "共同レポート")
        XCTAssertEqual(doc.collabRoomID, "room-snap")
        XCTAssertEqual(doc.collabRevision, 4)
        XCTAssertNotNil(doc.collabBaseSnapshot)
        XCTAssertEqual(doc.sortedBlocks.count, 2)
        XCTAssertEqual(doc.sortedBlocks[1].bodyData, imageBytes)
        XCTAssertEqual(doc.header?.showsPageNumber, true)
        XCTAssertEqual(CollabInviteImporter.title(inviterName: "佐藤"), L("佐藤さんの共有文書"))
        XCTAssertEqual(CollabInviteImporter.title(inviterName: "   "), L("共有された文書"))
    }

    @MainActor
    func testRevisionZeroFallbackImportsLegacyStateAndUpgradesInPlaceWhenOwnerPushesSnapshot() async throws {
        installInMemoryCollabState()
        final class UpgradeRoom: DocumentSnapshotClient {
            var revision = 0
            var snapshotText: String?
            var assets: [String: Data] = [:]
            var editorsMustWait = true

            func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply {
                if revision == 0 { return .init(revision: 0, snapshot: nil, unchanged: nil) }
                if since == revision { return .init(revision: revision, snapshot: nil, unchanged: true) }
                return .init(revision: revision, snapshot: snapshotText, unchanged: nil)
            }
            func putSnapshot(roomID: String, baseRevision: Int, snapshot: String, assets: [String]) async throws -> Int {
                if editorsMustWait { throw DocumentCollabService.RoomNotReady() }
                guard baseRevision == revision else { throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
                revision += 1
                snapshotText = snapshot
                return revision
            }
            func missingAssets(roomID: String, hashes: [String]) async throws -> [String] { hashes.filter { assets[$0] == nil } }
            func putAsset(roomID: String, hash: String, data: Data) async throws { assets[hash] = data }
            func asset(roomID: String, hash: String) async throws -> Data? { assets[hash] }
        }

        let room = UpgradeRoom()
        let invited = CollabInviteImporter.makeDocument(roomID: "room-zero", inviterName: "鈴木", state: state())
        XCTAssertEqual(invited.collabRevision, 0)
        XCTAssertNil(invited.collabBaseSnapshot)

        let waiting = try await CollabSyncEngine.sync(
            document: invited, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(waiting, .upToDate)
        XCTAssertEqual(room.revision, 0)

        let ownerDoc = TextDocument(title: "オーナー確定版")
        let ownerPara = DocumentBlock(order: 0, kind: .paragraph)
        ownerPara.bodyData = DocumentBody.encode(NSAttributedString(string: "オーナー本文", attributes: DocumentBody.defaultAttributes()))
        ownerPara.document = ownerDoc
        let ownerTable = DocumentBlock.makeTable(order: 1, rows: 1, columns: 2)
        ownerTable.sortedTableRows[0].sortedCells[0].text = "表セル"
        ownerTable.document = ownerDoc
        ownerDoc.blocks = [ownerPara, ownerTable]
        ownerDoc.isMigratedToBlocks = true
        ownerDoc.collabRoomID = "room-zero"

        room.editorsMustWait = false
        let ownerPush = try await CollabSyncEngine.sync(
            document: ownerDoc, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(ownerPush, .pushed)
        XCTAssertEqual(room.revision, 1)

        // Reset invited document to base-less state as imported at revision 0 before owner pushed
        invited.collabRevision = 0
        invited.collabBaseSnapshot = nil
        invited.blocks = []
        let editorPull = try await CollabSyncEngine.sync(
            document: invited, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(editorPull, .pulled(conflicts: 0))
        XCTAssertEqual(invited.collabRevision, 1)
        XCTAssertEqual(invited.title, "オーナー確定版")
        XCTAssertEqual(invited.sortedBlocks.map(\.kind), [.paragraph, .table])
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
