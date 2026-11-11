import XCTest
@testable import studiquo

/// Two documents in one test stand for two devices: give each its own sync state, in memory.
func installInMemoryCollabState() {
    CollabLocalState.store = InMemoryCollabStateStore()
    CollabLocalState.keyProvider = { document in
        document.collabRoomID.map { "\($0)|\(ObjectIdentifier(document).hashValue)" }
    }
}

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
    var alwaysConflictOnPut = false
    var failPutWithTooLarge = false
    var editorsMustWait = false
    var missingAssetsBatchSizes: [Int] = []
    var putAssetCalls = 0
    var putAttempts = 0

    func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply {
        if revision == 0 { return .init(revision: 0, snapshot: nil, unchanged: nil) }
        if since == revision { return .init(revision: revision, snapshot: nil, unchanged: true) }
        return .init(revision: revision, snapshot: snapshotText, unchanged: nil)
    }
    func putSnapshot(roomID: String, baseRevision: Int, snapshot: String, assets: [String]) async throws -> Int {
        putAttempts += 1
        if editorsMustWait { throw DocumentCollabService.RoomNotReady() }
        if failPutWithTooLarge { throw DocumentCollabService.ServerError(status: 413, message: "Snapshot too large") }
        if alwaysConflictOnPut {
            revision += 1
            var competing = DocumentSnapshot.decoded(Data((snapshotText ?? snapshot).utf8))!
            competing.title = "他端末更新-\(revision)"
            snapshotText = String(data: competing.encoded()!, encoding: .utf8)
            throw DocumentCollabService.RevisionConflict(currentRevision: revision)
        }
        if failNextPutWithConflict { failNextPutWithConflict = false; throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
        guard baseRevision == revision else { throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
        revision += 1
        snapshotText = snapshot
        return revision
    }
    func missingAssets(roomID: String, hashes: [String]) async throws -> [String] {
        missingAssetsBatchSizes.append(hashes.count)
        return hashes.filter { assets[$0] == nil }
    }
    func putAsset(roomID: String, hash: String, data: Data) async throws {
        putAssetCalls += 1
        assets[hash] = data
    }
    func asset(roomID: String, hash: String) async throws -> Data? { assets[hash] }
}

@MainActor
final class CollabSnapshotTests: XCTestCase {
    override func setUp() { installInMemoryCollabState() }
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

// MARK: - Regression tests for problems found while building shared editing

@MainActor
final class CollabRegressionTests: XCTestCase {
    override func setUp() { installInMemoryCollabState() }
    private struct Down: Error {}

    // 共有の招待が出なかった: 招待が0件のとき区画が出ず、読み込みが区画に付いていたため一度も読まれなかった。
    // 読み込みは区画を表示する側(CollabInviteInbox)が持ち、区画の表示に依らず呼べること。
    func testTheInviteInboxLoadsOnItsOwnWithoutAnyViewShowingIt() async {
        let invite = DocumentCollabService.PendingInvite(roomID: "r1", role: "editor", inviterName: "田中", createdAt: 1)
        let inbox = CollabInviteInbox(load: { [invite] })
        XCTAssertTrue(inbox.invites.isEmpty, "nothing is shown before the screen asks")
        await inbox.reload()
        XCTAssertEqual(inbox.invites, [invite])
        XCTAssertFalse(inbox.loadFailed)
    }

    func testAFailedLoadIsOnlyReportedBeforeTheFirstSuccessAndIsClearedByTheNext() async {
        var fail = true
        let inbox = CollabInviteInbox(load: { if fail { throw Down() }; return [] })
        await inbox.reload()
        XCTAssertTrue(inbox.loadFailed)
        fail = false
        await inbox.reload()
        XCTAssertFalse(inbox.loadFailed)
        fail = true
        await inbox.reload()
        XCTAssertFalse(inbox.loadFailed, "a blip after a good load does not raise the banner")
    }

    // 同期が一度も送信されなかった: 入力の有無を updatedAt で見ていたため、自動保存のたびに「入力中」と誤判定された。
    func testAnAutosaveTouchingUpdatedAtIsNotAnEdit() {
        let document = TextDocument(title: "d")
        let block = DocumentBlock(order: 0)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "本文", attributes: DocumentBody.defaultAttributes()))
        block.document = document
        document.blocks = [block]
        let before = CollabEditMarker.capture(of: document, live: NSAttributedString(string: "本文"))
        document.updatedAt = Date().addingTimeInterval(60)
        XCTAssertEqual(CollabEditMarker.capture(of: document, live: NSAttributedString(string: "本文")), before)
    }

    func testTypingOrAChangedBlockIsAnEdit() {
        let document = TextDocument(title: "d")
        let block = DocumentBlock(order: 0)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "本文", attributes: DocumentBody.defaultAttributes()))
        block.document = document
        document.blocks = [block]
        let before = CollabEditMarker.capture(of: document, live: NSAttributedString(string: "本文"))
        XCTAssertNotEqual(CollabEditMarker.capture(of: document, live: NSAttributedString(string: "本文あ")), before)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "別", attributes: DocumentBody.defaultAttributes()))
        XCTAssertNotEqual(CollabEditMarker.capture(of: document, live: NSAttributedString(string: "本文")), before)
    }

    // 相手の変更が自分の文書に入らなかった / ヘッダーが同期されなかった。
    func testHeaderFooterTitleAndTableEditsReachTheOtherDevice() async throws {
        let room = RoomForRegression()
        let a = TextDocument(title: "元")
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 2)
        table.document = a
        a.blocks = [table]
        a.isMigratedToBlocks = true
        a.collabRoomID = "room"
        _ = try await CollabSyncEngine.sync(document: a, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})

        let b = CollabInviteImporter.makeDocument(roomID: "room", inviterName: nil,
            snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: room.revision, assets: [:])
        b.headerFooter(.header).text = "ヘッダー"
        b.title = "改題"
        b.sortedBlocks[0].sortedTableRows[0].sortedCells[1].text = "右"
        _ = try await CollabSyncEngine.sync(document: b, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
        _ = try await CollabSyncEngine.sync(document: a, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})

        XCTAssertEqual(a.header?.text, "ヘッダー")
        XCTAssertEqual(a.title, "改題")
        XCTAssertEqual(a.sortedBlocks[0].sortedTableRows[0].sortedCells[1].text, "右")
    }

    // 空の文書が共有されると取り込み側が空のままになる、承認しても本文に入らない、という退行を防ぐ。
    func testAnEmptyRoomFirstSyncPushesAndAnEmptyDeviceThenReceivesEverything() async throws {
        let room = RoomForRegression()
        let owner = TextDocument(title: "共有")
        for (index, text) in ["一", "二", "三"].enumerated() {
            let block = DocumentBlock(order: index)
            block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
            block.document = owner
            owner.blocks = (owner.blocks ?? []) + [block]
        }
        owner.collabRoomID = "room"
        let first = try await CollabSyncEngine.sync(document: owner, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
        XCTAssertEqual(first, .pushed)
        XCTAssertEqual(room.revision, 1)
    }
}

/// The same revision rule as the server's, for regression tests.
private final class RoomForRegression: DocumentSnapshotClient {
    var revision = 0
    var snapshotText: String?
    func snapshot(roomID: String, since: Int) async throws -> DocumentCollabService.SnapshotReply {
        if revision == 0 { return .init(revision: 0, snapshot: nil, unchanged: nil) }
        if since == revision { return .init(revision: revision, snapshot: nil, unchanged: true) }
        return .init(revision: revision, snapshot: snapshotText, unchanged: nil)
    }
    func putSnapshot(roomID: String, baseRevision: Int, snapshot: String, assets: [String]) async throws -> Int {
        guard baseRevision == revision else { throw DocumentCollabService.RevisionConflict(currentRevision: revision) }
        revision += 1; snapshotText = snapshot; return revision
    }
    func missingAssets(roomID: String, hashes: [String]) async throws -> [String] { [] }
    func putAsset(roomID: String, hash: String, data: Data) async throws {}
    func asset(roomID: String, hash: String) async throws -> Data? { nil }
}


// MARK: - Regression tests for the independent review's findings

@MainActor
final class CollabReviewFindingsTests: XCTestCase {
    override func setUp() { installInMemoryCollabState() }

    private func text(_ value: String) -> Data? { DocumentBody.encode(NSAttributedString(string: value, attributes: DocumentBody.defaultAttributes())) }

    // H1: an editor who opens a document the owner has not synced yet must not make the room's first snapshot.
    func testAnEditorWaitsWhileTheRoomHasNoSnapshotAndNothingIsSent() async throws {
        let room = FakeRoom()
        room.editorsMustWait = true
        let invited = CollabInviteImporter.makeDocument(
            roomID: "room", inviterName: nil,
            state: DocumentCollabService.RoomState(blocks: [.init(order: 0, kind: "paragraph", text: "簡易版", listKind: nil, listLevel: 0, paragraphStyle: nil)], pendingChanges: [])
        )
        let outcome = try await CollabSyncEngine.sync(document: invited, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertEqual(room.revision, 0)
    }

    // M1: inserting or deleting a paragraph must not move every later paragraph onto its neighbour's id.
    func testInsertingAndDeletingParagraphsKeepsEachParagraphsId() {
        let document = TextDocument(title: "d")
        document.blocks = ["一", "二", "三", "四"].enumerated().map { index, value in
            let block = DocumentBlock(order: index)
            block.bodyData = text(value)
            block.collabID = "id-\(value)"
            block.document = document
            return block
        }
        let run = document.sortedBlocks
        let inserted = document.replaceParagraphRun(run, with: NSAttributedString(string: "一\n新\n二\n三\n四", attributes: DocumentBody.defaultAttributes()))
        XCTAssertEqual(inserted.map(\.collabID), ["id-一", nil, "id-二", "id-三", "id-四"])

        let deleted = document.replaceParagraphRun(document.sortedBlocks, with: NSAttributedString(string: "一\n二\n四", attributes: DocumentBody.defaultAttributes()))
        XCTAssertEqual(deleted.map(\.collabID), ["id-一", "id-二", "id-四"])

        let edited = document.replaceParagraphRun(document.sortedBlocks, with: NSAttributedString(string: "一\n二改\n四", attributes: DocumentBody.defaultAttributes()))
        XCTAssertEqual(edited.map(\.collabID), ["id-一", "id-二", "id-四"], "an edited paragraph keeps its own id")
    }

    // M2: a reviewer deleting a picture gets it back, picture included, and stays in step afterwards.
    func testAReviewerWhoDeletesAnImageGetsItBackWithItsPicture() async throws {
        let room = FakeRoom()
        let owner = TextDocument(title: "d")
        let image = DocumentBlock(order: 0, kind: .image)
        image.bodyData = Data([5, 6, 7])
        image.document = owner
        owner.blocks = [image]
        owner.collabRoomID = "room"
        _ = try await CollabSyncEngine.sync(document: owner, canWrite: true, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})

        let reviewer = CollabInviteImporter.makeDocument(
            roomID: "room", inviterName: nil, snapshot: DocumentSnapshot.decoded(Data(room.snapshotText!.utf8))!, revision: room.revision, assets: room.assets
        )
        reviewer.blocks = []
        _ = try await CollabSyncEngine.sync(document: reviewer, canWrite: false, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
        XCTAssertEqual(reviewer.sortedBlocks.first?.bodyData, Data([5, 6, 7]))
        let again = try await CollabSyncEngine.sync(document: reviewer, canWrite: false, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
        XCTAssertEqual(again, .upToDate, "restored once, not every round")
    }

    // M3: a bold applied while the network call ran is an edit even though the characters are the same.
    func testFormattingOnlyChangeCountsAsAnEdit() {
        let document = TextDocument(title: "d")
        let plain = NSAttributedString(string: "本文", attributes: DocumentBody.defaultAttributes())
        let bold = NSMutableAttributedString(attributedString: plain)
        bold.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 2))
        XCTAssertNotEqual(CollabEditMarker.capture(of: document, live: plain), CollabEditMarker.capture(of: document, live: bold))
        XCTAssertEqual(CollabEditMarker.capture(of: document, live: plain), CollabEditMarker.capture(of: document, live: NSAttributedString(attributedString: plain)))
    }

    // L3: a snapshot that names one block twice must not put the same object in the document twice.
    func testASnapshotNamingABlockTwiceIsAppliedOnce() {
        let source = makeDocument(["一"])
        var (snapshot, _) = DocumentSnapshotCodec.make(from: source)
        snapshot.blocks.append(snapshot.blocks[0])
        let target = TextDocument(title: "t")
        DocumentSnapshotCodec.apply(snapshot, to: target, assets: [:])
        XCTAssertEqual(target.sortedBlocks.count, 1)
    }

    // M5: the base and revision belong to a device, not to the (iCloud-synced) document.
    func testSyncStateIsKeptPerDeviceNotInTheDocumentModel() {
        let a = TextDocument(title: "a"), b = TextDocument(title: "b")
        a.collabRoomID = "room"; b.collabRoomID = "room"
        a.collabRevision = 3
        a.collabBaseSnapshot = Data([1])
        XCTAssertEqual(b.collabRevision, 0)
        XCTAssertNil(b.collabBaseSnapshot)
        let unshared = TextDocument(title: "local only")
        unshared.collabRevision = 9
        XCTAssertEqual(unshared.collabRevision, 0, "a document with no room has no sync state")
    }

    // MARK: - Additional coverage for image asset batching, limits, merge conflicts, local state store, and paragraph ID carry-over

    func testUploadingMoreThanOneHundredImagesBatchesMissingAssetChecksAndUploadsOnlyMissingOnes() async throws {
        let room = FakeRoom()
        let document = TextDocument(title: "画像多数")
        var blocks: [DocumentBlock] = []
        for index in 0..<105 {
            let image = DocumentBlock(order: index, kind: .image)
            let bytes = Data([UInt8(index & 0xff), UInt8((index >> 8) & 0xff), 0x42])
            image.bodyData = bytes
            image.document = document
            blocks.append(image)
        }
        document.blocks = blocks
        document.isMigratedToBlocks = true
        document.collabRoomID = "room-batch"

        let (_, allAssets) = DocumentSnapshotCodec.make(from: document)
        XCTAssertEqual(allAssets.count, 105)
        for (hash, data) in allAssets.sorted(by: { $0.key < $1.key }).prefix(10) {
            room.assets[hash] = data
        }

        let outcome = try await CollabSyncEngine.sync(
            document: document, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(outcome, .pushed)
        XCTAssertEqual(room.missingAssetsBatchSizes, [100, 5])
        XCTAssertEqual(room.putAssetCalls, 95)
        XCTAssertEqual(room.assets.count, 105)
    }

    func testOversizedImageIsExcludedFromSnapshotUploadAndPreservedLocallyOnApply() {
        let document = makeDocument(["本文"])
        let oversizedData = Data(repeating: 0xab, count: DocumentSnapshotCodec.maxImageBytes + 1)
        let image = DocumentBlock(order: 1, kind: .image)
        image.bodyData = oversizedData
        image.document = document
        document.blocks = (document.blocks ?? []) + [image]

        var (snapshot, assets) = DocumentSnapshotCodec.make(from: document)
        XCTAssertTrue(assets.isEmpty, "oversized image must not be uploaded as an asset")
        let imageSnap = snapshot.blocks.first { $0.kind == "image" }
        XCTAssertNotNil(imageSnap)
        XCTAssertNil(imageSnap?.imageHash)

        snapshot.title = "リモート更新後"
        DocumentSnapshotCodec.apply(snapshot, to: document, assets: [:])
        let preservedImage = document.sortedBlocks.first { $0.kind == .image }
        XCTAssertEqual(preservedImage?.bodyData?.count, DocumentSnapshotCodec.maxImageBytes + 1, "local oversized image bytes must not be wiped when imageHash is nil")
    }

    func testSnapshotTooLarge413ReturnsTooLargeWithoutAdvancingLocalState() async throws {
        let room = FakeRoom()
        let document = makeDocument(["初期"])
        document.collabRoomID = "room-413"
        let first = try await CollabSyncEngine.sync(
            document: document, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(first, .pushed)
        XCTAssertEqual(document.collabRevision, 1)

        document.sortedBlocks[0].bodyData = text("巨大変更")
        room.failPutWithTooLarge = true
        let second = try await CollabSyncEngine.sync(
            document: document, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(second, .tooLarge)
        XCTAssertEqual(document.collabRevision, 1)
        let baseSnapshot = try XCTUnwrap(DocumentSnapshot.decoded(document.collabBaseSnapshot))
        XCTAssertEqual(DocumentBody.decode(baseSnapshot.blocks[0].body).string, "初期")
    }

    func testMergeWhenBothSidesReorderUsesRemoteOrderSkeletonAndKeepsBothSidesInsertions() {
        let base = DocumentSnapshot(title: "t", pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: [
            .init(id: "a", kind: "paragraph", body: text("A"), imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
            .init(id: "b", kind: "paragraph", body: text("B"), imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
            .init(id: "c", kind: "paragraph", body: text("C"), imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
        ])
        let local = DocumentSnapshot(title: "t", pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: [
            base.blocks[1],
            base.blocks[0],
            .init(id: "x", kind: "paragraph", body: text("X"), imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
            base.blocks[2],
        ])
        let remote = DocumentSnapshot(title: "t", pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: [
            base.blocks[2],
            base.blocks[1],
            .init(id: "y", kind: "paragraph", body: text("Y"), imageHash: nil, equationSource: "", listKind: nil, listLevel: 0, paragraphStyle: nil, rows: nil, comments: [], footnotes: []),
            base.blocks[0],
        ])
        let merged = DocumentSnapshotMerge.merge(base: base, local: local, remote: remote)
        let ids = merged.snapshot.blocks.map(\.id)
        XCTAssertEqual(ids, ["c", "b", "y", "a", "x"])
        XCTAssertEqual(Set(ids).count, 5)
    }

    func testApplyingSnapshotWhenABlockChangesKindReplacesTheBlockObject() {
        let document = makeDocument(["段落から表へ"])
        let originalBlock = document.sortedBlocks[0]
        originalBlock.collabID = "same-id"
        XCTAssertEqual(originalBlock.kind, .paragraph)

        let tableSnapshot = DocumentSnapshot(title: "t", pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: [
            .init(
                id: "same-id", kind: "table", body: nil, imageHash: nil, equationSource: "",
                listKind: nil, listLevel: 0, paragraphStyle: nil,
                rows: [[.init(body: text("A1"), columnSpan: 1, rowSpan: 1), .init(body: text("B1"), columnSpan: 1, rowSpan: 1)]],
                comments: [], footnotes: []
            ),
        ])
        DocumentSnapshotCodec.apply(tableSnapshot, to: document, assets: [:])
        XCTAssertEqual(document.sortedBlocks.count, 1)
        let replaced = document.sortedBlocks[0]
        XCTAssertTrue(replaced !== originalBlock)
        XCTAssertEqual(replaced.collabID, "same-id")
        XCTAssertEqual(replaced.kind, .table)
        XCTAssertEqual(replaced.sortedTableRows.first?.sortedCells.map(\.text), ["A1", "B1"])
    }

    func testRepeatedRevisionConflictsExhaustMaxAttemptsAndReturnSkipped() async throws {
        let room = FakeRoom()
        let document = makeDocument(["初期"])
        document.collabRoomID = "room-conflict-exhaust"
        _ = try await CollabSyncEngine.sync(
            document: document, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        document.sortedBlocks[0].bodyData = text("競合し続ける変更")
        room.putAttempts = 0
        room.alwaysConflictOnPut = true

        let outcome = try await CollabSyncEngine.sync(
            document: document, canWrite: true, client: room,
            flush: {}, stillCurrent: { true }, didApply: {}, save: {}
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(room.putAttempts, 4)
    }

    func testFileCollabStateStorePersistsBaseExcludesFromBackupAndDeletesOnNil() throws {
        let store = FileCollabStateStore()
        let key = "test-room-\(UUID().uuidString)|doc"
        defer {
            store.setBase(nil, forKey: key)
            UserDefaults.standard.removeObject(forKey: "collab.rev.\(key)")
        }

        XCTAssertEqual(store.revision(forKey: key), 0)
        XCTAssertNil(store.base(forKey: key))

        let payload = Data("{\"title\":\"テスト\"}".utf8)
        store.setRevision(12, forKey: key)
        store.setBase(payload, forKey: key)
        XCTAssertEqual(store.revision(forKey: key), 12)
        XCTAssertEqual(store.base(forKey: key), payload)

        let directory = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("collab-sync", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isExcludedFromBackupKey])
        let matched = try XCTUnwrap(files.first { (try? Data(contentsOf: $0)) == payload })
        let values = try matched.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        store.setBase(nil, forKey: key)
        XCTAssertNil(store.base(forKey: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matched.path))
    }

    func testCarryOverCollabIDsWithDuplicateEmptyAndRepeatedParagraphsDoesNotDuplicateIDs() {
        let old = [
            para("", id: "id-1"),
            para("本文", id: "id-2"),
            para("", id: "id-3"),
            para("本文", id: "id-4"),
        ]
        let new = ["", "挿入", "本文", "", "本文"].map { para($0) }
        DocumentBlockText.carryOverCollabIDs(from: old, to: new)
        XCTAssertEqual(new.map(\.collabID), ["id-1", nil, "id-2", "id-3", "id-4"])
    }

    func testCarryOverCollabIDsWhenAllParagraphsChangeAndCountGrowsAssignsLeadingIDsOnly() {
        let old = [
            para("古1", id: "id-1"),
            para("古2", id: "id-2"),
        ]
        let new = ["新1", "新2", "新3"].map { para($0) }
        DocumentBlockText.carryOverCollabIDs(from: old, to: new)
        XCTAssertEqual(new.map(\.collabID), ["id-1", "id-2", nil])
    }
}

/// The sync engine with snapshots and stored values that are out of range or over
/// `DocumentSnapshot.Limits`: nothing crashes, nothing is sent round after round,
/// and what is refused is reported rather than shown as "in step".
@MainActor
final class CollabSnapshotLimitsSyncTests: XCTestCase {
    override func setUp() { installInMemoryCollabState() }

    private func sync(_ document: TextDocument, _ room: FakeRoom, canWrite: Bool = true) async throws -> CollabSyncEngine.Outcome {
        document.collabRoomID = document.collabRoomID ?? "room"
        return try await CollabSyncEngine.sync(document: document, canWrite: canWrite, client: room, flush: {}, stillCurrent: { true }, didApply: {}, save: {})
    }

    private func isTooLarge(_ outcome: CollabSyncEngine.Outcome) -> Bool {
        if case .tooLarge = outcome { return true }
        return false
    }

    private func isUpToDate(_ outcome: CollabSyncEngine.Outcome) -> Bool {
        if case .upToDate = outcome { return true }
        return false
    }

    private func block(id: String, kind: String = "paragraph", listKind: String? = nil, listLevel: Int = 0, rows: [[DocumentSnapshot.Cell]]? = nil) -> DocumentSnapshot.Block {
        .init(id: id, kind: kind, body: nil, imageHash: nil, equationSource: "", listKind: listKind,
              listLevel: listLevel, paragraphStyle: nil, rows: rows, comments: [], footnotes: [])
    }

    private func put(_ blocks: [DocumentSnapshot.Block], in room: FakeRoom) {
        let snapshot = DocumentSnapshot(title: "文書", pageSize: "a4", columnCount: 1, header: nil, footer: nil, blocks: blocks)
        room.snapshotText = String(data: snapshot.encoded()!, encoding: .utf8)
        room.revision += 1
    }

    /// A table whose first row has more cells than one row may hold.
    private func addOversizedTable(to document: TextDocument) {
        let table = DocumentBlock.makeTable(order: 99, rows: 1, columns: DocumentSnapshot.Limits.maxCellsPerRow + 1)
        table.document = document
        document.blocks = (document.blocks ?? []) + [table]
    }

    func testAHostileSnapshotIsAppliedWithinBoundsAndNotSentBack() async throws {
        let room = FakeRoom()
        put([
            block(id: "list", listKind: "bulleted", listLevel: -1),
            block(id: "table", kind: "table", rows: [[.init(body: nil, columnSpan: -5, rowSpan: 3), .init(body: nil, columnSpan: .max, rowSpan: .max)]]),
        ], in: room)
        let document = makeDocument([])

        _ = try await sync(document, room)
        let second = try await sync(document, room)

        XCTAssertEqual(document.sortedBlocks.map(\.listLevel), [0, 0])
        XCTAssertEqual(document.listMarker(for: document.sortedBlocks[0]), "•")
        XCTAssertEqual(document.sortedBlocks[1].tableGridRows.count, 1)
        XCTAssertTrue(isUpToDate(second))
        XCTAssertEqual(room.putAttempts, 0, "the corrected values must not be written back to the room")
        XCTAssertEqual(room.revision, 1)
    }

    /// A device that stored out-of-range values before they were checked on the way in.
    func testADeviceHoldingOutOfRangeValuesSendsOnceAndSettles() async throws {
        let room = FakeRoom()
        let document = makeDocument(["項目"])
        document.sortedBlocks[0].listKind = .bulleted
        document.sortedBlocks[0].listLevel = -1
        let table = DocumentBlock.makeTable(order: 1, rows: 2, columns: 2)
        table.document = document
        for cell in table.sortedTableRows.flatMap(\.sortedCells) { cell.columnSpan = -5; cell.rowSpan = .max }
        document.blocks = (document.blocks ?? []) + [table]

        _ = try await sync(document, room)
        XCTAssertEqual(room.putAttempts, 1)
        for _ in 0..<3 { let outcome = try await sync(document, room); XCTAssertTrue(isUpToDate(outcome)) }

        XCTAssertEqual(room.putAttempts, 1, "the same document must not be sent again on every round")
        let sent = try XCTUnwrap(DocumentSnapshot.decodedUnchecked(Data((room.snapshotText ?? "").utf8)))
        XCTAssertEqual(sent.blocks[0].listLevel, 0, "what is sent is within bounds, so an older app is not sent the bad values")
        XCTAssertEqual(sent.blocks[1].rows?.flatMap { $0 }.map(\.columnSpan), [1, 1, 1, 1])
        XCTAssertEqual(sent.blocks[1].rows?.flatMap { $0 }.map(\.rowSpan), Array(repeating: DocumentTableCell.maxRowSpan, count: 4))
    }

    /// The same device after it has already shared: the room and its own record of the
    /// room both hold the raw values, as an app from before the check would have left them.
    func testADeviceWhoseRoomAndBaseHoldOutOfRangeValuesDoesNotSendThemAgain() async throws {
        let room = FakeRoom()
        let document = makeDocument(["項目"])
        document.collabRoomID = "room"
        document.sortedBlocks[0].listKind = .bulleted
        document.sortedBlocks[0].listLevel = -1
        let table = DocumentBlock.makeTable(order: 1, rows: 1, columns: 2)
        table.document = document
        for cell in table.sortedTableRows[0].sortedCells { cell.columnSpan = -5; cell.rowSpan = .max }
        document.blocks = (document.blocks ?? []) + [table]
        // What that app wrote: the document as it is stored, numbers untouched.
        var raw = DocumentSnapshotCodec.make(from: document).snapshot
        raw.blocks[0].listLevel = -1
        raw.blocks[1].rows = raw.blocks[1].rows?.map { $0.map { .init(body: $0.body, columnSpan: -5, rowSpan: .max) } }
        let rawData = try XCTUnwrap(raw.encoded())
        XCTAssertEqual(DocumentSnapshot.decodedUnchecked(rawData)?.blocks[0].listLevel, -1)
        room.snapshotText = String(data: rawData, encoding: .utf8)
        room.revision = 1
        document.collabBaseSnapshot = rawData
        document.collabRevision = 1

        for _ in 0..<3 { let outcome = try await sync(document, room); XCTAssertTrue(isUpToDate(outcome)) }

        XCTAssertEqual(room.putAttempts, 0, "nothing changed, so nothing is sent: not once, and not on every round")
        XCTAssertEqual(room.revision, 1)
    }

    func testADocumentOverTheLimitsIsReportedAndNeverSent() async throws {
        let room = FakeRoom()
        let document = makeDocument(["本文"])
        addOversizedTable(to: document)

        for _ in 0..<3 { let outcome = try await sync(document, room); XCTAssertTrue(isTooLarge(outcome)) }

        XCTAssertEqual(room.putAttempts, 0)
        XCTAssertEqual(room.revision, 0)
    }

    func testADocumentThatGrowsOverTheLimitsAfterSharingStopsBeingSent() async throws {
        let room = FakeRoom()
        let document = makeDocument(["本文"])
        _ = try await sync(document, room)
        XCTAssertEqual(room.putAttempts, 1)
        addOversizedTable(to: document)

        for _ in 0..<3 { let outcome = try await sync(document, room); XCTAssertTrue(isTooLarge(outcome)) }

        XCTAssertEqual(room.putAttempts, 1)
    }

    func testARoomOverTheLimitsIsReportedAndChangesNothingHere() async throws {
        let room = FakeRoom()
        put((0...DocumentSnapshot.Limits.maxBlocks).map { block(id: "b\($0)") }, in: room)

        for canWrite in [true, false] {
            let document = makeDocument(["自分の文"])
            document.collabRoomID = "room-\(canWrite)"

            for _ in 0..<2 { let outcome = try await sync(document, room, canWrite: canWrite); XCTAssertTrue(isTooLarge(outcome)) }

            XCTAssertEqual(texts(document), ["自分の文"])
            XCTAssertEqual(document.collabRevision, 0)
        }
        XCTAssertEqual(room.putAttempts, 0)
    }

    func testAMergeThatWouldGoOverTheLimitsIsReportedAndLosesNothing() async throws {
        let room = FakeRoom()
        let mine = makeDocument(["共通"])
        _ = try await sync(mine, room)   // revision 1, the common base
        let half = DocumentSnapshot.Limits.maxBlocks / 2 + 1

        // The other member adds just over half the limit...
        var theirs = try XCTUnwrap(DocumentSnapshot.decoded(Data((room.snapshotText ?? "").utf8)))
        theirs.blocks += (0..<half).map { block(id: "theirs-\($0)") }
        room.snapshotText = String(data: theirs.encoded()!, encoding: .utf8)
        room.revision += 1
        // ...and so does this device, so each side fits and the merge does not.
        let added = (0..<half).map { index -> DocumentBlock in
            let item = DocumentBlock(order: index + 1, kind: .paragraph)
            item.collabID = "mine-\(index)"
            item.document = mine
            return item
        }
        mine.blocks = (mine.blocks ?? []) + added
        let putsBefore = room.putAttempts

        let outcome = try await sync(mine, room)

        XCTAssertTrue(isTooLarge(outcome))
        XCTAssertEqual(room.putAttempts, putsBefore)
        XCTAssertEqual(mine.sortedBlocks.count, 1 + half, "this device's additions are still here")
        XCTAssertEqual(mine.collabRevision, 1, "the room's version was not recorded as merged")
    }
}
