import XCTest
@testable import studiquo

private func para(_ text: String, id: String? = nil) -> DocumentBlock {
    let block = DocumentBlock(order: 0, kind: .paragraph)
    block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
    block.collabID = id
    return block
}

private func makeDocument(_ texts: [String]) -> TextDocument {
    let document = TextDocument(title: "文書")
    let blocks = texts.enumerated().map { index, text -> DocumentBlock in
        let block = para(text)
        block.order = index
        block.document = document
        return block
    }
    document.blocks = blocks
    document.isMigratedToBlocks = true
    return document
}

private func texts(_ document: TextDocument) -> [String] {
    document.sortedBlocks.map { DocumentBody.decode($0.bodyData).string }
}

/// An in-memory room with the server's revision rule.
private final class FakeRoom: DocumentSnapshotClient {
    var revision = 0
    var snapshotText: String?
    var assets: [String: Data] = [:]
    var failNextPutWithConflict = false

    func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply {
        if revision == 0 { return .init(revision: 0, snapshot: nil, unchanged: nil) }
        if since == revision { return .init(revision: revision, snapshot: nil, unchanged: true) }
        return .init(revision: revision, snapshot: snapshotText, unchanged: nil)
    }
    func putSnapshot(roomID: String, baseRevision: Int, snapshot: String) async throws -> Int {
        if failNextPutWithConflict { failNextPutWithConflict = false; throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
        guard baseRevision == revision else { throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
        revision += 1
        snapshotText = snapshot
        return revision
    }
    func missingAssets(roomID: String, hashes: [String]) async throws -> [String] { hashes.filter { assets[$0] == nil } }
    func putAsset(roomID: String, hash: String, data: Data) async throws { assets[hash] = data }
    func asset(roomID: String, hash: String) async throws -> Data? { assets[hash] }
}

@MainActor
final class CollabSnapshotTests: XCTestCase {
    private func sync(_ document: TextDocument, _ room: FakeRoom, canWrite: Bool = true, current: @escaping () -> Bool = { true }) async throws -> CollabSyncEngine.Outcome {
        document.collabRoomID = document.collabRoomID ?? "room"
        return try await CollabSyncEngine.sync(document: document, canWrite: canWrite, client: room, flush: {}, stillCurrent: current, didApply: {}, save: {})
    }

    // MARK: codec

    func testSnapshotRoundTripKeepsTablesCommentsFootnotesHeaderAndImages() throws {
        let document = makeDocument(["本文"])
        document.headerFooter(.header).text = "ヘッダー"
        document.headerFooter(.footer).showsPageNumber = true
        let table = DocumentBlock.makeTable(order: 1, rows: 2, columns: 2)
        table.document = document
        table.sortedTableRows[0].sortedCells[0].text = "左上"
        let image = DocumentBlock(order: 2, kind: .image)
        image.bodyData = Data([1, 2, 3, 4])
        image.document = document
        document.blocks = (document.blocks ?? []) + [table, image]
        _ = document.sortedBlocks[0].addComment(author: "田中", text: "確認")
        document.sortedBlocks[0].addFootnote(text: "注")

        let (snapshot, assets) = DocumentSnapshotCodec.make(from: document)
        XCTAssertEqual(snapshot.blocks.count, 3)
        XCTAssertEqual(assets.count, 1)

        let copy = TextDocument(title: "x")
        DocumentSnapshotCodec.apply(snapshot, to: copy, assets: assets)
        let (again, againAssets) = DocumentSnapshotCodec.make(from: copy)
        XCTAssertEqual(again, snapshot)
        XCTAssertEqual(againAssets, assets)
        XCTAssertEqual(copy.header?.text, "ヘッダー")
        XCTAssertEqual(copy.footer?.showsPageNumber, true)
        XCTAssertEqual(copy.sortedBlocks[1].sortedTableRows[0].sortedCells[0].text, "左上")
        XCTAssertEqual(copy.sortedBlocks[0].sortedAnchoredComments.first?.text, "確認")
        XCTAssertEqual(copy.sortedBlocks[2].bodyData, Data([1, 2, 3, 4]))
    }

    func testReArchivedButUnchangedTextIsNotAnEdit() {
        let a = DocumentBody.encode(NSAttributedString(string: "同じ", attributes: DocumentBody.defaultAttributes()))
        let b = DocumentBody.encode(NSAttributedString(string: "同じ", attributes: DocumentBody.defaultAttributes()))
        XCTAssertTrue(SnapshotText.same(a, b))
        XCTAssertFalse(SnapshotText.same(a, DocumentBody.encode(NSAttributedString(string: "違う", attributes: DocumentBody.defaultAttributes()))))
    }

    func testTheEditorRebuildingAParagraphKeepsItsSyncID() {
        let document = makeDocument(["一", "二"])
        _ = DocumentSnapshotCodec.make(from: document)
        let ids = document.sortedBlocks.compactMap(\.collabID)
        XCTAssertEqual(ids.count, 2)
        let segment = document.segments[0]
        let run = document.replaceParagraphRun(segment.blocks, with: NSAttributedString(string: "一改\n二", attributes: DocumentBody.defaultAttributes()))
        XCTAssertEqual(run.compactMap(\.collabID), ids)
    }

    // MARK: merge

    private func snapshot(_ items: [(String, String)], title: String = "t") -> DocumentSnapshot {
        DocumentSnapshot(title: title, pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: items.map { id, text in
            DocumentSnapshot.Block(id: id, kind: "paragraph", body: DocumentBody.encode(NSAttributedString(string: text)), imageHash: nil,
                                   equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: [])
        })
    }
    private func words(_ s: DocumentSnapshot) -> [String] { s.blocks.map { "\($0.id):\(DocumentBody.decode($0.body).string)" } }

    func testMergeTakesEachSidesOwnEditsToDifferentBlocks() {
        let base = snapshot([("a", "A"), ("b", "B")])
        let local = snapshot([("a", "A1"), ("b", "B")])
        let remote = snapshot([("a", "A"), ("b", "B2")])
        let result = DocumentSnapshotMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(words(result.snapshot), ["a:A1", "b:B2"])
        XCTAssertEqual(result.conflicts, 0)
    }

    func testMergeKeepsLocalOnTheSameBlockAndCountsIt() {
        let base = snapshot([("a", "A")])
        let result = DocumentSnapshotMerge.merge(base: base, local: snapshot([("a", "L")]), remote: snapshot([("a", "R")]))
        XCTAssertEqual(words(result.snapshot), ["a:L"])
        XCTAssertEqual(result.conflicts, 1)
    }

    func testMergeInsertionsFromBothSidesAndDeletions() {
        let base = snapshot([("a", "A"), ("b", "B"), ("c", "C")])
        let local = snapshot([("a", "A"), ("x", "X"), ("b", "B")])          // new x after a, c deleted
        let remote = snapshot([("a", "A"), ("b", "B"), ("c", "C"), ("y", "Y")]) // new y at the end
        let result = DocumentSnapshotMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(words(result.snapshot), ["a:A", "x:X", "b:B", "y:Y"])
    }

    func testDeletingWhatTheOtherSideEditedKeepsTheEdit() {
        let base = snapshot([("a", "A"), ("b", "B")])
        let result = DocumentSnapshotMerge.merge(base: base, local: snapshot([("a", "A")]), remote: snapshot([("a", "A"), ("b", "B改")]))
        XCTAssertEqual(words(result.snapshot), ["a:A", "b:B改"])
    }

    func testMergeFollowsTheOnlySideThatReordered() {
        let base = snapshot([("a", "A"), ("b", "B"), ("c", "C")])
        let local = snapshot([("c", "C"), ("a", "A"), ("b", "B")])
        let result = DocumentSnapshotMerge.merge(base: base, local: local, remote: base)
        XCTAssertEqual(result.snapshot.blocks.map(\.id), ["c", "a", "b"])
    }

    func testMergeOfSettingsIsPerField() {
        let base = snapshot([("a", "A")], title: "古")
        var local = base; local.title = "新"
        var remote = base; remote.columnCount = 2
        let merged = DocumentSnapshotMerge.merge(base: base, local: local, remote: remote).snapshot
        XCTAssertEqual(merged.title, "新")
        XCTAssertEqual(merged.columnCount, 2)
    }

    // MARK: engine

    func testOwnerPushesFirstThenAnInvitedDeviceFollowsAndEditsComeBack() async throws {
        let room = FakeRoom()
        let owner = makeDocument(["一", "二"])
        var outcome = try await sync(owner, room)
        XCTAssertEqual(outcome, .pushed)
        XCTAssertEqual(room.revision, 1)
        outcome = try await sync(owner, room)
        XCTAssertEqual(outcome, .upToDate)

        // the other device joins from the snapshot
        let invited = CollabInviteImporter.makeDocument(
            roomID: "room", inviterName: "A",
            snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: 1, assets: [:]
        )
        XCTAssertEqual(texts(invited), ["一", "二"])
        outcome = try await sync(invited, room)
        XCTAssertEqual(outcome, .upToDate)

        invited.sortedBlocks[1].bodyData = DocumentBody.encode(NSAttributedString(string: "二改", attributes: DocumentBody.defaultAttributes()))
        outcome = try await sync(invited, room)
        XCTAssertEqual(outcome, .pushed)
        outcome = try await sync(owner, room)
        XCTAssertEqual(outcome, .pulled(conflicts: 0))
        XCTAssertEqual(texts(owner), ["一", "二改"])
    }

    func testEditsToDifferentParagraphsMadeAtTheSameTimeAreBothKept() async throws {
        let room = FakeRoom()
        let a = makeDocument(["一", "二"])
        _ = try await sync(a, room)
        let b = CollabInviteImporter.makeDocument(roomID: "room", inviterName: nil, snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: 1, assets: [:])

        a.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "一A", attributes: DocumentBody.defaultAttributes()))
        b.sortedBlocks[1].bodyData = DocumentBody.encode(NSAttributedString(string: "二B", attributes: DocumentBody.defaultAttributes()))
        _ = try await sync(a, room)
        let outcome = try await sync(b, room)
        XCTAssertEqual(outcome, .pulled(conflicts: 0))
        XCTAssertEqual(texts(b), ["一A", "二B"])
        _ = try await sync(a, room)
        XCTAssertEqual(texts(a), ["一A", "二B"])
        XCTAssertEqual(room.revision, 3)
    }

    func testAStaleSaveIsRetriedOnTopOfTheNewRevision() async throws {
        let room = FakeRoom()
        let a = makeDocument(["一"])
        _ = try await sync(a, room)
        a.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "一改", attributes: DocumentBody.defaultAttributes()))
        room.failNextPutWithConflict = true
        let outcome = try await sync(a, room)
        XCTAssertTrue(outcome == .pushed || outcome == .pulled(conflicts: 0))
        XCTAssertEqual(room.revision, 2)
        XCTAssertTrue(room.snapshotText!.contains("revision") == false)
    }

    func testAReviewerFollowsTheRoomAndItsOwnEditsDoNotLeave() async throws {
        let room = FakeRoom()
        let owner = makeDocument(["本文"])
        _ = try await sync(owner, room)
        let reviewer = CollabInviteImporter.makeDocument(roomID: "room", inviterName: nil, snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: 1, assets: [:])
        reviewer.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "勝手", attributes: DocumentBody.defaultAttributes()))
        _ = try await sync(reviewer, room, canWrite: false)
        XCTAssertEqual(texts(reviewer), ["本文"])
        XCTAssertEqual(room.revision, 1)

        owner.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "本文改", attributes: DocumentBody.defaultAttributes()))
        _ = try await sync(owner, room)
        _ = try await sync(reviewer, room, canWrite: false)
        XCTAssertEqual(texts(reviewer), ["本文改"])
    }

    func testKeepingTypingDuringTheNetworkCallDropsTheRoundInsteadOfOverwriting() async throws {
        let room = FakeRoom()
        let a = makeDocument(["一"])
        _ = try await sync(a, room)
        let b = CollabInviteImporter.makeDocument(roomID: "room", inviterName: nil, snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: 1, assets: [:])
        b.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "相手", attributes: DocumentBody.defaultAttributes()))
        _ = try await sync(b, room)

        a.sortedBlocks[0].bodyData = DocumentBody.encode(NSAttributedString(string: "自分が入力中", attributes: DocumentBody.defaultAttributes()))
        let outcome = try await sync(a, room, current: { false })
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(texts(a), ["自分が入力中"], "nothing was applied over the typing")
    }

    func testImagesTravelThroughTheRoomByHash() async throws {
        let room = FakeRoom()
        let a = makeDocument(["本文"])
        let image = DocumentBlock(order: 1, kind: .image)
        image.bodyData = Data([9, 8, 7])
        image.document = a
        a.blocks = (a.blocks ?? []) + [image]
        _ = try await sync(a, room)
        XCTAssertEqual(room.assets.count, 1)
        let b = makeDocument([])
        b.collabRoomID = "room"
        _ = try await sync(b, room)
        XCTAssertEqual(b.sortedBlocks.last?.bodyData, Data([9, 8, 7]))
    }
}

final class CollabRequestURLTests: XCTestCase {
    func testAQueryStaysAQueryAndIsNotEncodedIntoThePath() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://staging-api.studiquo.app"))
        let url = try XCTUnwrap(DocumentCollabService.requestURL(endpoint: endpoint, path: "api/document/rooms/abc/snapshot?since=3"))
        XCTAssertEqual(url.absoluteString, "https://staging-api.studiquo.app/api/document/rooms/abc/snapshot?since=3")
        XCTAssertEqual(url.path, "/api/document/rooms/abc/snapshot")
        XCTAssertEqual(url.query, "since=3")
        let plain = try XCTUnwrap(DocumentCollabService.requestURL(endpoint: endpoint, path: "api/document/invites"))
        XCTAssertEqual(plain.absoluteString, "https://staging-api.studiquo.app/api/document/invites")
    }
}
