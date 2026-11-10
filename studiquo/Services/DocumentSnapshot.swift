import CryptoKit
import Foundation

/// The whole content of a shared document as one value: what the room stores
/// as its snapshot and what two devices merge. Plain `Codable` data, with the
/// SwiftData models on one side (`DocumentSnapshotCodec`) and the merge on the
/// other (`DocumentSnapshotMerge`). Large images are not inside it: a block
/// names its image by SHA-256 and the bytes travel separately.
struct DocumentSnapshot: Codable, Equatable {
    var version = 1
    var title: String
    var pageSize: String
    var columnCount: Int
    var header: HeaderFooter?
    var footer: HeaderFooter?
    var blocks: [Block]

    struct HeaderFooter: Codable, Equatable {
        var body: Data?
        var showsPageNumber: Bool

        static func == (lhs: HeaderFooter, rhs: HeaderFooter) -> Bool {
            lhs.showsPageNumber == rhs.showsPageNumber && SnapshotText.same(lhs.body, rhs.body)
        }
    }

    struct Cell: Codable, Equatable {
        var body: Data?
        var columnSpan: Int
        var rowSpan: Int

        static func == (lhs: Cell, rhs: Cell) -> Bool {
            lhs.columnSpan == rhs.columnSpan && lhs.rowSpan == rhs.rowSpan && SnapshotText.same(lhs.body, rhs.body)
        }
    }

    struct Comment: Codable, Equatable {
        var author: String
        var text: String
        var createdAt: Double
        var isResolved: Bool
    }

    struct Footnote: Codable, Equatable {
        var text: String
        var createdAt: Double
    }

    struct Block: Codable, Equatable, Identifiable {
        var id: String
        var kind: String
        /// Archived text of a paragraph; nil for other kinds.
        var body: Data?
        /// An image block's picture, by SHA-256 of its bytes (the bytes are an asset).
        var imageHash: String?
        var equationSource: String
        var listKind: String?
        var listLevel: Int
        var paragraphStyle: String?
        /// Table rows, each a list of cells; nil for other kinds.
        var rows: [[Cell]]?
        var comments: [Comment]
        var footnotes: [Footnote]

        static func == (lhs: Block, rhs: Block) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.imageHash == rhs.imageHash
                && lhs.equationSource == rhs.equationSource && lhs.listKind == rhs.listKind
                && lhs.listLevel == rhs.listLevel && lhs.paragraphStyle == rhs.paragraphStyle
                && lhs.rows == rhs.rows && lhs.comments == rhs.comments && lhs.footnotes == rhs.footnotes
                && SnapshotText.same(lhs.body, rhs.body)
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    /// A snapshot is written by another member of the room, so nothing in it is
    /// trusted: every snapshot read here goes through `validated()`.
    static func decoded(_ data: Data?) -> DocumentSnapshot? {
        guard let data else { return nil }
        return (try? JSONDecoder().decode(DocumentSnapshot.self, from: data))?.validated()
    }

    /// Bounds on what one snapshot may hold. All far above what the editor
    /// produces; they exist so that a snapshot made by hand cannot make this
    /// device crash, hang or run out of memory when it is applied and drawn.
    enum Limits {
        static let maxBlocks = 5_000
        static let maxTableRows = 1_000
        static let maxCellsPerRow = DocumentTableCell.maxColumnSpan
        static let maxCommentsPerBlock = 1_000
        static let maxFootnotesPerBlock = 1_000
        static let maxListLevel = 8
        static let columnCounts = 1...3
    }

    /// The snapshot with its numbers held to the ranges the app can draw, or
    /// nil when it holds more than `Limits` allows.
    ///
    /// Numbers out of range are corrected rather than refused: no editor writes
    /// them, and the document is still usable with the nearest valid value.
    /// Too many blocks, rows, cells or notes refuse the whole snapshot instead
    /// of cutting it short, because a member who can write would then send the
    /// shortened document back to the room as if the rest had been deleted.
    func validated() -> DocumentSnapshot? {
        guard blocks.count <= Limits.maxBlocks else { return nil }
        var result = self
        result.columnCount = min(max(columnCount, Limits.columnCounts.lowerBound), Limits.columnCounts.upperBound)
        for index in result.blocks.indices {
            var block = result.blocks[index]
            guard block.comments.count <= Limits.maxCommentsPerBlock,
                  block.footnotes.count <= Limits.maxFootnotesPerBlock else { return nil }
            block.listLevel = min(max(block.listLevel, 0), Limits.maxListLevel)
            if var rows = block.rows {
                guard rows.count <= Limits.maxTableRows else { return nil }
                for rowIndex in rows.indices {
                    guard rows[rowIndex].count <= Limits.maxCellsPerRow else { return nil }
                    for cellIndex in rows[rowIndex].indices {
                        let cell = rows[rowIndex][cellIndex]
                        rows[rowIndex][cellIndex].columnSpan = min(max(cell.columnSpan, 1), DocumentTableCell.maxColumnSpan)
                        rows[rowIndex][cellIndex].rowSpan = min(max(cell.rowSpan, 1), DocumentTableCell.maxRowSpan)
                    }
                }
                block.rows = rows
            }
            result.blocks[index] = block
        }
        return result
    }
}

enum SnapshotText {
    /// Two archived texts are the same when their bytes match or they decode to
    /// equal attributed strings (re-archiving unchanged text can change bytes),
    /// so an untouched paragraph is never mistaken for an edit.
    static func same(_ lhs: Data?, _ rhs: Data?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs else { return (lhs ?? Data()).isEmpty && (rhs ?? Data()).isEmpty }
        return DocumentBody.decode(lhs).isEqual(to: DocumentBody.decode(rhs))
    }
}

// MARK: - SwiftData <-> snapshot

enum DocumentSnapshotCodec {
    /// An image bigger than this (raw bytes) stays on its device: the room's
    /// per-image limit is 6M characters of base64.
    static let maxImageBytes = 4_400_000

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The document as a snapshot, plus the image bytes it refers to. Blocks
    /// that have no sync identity yet get one here.
    static func make(from document: TextDocument) -> (snapshot: DocumentSnapshot, assets: [String: Data]) {
        var assets: [String: Data] = [:]
        let blocks = document.sortedBlocks.map { block -> DocumentSnapshot.Block in
            if block.collabID == nil { block.collabID = UUID().uuidString.lowercased() }
            var imageHash: String?
            if block.kind == .image, let data = block.bodyData, !data.isEmpty, data.count <= maxImageBytes {
                imageHash = sha256Hex(data)
                assets[imageHash!] = data
            }
            return DocumentSnapshot.Block(
                id: block.collabID!,
                kind: block.kindRawValue,
                body: block.kind == .paragraph ? block.bodyData : nil,
                imageHash: imageHash,
                equationSource: block.equationSource,
                listKind: block.listKindRawValue,
                listLevel: block.listLevel,
                paragraphStyle: block.paragraphStyleRawValue,
                rows: block.kind == .table ? block.sortedTableRows.map { row in
                    row.sortedCells.map { DocumentSnapshot.Cell(body: $0.bodyData, columnSpan: $0.columnSpan, rowSpan: $0.rowSpan) }
                } : nil,
                comments: block.sortedAnchoredComments.map {
                    .init(author: $0.author, text: $0.text, createdAt: $0.createdAt.timeIntervalSince1970, isResolved: $0.isResolved)
                },
                footnotes: (block.anchoredFootnotes ?? []).sorted { $0.createdAt < $1.createdAt }.map {
                    .init(text: $0.text, createdAt: $0.createdAt.timeIntervalSince1970)
                }
            )
        }
        func headerFooter(_ value: DocumentHeaderFooter?) -> DocumentSnapshot.HeaderFooter? {
            guard let value, !(value.bodyData ?? Data()).isEmpty || value.showsPageNumber else { return nil }
            return .init(body: value.bodyData, showsPageNumber: value.showsPageNumber)
        }
        let snapshot = DocumentSnapshot(
            title: document.title,
            pageSize: document.pageSizeRawValue,
            columnCount: document.columnCount,
            header: headerFooter(document.header),
            footer: headerFooter(document.footer),
            blocks: blocks
        )
        return (snapshot, assets)
    }

    /// Makes `document` match `snapshot`: blocks are updated in place by their
    /// sync id (so the objects the editor holds stay valid where they can),
    /// added, removed and reordered. `assets` supplies image bytes by hash; an
    /// image whose bytes are unavailable keeps what the block already has.
    static func apply(_ unchecked: DocumentSnapshot, to document: TextDocument, assets: [String: Data]) {
        // Checked again here, whatever the caller did: this is the one place a
        // snapshot's values reach the stored document. One that is over the
        // limits changes nothing.
        guard let snapshot = unchecked.validated() else { return }
        if document.title != snapshot.title { document.title = snapshot.title }
        if document.pageSizeRawValue != snapshot.pageSize { document.pageSizeRawValue = snapshot.pageSize }
        if document.columnCount != snapshot.columnCount { document.columnCount = snapshot.columnCount }
        applyHeaderFooter(snapshot.header, kind: .header, to: document)
        applyHeaderFooter(snapshot.footer, kind: .footer, to: document)

        var existing: [String: DocumentBlock] = [:]
        for block in document.sortedBlocks { if let id = block.collabID { existing[id] = block } }
        var result: [DocumentBlock] = []
        var seen = Set<String>()
        for source in snapshot.blocks {
            // A snapshot naming one block twice would put one object in the document twice.
            guard seen.insert(source.id).inserted else { continue }
            let block: DocumentBlock
            if let found = existing[source.id], found.kindRawValue == source.kind {
                block = found
            } else {
                block = DocumentBlock(order: 0, kind: DocumentBlockKind(rawValue: source.kind) ?? .paragraph)
                block.collabID = source.id
                block.document = document
            }
            fill(block, from: source, assets: assets, in: document)
            result.append(block)
        }
        // Blocks that are no longer in the snapshot (deleted by the other side)
        // — and old objects replaced because their kind changed — go away.
        for block in document.sortedBlocks where !result.contains(where: { $0 === block }) {
            document.modelContext?.delete(block)
        }
        for (index, block) in result.enumerated() { block.order = index }
        document.blocks = result
        document.updatedAt = .now
    }

    private static func applyHeaderFooter(_ value: DocumentSnapshot.HeaderFooter?, kind: DocumentHeaderFooterKind, to document: TextDocument) {
        let current = kind == .header ? document.header : document.footer
        guard let value else {
            if let current, !(current.bodyData ?? Data()).isEmpty || current.showsPageNumber {
                current.bodyData = nil
                current.showsPageNumber = false
            }
            return
        }
        let target = document.headerFooter(kind)
        if !SnapshotText.same(target.bodyData, value.body) { target.bodyData = value.body }
        if target.showsPageNumber != value.showsPageNumber { target.showsPageNumber = value.showsPageNumber }
    }

    private static func fill(_ block: DocumentBlock, from source: DocumentSnapshot.Block, assets: [String: Data], in document: TextDocument) {
        if source.kind == DocumentBlockKind.paragraph.rawValue {
            if !SnapshotText.same(block.bodyData, source.body) { block.bodyData = source.body }
        } else if source.kind == DocumentBlockKind.image.rawValue, let hash = source.imageHash, let data = assets[hash] {
            if block.bodyData != data { block.bodyData = data }
        }
        if block.equationSource != source.equationSource { block.equationSource = source.equationSource }
        if block.listKindRawValue != source.listKind { block.listKindRawValue = source.listKind }
        if block.listLevel != source.listLevel { block.listLevel = source.listLevel }
        if block.paragraphStyleRawValue != source.paragraphStyle { block.paragraphStyleRawValue = source.paragraphStyle }

        if let rows = source.rows {
            let currentRows = block.sortedTableRows.map { $0.sortedCells.map {
                DocumentSnapshot.Cell(body: $0.bodyData, columnSpan: $0.columnSpan, rowSpan: $0.rowSpan)
            } }
            if currentRows != rows {
                for row in block.tableRows ?? [] { document.modelContext?.delete(row) }
                var newRows: [DocumentTableRow] = []
                for (rowIndex, cells) in rows.enumerated() {
                    let row = DocumentTableRow(order: rowIndex)
                    row.block = block
                    var newCells: [DocumentTableCell] = []
                    for (cellIndex, cell) in cells.enumerated() {
                        let model = DocumentTableCell(order: cellIndex)
                        model.bodyData = cell.body
                        model.columnSpan = cell.columnSpan
                        model.rowSpan = cell.rowSpan
                        model.row = row
                        newCells.append(model)
                    }
                    row.cells = newCells
                    newRows.append(row)
                }
                block.tableRows = newRows
            }
        }

        let currentComments = block.sortedAnchoredComments.map {
            DocumentSnapshot.Comment(author: $0.author, text: $0.text, createdAt: $0.createdAt.timeIntervalSince1970, isResolved: $0.isResolved)
        }
        if currentComments != source.comments {
            for comment in block.anchoredComments ?? [] { document.modelContext?.delete(comment) }
            block.anchoredComments = source.comments.map { value in
                let comment = DocumentComment(author: value.author, text: value.text, anchorBlock: block)
                comment.createdAt = Date(timeIntervalSince1970: value.createdAt)
                comment.isResolved = value.isResolved
                comment.document = document
                return comment
            }
        }
        let currentNotes = (block.anchoredFootnotes ?? []).sorted { $0.createdAt < $1.createdAt }.map {
            DocumentSnapshot.Footnote(text: $0.text, createdAt: $0.createdAt.timeIntervalSince1970)
        }
        if currentNotes != source.footnotes {
            for note in block.anchoredFootnotes ?? [] { document.modelContext?.delete(note) }
            block.anchoredFootnotes = source.footnotes.map { value in
                let note = DocumentFootnote(text: value.text, anchorBlock: block)
                note.createdAt = Date(timeIntervalSince1970: value.createdAt)
                note.document = document
                return note
            }
        }
    }
}

// MARK: - Three-way merge

/// Merges two devices' versions of a document against the version they both
/// started from, block by block (by sync id). A block only one side touched
/// takes that side's version; a block both touched keeps the local version
/// (the one being saved now, which is the later save) and is counted as a
/// conflict. A block one side deleted and the other left alone is deleted; one
/// side deleting what the other edited keeps the edit.
enum DocumentSnapshotMerge {
    struct Result {
        var snapshot: DocumentSnapshot
        var conflicts: Int
    }

    static func merge(base: DocumentSnapshot, local: DocumentSnapshot, remote: DocumentSnapshot) -> Result {
        var conflicts = 0
        func field<T: Equatable>(_ b: T, _ l: T, _ r: T) -> T {
            if l == b { return r }
            if r == b { return l }
            if l != r { conflicts += 1 }
            return l
        }
        let baseBlocks = Dictionary(base.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localBlocks = Dictionary(local.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteBlocks = Dictionary(remote.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var chosen: [String: DocumentSnapshot.Block] = [:]
        for id in Set(localBlocks.keys).union(remoteBlocks.keys) {
            let b = baseBlocks[id], l = localBlocks[id], r = remoteBlocks[id]
            switch (b, l, r) {
            case (_, let l?, let r?):
                if let b {
                    if l == b { chosen[id] = r }
                    else if r == b { chosen[id] = l }
                    else { if l != r { conflicts += 1 }; chosen[id] = l }
                } else {
                    chosen[id] = l   // the same new id on both sides: take ours
                }
            case (let b?, let l?, nil):   // deleted remotely
                if l != b { chosen[id] = l }   // but edited here: the edit stays
            case (let b?, nil, let r?):   // deleted locally
                if r != b { chosen[id] = r }
            case (nil, let l?, nil): chosen[id] = l   // new here
            case (nil, nil, let r?): chosen[id] = r   // new there
            default: break
            }
        }

        // Order: follow the side that reordered (if only one did), else the remote
        // one; blocks the chosen skeleton lacks are inserted after their
        // predecessor in the list they came from.
        let baseOrder = base.blocks.map(\.id)
        let localOrder = local.blocks.map(\.id).filter { chosen[$0] != nil }
        let remoteOrder = remote.blocks.map(\.id).filter { chosen[$0] != nil }
        let commonBase = baseOrder.filter { chosen[$0] != nil && localBlocks[$0] != nil && remoteBlocks[$0] != nil }
        let localCommon = localOrder.filter { commonBase.contains($0) }
        let remoteCommon = remoteOrder.filter { commonBase.contains($0) }
        let localReordered = localCommon != commonBase
        let remoteReordered = remoteCommon != commonBase
        let skeletonSource = (localReordered && !remoteReordered) ? localOrder : remoteOrder
        var order = skeletonSource
        for source in [localOrder, remoteOrder] {
            for (index, id) in source.enumerated() where !order.contains(id) {
                let predecessor = source[..<index].last(where: { order.contains($0) })
                if let predecessor, let at = order.firstIndex(of: predecessor) { order.insert(id, at: at + 1) }
                else { order.insert(id, at: 0) }
            }
        }

        let merged = DocumentSnapshot(
            title: field(base.title, local.title, remote.title),
            pageSize: field(base.pageSize, local.pageSize, remote.pageSize),
            columnCount: field(base.columnCount, local.columnCount, remote.columnCount),
            header: field(base.header, local.header, remote.header),
            footer: field(base.footer, local.footer, remote.footer),
            blocks: order.compactMap { chosen[$0] }
        )
        return Result(snapshot: merged, conflicts: conflicts)
    }
}
