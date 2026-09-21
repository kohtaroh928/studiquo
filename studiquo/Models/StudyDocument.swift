import Foundation
import SwiftData
import SwiftUI

// MARK: - Word-style text document

/// A flowing text document, alongside the app's handwritten notes.
///
/// The body is a real `NSAttributedString` archived to `Data` rather than a
/// bespoke block model. That is what makes character-level formatting —
/// mixed bold/italic inside one paragraph, per-run colour and size, inline
/// images — behave the way a word processor's does, and it hands paragraph
/// styles, list rendering and pagination to TextKit instead of reimplementing
/// them.
@Model
final class TextDocument {
    var title: String = "無題の文書"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var folderName: String = ""
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    /// Archived `NSAttributedString` (see `DocumentBody`).
    @Attribute(.externalStorage) var bodyData: Data?
    /// Kept in sync on every save so the library can show a preview and the
    /// MCP snapshot has something readable without unarchiving.
    var plainText: String = ""
    var pageSizeRawValue: String = DocumentPageSize.a4.rawValue
    /// 1-3. Only affects PDF export (see `ExportService.pdfData(from:
    /// TextDocument)`) — the live editor stays single-column; see that
    /// method's doc comment for why.
    var columnCount: Int = 1
    /// Back-reference from `AIReviewItem.explanationDocument`. CloudKit sync
    /// requires every relationship to have an explicit inverse; without this,
    /// the whole schema fails CloudKit validation at launch, not just this
    /// one relationship.
    var aiReviewItem: AIReviewItem?

    // MARK: Block-based structure (tables, headers/footers, comments, change tracking)

    @Relationship(deleteRule: .cascade, inverse: \DocumentBlock.document)
    var blocks: [DocumentBlock]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentHeaderFooter.document)
    var headerFooters: [DocumentHeaderFooter]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentComment.document)
    var comments: [DocumentComment]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentChangeRecord.document)
    var changeRecords: [DocumentChangeRecord]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentFootnote.document)
    var footnotes: [DocumentFootnote]?

    /// Whether `bodyData` has been converted into `blocks` yet, via
    /// `DocumentBlockMigration.migrateIfNeeded`. `bodyData` is deliberately
    /// left in place even after migration succeeds — see that type's doc
    /// comment for why.
    var isMigratedToBlocks: Bool = false

    /// The server-side `DocumentRoom`'s id (see `DocumentCollabService`) once
    /// this document has collaboration turned on, or nil if it's still
    /// local-only. A 64-hex-character string minted client-side by whoever
    /// first turns collaboration on for this document.
    var collabRoomID: String?

    init(title: String = "無題の文書") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedBlocks: [DocumentBlock] {
        (blocks ?? []).sorted { $0.order < $1.order }
    }

    var header: DocumentHeaderFooter? {
        (headerFooters ?? []).first { $0.kind == .header }
    }

    var footer: DocumentHeaderFooter? {
        (headerFooters ?? []).first { $0.kind == .footer }
    }

    /// Returns the existing header/footer, or creates and attaches an empty
    /// one — the editor calls this the moment someone taps into the header
    /// or footer area, rather than every document paying the relationship
    /// overhead for a header/footer it never uses.
    func headerFooter(_ kind: DocumentHeaderFooterKind) -> DocumentHeaderFooter {
        if let existing = (headerFooters ?? []).first(where: { $0.kind == kind }) { return existing }
        let created = DocumentHeaderFooter(kind: kind)
        created.document = self
        headerFooters = (headerFooters ?? []) + [created]
        return created
    }

    var pendingChangeRecords: [DocumentChangeRecord] {
        (changeRecords ?? []).filter { $0.status == .pending }
    }

    /// Every footnote, in document order — its anchor block's position
    /// among `sortedBlocks` first, then creation time to break ties between
    /// several footnotes on the same paragraph. A footnote whose anchor
    /// block no longer exists sorts last, after every still-anchored one.
    var sortedFootnotes: [DocumentFootnote] {
        let order = sortedBlocks
        func blockIndex(_ footnote: DocumentFootnote) -> Int {
            guard let anchor = footnote.anchorBlock,
                  let index = order.firstIndex(where: { $0 === anchor }) else { return Int.max }
            return index
        }
        return (footnotes ?? []).sorted { lhs, rhs in
            let lhsIndex = blockIndex(lhs)
            let rhsIndex = blockIndex(rhs)
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// 1-based position of `footnote` in `sortedFootnotes` — not stored, so
    /// footnotes renumber automatically as they're added, removed, or their
    /// anchor paragraphs get reordered. `nil` if `footnote` isn't this
    /// document's.
    func footnoteNumber(for footnote: DocumentFootnote) -> Int? {
        sortedFootnotes.firstIndex(where: { $0 === footnote }).map { $0 + 1 }
    }

    var pageSize: DocumentPageSize {
        get { DocumentPageSize(rawValue: pageSizeRawValue) ?? .a4 }
        set { pageSizeRawValue = newValue.rawValue }
    }

    var wordCount: Int {
        plainText.split { $0.isWhitespace || $0.isNewline }.count
    }

    var characterCount: Int {
        plainText.replacingOccurrences(of: "\n", with: "").count
    }
}

enum DocumentPageSize: String, CaseIterable, Identifiable {
    case a4, letter, b5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "レター"
        case .b5: "B5"
        }
    }

    /// In points, at 72 dpi — the unit `UIGraphicsPDFRenderer` works in.
    var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .letter: CGSize(width: 612, height: 792)
        case .b5: CGSize(width: 516, height: 729)
        }
    }

    /// Word's default margin is one inch; this matches it.
    var margin: CGFloat { 72 }
}

/// The paragraph styles offered in the style menu, mirroring the ones a word
/// processor puts at the front of its gallery. Each carries the concrete
/// typography it applies, so applying a style is one assignment rather than a
/// scattering of attribute writes.
enum DocumentParagraphStyle: String, CaseIterable, Identifiable {
    case title, heading1, heading2, heading3, body, quote, caption

    var id: String { rawValue }

    var title2: String {
        switch self {
        case .title: "タイトル"
        case .heading1: "見出し 1"
        case .heading2: "見出し 2"
        case .heading3: "見出し 3"
        case .body: "本文"
        case .quote: "引用"
        case .caption: "キャプション"
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .title: 28
        case .heading1: 22
        case .heading2: 18
        case .heading3: 16
        case .body: 13
        case .quote: 13
        case .caption: 11
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .title: .bold
        case .heading1, .heading2, .heading3: .semibold
        default: .regular
        }
    }

    var spacingBefore: CGFloat {
        switch self {
        case .title: 0
        case .heading1: 14
        case .heading2, .heading3: 10
        default: 0
        }
    }

    var spacingAfter: CGFloat {
        switch self {
        case .title: 12
        case .heading1, .heading2, .heading3: 6
        case .caption: 8
        default: 6
        }
    }

    var isItalic: Bool { self == .quote }

    var headIndent: CGFloat { self == .quote ? 22 : 0 }
}

// MARK: - Block-based document structure

/// The kind of content a `DocumentBlock` holds. A document's body is an
/// ordered list of these, rather than one continuous `NSAttributedString` —
/// what lets tables and other structural elements interleave with paragraphs,
/// and what a docx import/export or a change-tracking record can point at
/// (`targetBlockOrder`) without referring to a character offset into an
/// ever-shifting single blob.
enum DocumentBlockKind: String, CaseIterable, Identifiable {
    case paragraph, table, image, pageBreak, equation, tableOfContents

    var id: String { rawValue }
}

enum DocumentListKind: String, CaseIterable, Identifiable {
    case bulleted, numbered

    var id: String { rawValue }
}

@Model
final class DocumentBlock {
    var order: Int = 0
    var kindRawValue: String = DocumentBlockKind.paragraph.rawValue
    /// Archived `NSAttributedString` (via `DocumentBody`) for `.paragraph`,
    /// or a standalone image for `.image`. Unused for `.table` (see
    /// `tableRows`), `.equation` (see `equationSource`), and `.pageBreak`.
    @Attribute(.externalStorage) var bodyData: Data?
    /// The `.equation` kind's source text, in the small LaTeX-like syntax
    /// `MathExpressionParser` reads — plain text rather than an archived
    /// `NSAttributedString` like `bodyData`, since it's a formula source,
    /// not formatted prose.
    var equationSource: String = ""
    /// `nil` for a plain paragraph. When set, this `.paragraph` block is one
    /// item of a list — a real, structured marker (see
    /// `TextDocument.listMarker(for:)`), not the literal "• "/"1. " text the
    /// editor used to type into the paragraph's own content. That's what
    /// lets inserting, deleting or reordering items renumber automatically,
    /// and what a docx round-trip needs: OOXML has its own real numbering
    /// definitions, and a hand-typed prefix string can't map onto them.
    var listKindRawValue: String?
    /// 0 = top level, 1 = nested once, etc. — `changeIndent` raises/lowers
    /// this for a list-item paragraph instead of (or alongside) its text
    /// indent.
    var listLevel: Int = 0
    /// `nil` = never explicitly styled (treated as `.body`). Stored
    /// separately from the visual formatting `apply(style:)` also applies
    /// (font size/weight, paragraph spacing) so "is this a heading, and at
    /// what level" is a real, inspectable fact about the block — not a
    /// guess from font size — which is what a table of contents (see
    /// `TextDocument.tableOfContentsLines`) and a docx round-trip both need.
    var paragraphStyleRawValue: String?
    @Relationship(deleteRule: .cascade, inverse: \DocumentTableRow.block)
    var tableRows: [DocumentTableRow]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentComment.anchorBlock)
    var anchoredComments: [DocumentComment]?
    @Relationship(deleteRule: .cascade, inverse: \DocumentFootnote.anchorBlock)
    var anchoredFootnotes: [DocumentFootnote]?
    /// Default (`.nullify`) delete rule, deliberately unlike
    /// `anchoredComments` above — see `DocumentChangeRecord`'s doc comment on
    /// why its history should outlive the block it was made to.
    @Relationship(inverse: \DocumentChangeRecord.anchorBlock)
    var anchoredChangeRecords: [DocumentChangeRecord]?
    var document: TextDocument?

    init(order: Int, kind: DocumentBlockKind = .paragraph) {
        self.order = order
        self.kindRawValue = kind.rawValue
    }

    var kind: DocumentBlockKind {
        get { DocumentBlockKind(rawValue: kindRawValue) ?? .paragraph }
        set { kindRawValue = newValue.rawValue }
    }

    var listKind: DocumentListKind? {
        get { listKindRawValue.flatMap(DocumentListKind.init(rawValue:)) }
        set { listKindRawValue = newValue?.rawValue }
    }

    var paragraphStyle: DocumentParagraphStyle? {
        get { paragraphStyleRawValue.flatMap(DocumentParagraphStyle.init(rawValue:)) }
        set { paragraphStyleRawValue = newValue?.rawValue }
    }

    var sortedTableRows: [DocumentTableRow] {
        (tableRows ?? []).sorted { $0.order < $1.order }
    }

    var sortedAnchoredComments: [DocumentComment] {
        (anchoredComments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var hasUnresolvedComments: Bool {
        sortedAnchoredComments.contains { !$0.isResolved }
    }

    @discardableResult
    func addComment(author: String, text: String) -> DocumentComment {
        let comment = DocumentComment(author: author, text: text, anchorBlock: self)
        comment.document = document
        anchoredComments = (anchoredComments ?? []) + [comment]
        return comment
    }

    @discardableResult
    func addFootnote(text: String) -> DocumentFootnote {
        let footnote = DocumentFootnote(text: text, anchorBlock: self)
        footnote.document = document
        anchoredFootnotes = (anchoredFootnotes ?? []) + [footnote]
        return footnote
    }

    /// Column count of the first row — every row is kept in sync to the same
    /// width by `addTableColumn`/`removeLastTableColumn`, so this stands in
    /// for "the table's" column count without a separate stored field.
    /// The table's logical width — the widest row once each cell's
    /// `columnSpan` is counted, not just the stored cell count. A merged
    /// cell's covered slot has no cell of its own (see
    /// `mergeCellWithRight`), so a plain `sortedCells.count` would
    /// undercount any row containing a merge.
    var tableColumnCount: Int {
        sortedTableRows.map { row in
            row.sortedCells.reduce(0) { $0 + $1.columnSpan }
        }.max() ?? 0
    }

    /// One row of `tableGridRows`, per visual column: either the cell that
    /// starts there, or a blank placeholder of the same width a cell above
    /// (via `rowSpan`) already covers — see `tableGridRows`.
    enum TableGridSlot {
        case cell(DocumentTableCell)
        case covered(columnSpan: Int)
    }

    /// The table as a real grid, one entry per row per visual column,
    /// accounting for both `columnSpan` and `rowSpan`. A vertical merge (see
    /// `mergeCellWithBelow`) removes the covered cell from its row entirely,
    /// the same way a horizontal merge does — so rendering a row by simply
    /// walking its own `cells` array would silently shift every later cell
    /// left into the gap, misaligning it with the columns above. This
    /// re-inserts a `.covered` placeholder of the right width at that
    /// column instead, so `DocumentTableBlockView` can draw a blank spacer
    /// there and keep every column's edges lined up top to bottom.
    var tableGridRows: [[TableGridSlot]] {
        let rows = sortedTableRows
        let columnCount = tableColumnCount
        guard columnCount > 0 else { return rows.map { _ in [] } }
        // For each column, the row index (exclusive) a `rowSpan` from above
        // still covers through, and the `columnSpan` to size that
        // placeholder — 0/1 means "not currently covered."
        var coveredThroughRow = [Int](repeating: 0, count: columnCount)
        var coveredSpan = [Int](repeating: 1, count: columnCount)

        return rows.enumerated().map { rowIndex, row in
            var slots: [TableGridSlot] = []
            var column = 0
            var remainingCells = row.sortedCells[...]
            while column < columnCount {
                if coveredThroughRow[column] > rowIndex {
                    let span = coveredSpan[column]
                    slots.append(.covered(columnSpan: span))
                    column += span
                    continue
                }
                guard let cell = remainingCells.first else { break }
                remainingCells = remainingCells.dropFirst()
                slots.append(.cell(cell))
                if cell.rowSpan > 1 {
                    for c in column..<min(column + cell.columnSpan, columnCount) {
                        coveredThroughRow[c] = rowIndex + cell.rowSpan
                        coveredSpan[c] = cell.columnSpan
                    }
                }
                column += cell.columnSpan
            }
            return slots
        }
    }

    func addTableRow() {
        let row = DocumentTableRow(order: sortedTableRows.count)
        row.block = self
        for columnIndex in 0..<max(tableColumnCount, 1) {
            let cell = DocumentTableCell(order: columnIndex)
            cell.row = row
            row.cells = (row.cells ?? []) + [cell]
        }
        tableRows = (tableRows ?? []) + [row]
    }

    func addTableColumn() {
        for row in sortedTableRows {
            let cell = DocumentTableCell(order: row.sortedCells.count)
            cell.row = row
            row.cells = (row.cells ?? []) + [cell]
        }
    }

    /// No-ops on a 1-row or 1-column table — a table needs at least one row
    /// and column to still be a table; delete the block itself instead.
    func removeLastTableRow() {
        guard sortedTableRows.count > 1, let last = sortedTableRows.last else { return }
        tableRows?.removeAll { $0 === last }
    }

    func removeLastTableColumn() {
        guard tableColumnCount > 1 else { return }
        for row in sortedTableRows {
            guard let last = row.sortedCells.last else { continue }
            row.cells?.removeAll { $0 === last }
        }
    }

    /// Merges the cell at `cellIndex` in `row` with the one immediately to
    /// its right: the right cell's text is appended into the left cell
    /// (space-separated), the left cell's `columnSpan` absorbs the right
    /// cell's, and the right cell is removed from `row.cells` entirely — the
    /// same "a merged cell's covered slot has no cell of its own" convention
    /// `tableColumnCount` already accounts for. Rendering a row therefore
    /// needs no separate "skip this slot" logic: it only ever draws the
    /// cells actually present, each sized by its own `columnSpan`.
    ///
    /// A no-op if `cellIndex` is the last cell in `row` (nothing to its
    /// right to merge with).
    func mergeCellWithRight(row: DocumentTableRow, cellIndex: Int) {
        let cells = row.sortedCells
        guard cellIndex >= 0, cellIndex + 1 < cells.count else { return }
        let left = cells[cellIndex]
        let right = cells[cellIndex + 1]
        left.text = [left.text, right.text].filter { !$0.isEmpty }.joined(separator: " ")
        left.columnSpan += right.columnSpan
        row.cells?.removeAll { $0 === right }
        for (index, cell) in row.sortedCells.enumerated() { cell.order = index }
    }

    /// The visual column each of `row`'s cells starts at — the sum of every
    /// preceding cell's `columnSpan`, not the cell's raw array index, since a
    /// horizontal merge earlier in the row shrinks the array without
    /// shrinking the columns it covers. `mergeCellWithBelow` needs this to
    /// find the cell in the next row that actually sits under a given cell,
    /// rather than the one that merely shares its array index.
    ///
    /// Keyed by `ObjectIdentifier`, not the cell itself: a `DocumentTableCell`
    /// not yet inserted into a `ModelContext` (as in a bare unit test) has no
    /// reliable `persistentModelID`, so using it directly as a `Hashable` key
    /// would be fragile in exactly the way this app has already been bitten
    /// by once (see `insertTable`'s history).
    private func visualColumnStarts(of row: DocumentTableRow) -> [ObjectIdentifier: Int] {
        var starts: [ObjectIdentifier: Int] = [:]
        var column = 0
        for cell in row.sortedCells {
            starts[ObjectIdentifier(cell)] = column
            column += cell.columnSpan
        }
        return starts
    }

    /// Merges the cell at `cellIndex` in `row` with whichever cell in the
    /// next row starts at the same visual column (see `visualColumnStarts`)
    /// — the lower cell's text is appended into the upper cell, the upper
    /// cell's `rowSpan` absorbs the lower cell's, and the lower cell is
    /// removed from its row entirely, the same "a merged cell's covered slot
    /// has no cell of its own" convention `mergeCellWithRight` uses on the
    /// column axis.
    ///
    /// A no-op if there is no next row, or if no cell in the next row starts
    /// at exactly the same column with exactly the same `columnSpan` —
    /// merging cells of mismatched width would leave the grid with no
    /// consistent column boundaries below the merge, which
    /// `DocumentTableBlockView` (and a future docx round-trip) both assume
    /// never happens.
    func mergeCellWithBelow(row: DocumentTableRow, cellIndex: Int) {
        let rows = sortedTableRows
        guard let rowIndex = rows.firstIndex(where: { $0 === row }), rowIndex + 1 < rows.count else { return }
        let cells = row.sortedCells
        guard cellIndex >= 0, cellIndex < cells.count else { return }
        let upper = cells[cellIndex]
        let upperColumn = visualColumnStarts(of: row)[ObjectIdentifier(upper)] ?? 0

        let belowRow = rows[rowIndex + 1]
        let belowStarts = visualColumnStarts(of: belowRow)
        guard let below = belowRow.sortedCells.first(where: { belowStarts[ObjectIdentifier($0)] == upperColumn }),
              below.columnSpan == upper.columnSpan else { return }

        upper.text = [upper.text, below.text].filter { !$0.isEmpty }.joined(separator: " ")
        upper.rowSpan += below.rowSpan
        belowRow.cells?.removeAll { $0 === below }
        for (index, cell) in belowRow.sortedCells.enumerated() { cell.order = index }
    }

    /// A block with `rows` rows and `columns` columns, ready to append to
    /// `TextDocument.blocks`.
    static func makeTable(order: Int, rows: Int, columns: Int) -> DocumentBlock {
        let block = DocumentBlock(order: order, kind: .table)
        for _ in 0..<max(rows, 1) {
            let row = DocumentTableRow(order: block.sortedTableRows.count)
            row.block = block
            for columnIndex in 0..<max(columns, 1) {
                let cell = DocumentTableCell(order: columnIndex)
                cell.row = row
                row.cells = (row.cells ?? []) + [cell]
            }
            block.tableRows = (block.tableRows ?? []) + [row]
        }
        return block
    }
}

@Model
final class DocumentTableRow {
    var order: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \DocumentTableCell.row)
    var cells: [DocumentTableCell]?
    var block: DocumentBlock?

    init(order: Int) {
        self.order = order
    }

    var sortedCells: [DocumentTableCell] {
        (cells ?? []).sorted { $0.order < $1.order }
    }
}

@Model
final class DocumentTableCell {
    var order: Int = 0
    /// How many columns/rows this cell spans, for merged cells — see
    /// `DocumentBlock.mergeCellWithRight`/`mergeCellWithBelow`. Every cell
    /// starts 1x1; a span greater than 1 means the cells it absorbed no
    /// longer exist in `row.cells` at all.
    var columnSpan: Int = 1
    var rowSpan: Int = 1
    @Attribute(.externalStorage) var bodyData: Data?
    var row: DocumentTableRow?

    init(order: Int) {
        self.order = order
    }

    /// Plain-text convenience over `bodyData`, for the cell text field. Goes
    /// through the same `DocumentBody` archiving as every other block, so a
    /// cell can later carry real character-level formatting without a schema
    /// change — today's editor just never writes more than plain text to it.
    var text: String {
        get { DocumentBody.decode(bodyData).string }
        set { bodyData = DocumentBody.encode(NSAttributedString(string: newValue, attributes: DocumentBody.defaultAttributes())) }
    }
}

enum DocumentHeaderFooterKind: String, CaseIterable, Identifiable {
    case header, footer

    var id: String { rawValue }
}

@Model
final class DocumentHeaderFooter {
    var kindRawValue: String = DocumentHeaderFooterKind.header.rawValue
    @Attribute(.externalStorage) var bodyData: Data?
    /// Appends the page number when rendering to PDF — see
    /// `ExportService.pdfData(from: TextDocument)`.
    var showsPageNumber: Bool = false
    var document: TextDocument?

    init(kind: DocumentHeaderFooterKind) {
        self.kindRawValue = kind.rawValue
    }

    var kind: DocumentHeaderFooterKind {
        get { DocumentHeaderFooterKind(rawValue: kindRawValue) ?? .header }
        set { kindRawValue = newValue.rawValue }
    }

    /// Plain-text convenience over `bodyData`, matching
    /// `DocumentTableCell.text` — same reasoning: goes through the same
    /// `DocumentBody` archiving as every other block, so it can later carry
    /// real formatting without a schema change.
    var text: String {
        get { DocumentBody.decode(bodyData).string }
        set { bodyData = DocumentBody.encode(NSAttributedString(string: newValue, attributes: DocumentBody.defaultAttributes())) }
    }
}

/// Anchored to a block (paragraph-level, not a character range within it —
/// enough precision for a review comment thread without tracking offsets
/// into a paragraph that keeps being edited).
///
/// The anchor is a relationship to the `DocumentBlock` itself, not a
/// snapshot of its `order` — `order` gets renumbered on essentially every
/// structural edit (inserting a table, `replaceParagraphRun`, …), so a
/// stored order number would silently start pointing at the wrong block
/// the moment anything before it shifted.
@Model
final class DocumentComment {
    var author: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var isResolved: Bool = false
    var anchorBlock: DocumentBlock?
    var document: TextDocument?

    init(author: String, text: String, anchorBlock: DocumentBlock?) {
        self.author = author
        self.text = text
        self.anchorBlock = anchorBlock
        self.createdAt = .now
    }
}

/// A footnote attached to a paragraph (block-level, like `DocumentComment` —
/// not a specific character position within it). Its number isn't stored:
/// like a list marker, it's computed from document order (see
/// `TextDocument.footnoteNumber(for:)`), so inserting or deleting a
/// footnote elsewhere renumbers the rest automatically.
///
/// Rendered as a small reference badge next to its paragraph (not inline at
/// an exact character offset within the text — the same reduced-precision
/// tradeoff `DocumentComment` makes) and listed together, in order, at the
/// end of the document — an endnote-style list rather than true per-page
/// footnote placement, since the live editor here isn't paginated the way a
/// PDF page is.
@Model
final class DocumentFootnote {
    var text: String = ""
    var createdAt: Date = Date.now
    var anchorBlock: DocumentBlock?
    var document: TextDocument?

    init(text: String, anchorBlock: DocumentBlock?) {
        self.text = text
        self.anchorBlock = anchorBlock
        self.createdAt = .now
    }
}

enum DocumentChangeKind: String, CaseIterable, Identifiable {
    case insert, edit

    var id: String { rawValue }
}

enum DocumentChangeStatus: String, CaseIterable, Identifiable {
    case pending, accepted, rejected

    var id: String { rawValue }
}

/// A record of one edit to a block's text, in the review model from the
/// design's change-tracking step. Unlike real-time collaborative track
/// changes (which need the multi-device sync layer this app doesn't have
/// yet — see the design notes), edits apply immediately here; what this adds
/// is attribution and a reviewable, revertible log of them, one record per
/// commit of a block's text (not one per keystroke).
///
/// `previousText`/`newText` are stored directly (not just a reference to the
/// block's current content) for two reasons: it's what the review UI diffs
/// against, and it's what `rejecting` a change restores — both need to work
/// even if `anchorBlock`'s own content has moved on since.
@Model
final class DocumentChangeRecord {
    var author: String = ""
    var createdAt: Date = Date.now
    var kindRawValue: String = DocumentChangeKind.edit.rawValue
    var statusRawValue: String = DocumentChangeStatus.pending.rawValue
    var previousText: String = ""
    var newText: String = ""
    /// Not cascade-deleted from the block's side (unlike `DocumentComment`):
    /// a change record should outlive the block it was made to, so its
    /// history remains reviewable even after that content is gone. `nil`
    /// simply means "the block this was made to no longer exists."
    var anchorBlock: DocumentBlock?
    var document: TextDocument?
    /// The id `DocumentCollabService.propose`/a remote pending change was
    /// assigned in the document's collaboration room, once this record has
    /// been synced with the server — nil for a purely local record that
    /// hasn't been proposed yet (or a document with no room at all). Set
    /// either right after this device proposes its own edit, or when a
    /// remote participant's pending change is pulled down and mirrored here
    /// so it shows up in the same change-history UI.
    var collabChangeID: Int?

    init(author: String, kind: DocumentChangeKind, previousText: String, newText: String, anchorBlock: DocumentBlock?) {
        self.author = author
        self.kindRawValue = kind.rawValue
        self.previousText = previousText
        self.newText = newText
        self.anchorBlock = anchorBlock
        self.createdAt = .now
    }

    var kind: DocumentChangeKind {
        get { DocumentChangeKind(rawValue: kindRawValue) ?? .edit }
        set { kindRawValue = newValue.rawValue }
    }

    var status: DocumentChangeStatus {
        get { DocumentChangeStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    /// Restores `anchorBlock`'s text to `previousText` and marks this
    /// `.rejected`. A no-op (still marks `.rejected`) if `anchorBlock` no
    /// longer exists — there's nothing left to revert.
    func reject() {
        if let anchorBlock {
            anchorBlock.bodyData = DocumentBody.encode(
                NSAttributedString(string: previousText, attributes: DocumentBody.defaultAttributes())
            )
        }
        status = .rejected
    }
}

/// Converts a legacy `TextDocument.bodyData` (one continuous
/// `NSAttributedString`) into `blocks`, one block per paragraph, the first
/// time such a document is touched after this app version ships.
///
/// Idempotent, and safe to call on every load: a document that's already
/// migrated (or was created directly in the block model) returns
/// immediately. `bodyData` is deliberately never cleared here — even after
/// migration succeeds, it stays as the fallback this document's editor can
/// fall back to reading if `blocks` ever turns out to be wrong, and migration
/// runs per-document, so one document's conversion failing can't affect any
/// other document.
enum DocumentBlockMigration {
    static func migrateIfNeeded(_ document: TextDocument) {
        guard !document.isMigratedToBlocks else { return }
        guard (document.blocks ?? []).isEmpty else {
            document.isMigratedToBlocks = true
            return
        }
        replaceParagraphBlocks(in: document, with: DocumentBody.decode(document.bodyData))
        document.isMigratedToBlocks = true
    }

    /// Rewrites every `.paragraph` block in `document` to match `text`, one
    /// block per paragraph — the same conversion `migrateIfNeeded` uses from
    /// `bodyData`, but callable directly from live edited text so the editor
    /// can keep `blocks` in step with what it's actually saving. Non-paragraph
    /// blocks (tables, images, …) are left untouched.
    ///
    /// Called only at natural save checkpoints (leaving the editor, exporting
    /// — see `TextDocumentView.flushSave`), not on every keystroke: rebuilding
    /// every paragraph block on each debounced autosave would mean deleting
    /// and reinserting several SwiftData objects (and, with CloudKit syncing,
    /// pushing that churn to the server) several times a minute while someone
    /// is just typing.
    static func replaceParagraphBlocks(in document: TextDocument, with text: NSAttributedString) {
        let otherBlocks = document.sortedBlocks.filter { $0.kind != .paragraph }
        let paragraphs = text.splitByParagraphs()
        var newBlocks: [DocumentBlock] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let block = DocumentBlock(order: index, kind: .paragraph)
            block.bodyData = DocumentBody.encode(paragraph)
            block.document = document
            newBlocks.append(block)
        }
        document.blocks = newBlocks + otherBlocks
    }
}

extension NSAttributedString {
    /// Splits on paragraph breaks, keeping each paragraph's own attributes —
    /// mirrors one paragraph per `DocumentBlock`.
    func splitByParagraphs() -> [NSAttributedString] {
        guard length > 0 else { return [NSAttributedString(string: "")] }
        var result: [NSAttributedString] = []
        let fullRange = NSRange(location: 0, length: length)
        (string as NSString).enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, range, _, _ in
            result.append(self.attributedSubstring(from: range))
        }
        return result.isEmpty ? [self] : result
    }
}

enum DocumentBlockText {
    /// One `DocumentBlock` (kind `.paragraph`) per paragraph in `text`, in
    /// order, not yet attached to any document.
    static func makeParagraphBlocks(from text: NSAttributedString) -> [DocumentBlock] {
        text.splitByParagraphs().map { paragraph in
            let block = DocumentBlock(order: 0, kind: .paragraph)
            block.bodyData = DocumentBody.encode(paragraph)
            return block
        }
    }

    /// The inverse of `makeParagraphBlocks` — joins a run of `.paragraph`
    /// blocks back into one flowing string, with `\n` between them. Used
    /// both to seed a text segment's editor and to reconstruct the whole
    /// document's `bodyData` from every paragraph block in order (see
    /// `TextDocumentView.persist`).
    ///
    /// A joining `\n`'s attributes come from the *end* of the block before
    /// it, not the block after — matching how a paragraph's own trailing
    /// newline normally carries that paragraph's own style in TextKit
    /// (`NSString.paragraphRange(for:)` includes it), which is what these
    /// blocks were split from in the first place.
    static func joinedText(of blocks: [DocumentBlock]) -> NSAttributedString {
        let joined = NSMutableAttributedString()
        var previous: NSAttributedString?
        for block in blocks {
            let piece = DocumentBody.decode(block.bodyData)
            if let previous {
                let trailing = previous.length > 0
                    ? previous.attributes(at: previous.length - 1, effectiveRange: nil)
                    : DocumentBody.defaultAttributes()
                joined.append(NSAttributedString(string: "\n", attributes: trailing))
            }
            joined.append(piece)
            previous = piece
        }
        return joined
    }

    /// Carries `listKind`/`listLevel`/`paragraphStyle` from `oldRun` onto
    /// `newRun` after a split/recommit — every commit discards `oldRun` and
    /// builds fresh blocks from the edited text, so without this, checking
    /// "make this a bulleted list" or "make this a heading" would be undone
    /// the moment the paragraph next autosaves. Index-for-index where both
    /// runs have a paragraph at that position; a paragraph added past the
    /// end of `oldRun` (pressing return inside a list item, or at the end of
    /// a heading) inherits the state of the new paragraph immediately
    /// before it — continuing the list, but also meaning a heading you just
    /// typed a return after doesn't hand its heading style to the next line;
    /// see `TextDocumentView.apply(style:)`, which only tags the paragraph
    /// actually being styled, never the one after it.
    static func carryOverListMetadata(from oldRun: [DocumentBlock], to newRun: [DocumentBlock]) {
        for (index, block) in newRun.enumerated() {
            if index < oldRun.count {
                block.listKindRawValue = oldRun[index].listKindRawValue
                block.listLevel = oldRun[index].listLevel
                block.paragraphStyleRawValue = oldRun[index].paragraphStyleRawValue
            } else if index > 0 {
                block.listKindRawValue = newRun[index - 1].listKindRawValue
                block.listLevel = newRun[index - 1].listLevel
                // Deliberately not carrying `paragraphStyleRawValue` here —
                // pressing return after a heading should drop back to body
                // style for the new line, the same as every word processor.
            }
        }
    }
}

/// One editable run in the document, in reading order — what the editor
/// actually renders as a separate view. A `.text` segment is one or more
/// consecutive `.paragraph` blocks sharing a single flowing text view; a
/// `.table` segment is exactly one table block. Tables can't be embedded
/// inside a flowing run of text on iOS (see `TextDocumentView`'s design
/// notes), so splitting the document into segments like this is what lets a
/// table sit between two paragraphs instead of only ever at the end.
/// One occurrence of a search query, in a specific block's own text (not a
/// document-wide character offset — `TextDocumentView.navigateToMatch`
/// resolves that from the block's position within its segment when it needs
/// to show it).
struct DocumentSearchMatch {
    let block: DocumentBlock
    let range: NSRange
}

struct DocumentSegment: Identifiable {
    enum Kind { case text, table, equation, tableOfContents }

    // `ObjectIdentifier` of the segment's first block, not
    // `PersistentIdentifier` — a block that hasn't yet been inserted into a
    // `ModelContext` (true for every block created in the same editing
    // session before the next save) doesn't reliably have a distinct
    // persistent ID yet, which would break both SwiftUI's `ForEach` identity
    // and the `===`-based lookups `replaceParagraphRun`/`insertTable` use.
    let id: ObjectIdentifier
    let kind: Kind
    let blocks: [DocumentBlock]

    /// Where a comment on this segment attaches — its first block, whether
    /// that's the one table block (`.table`) or the first of several
    /// paragraphs (`.text`). A multi-paragraph text segment doesn't have a
    /// per-paragraph UI target today (all its paragraphs render inside one
    /// `RichTextEditor` while the segment is active), so this is the whole
    /// segment's comment anchor, not one specific paragraph within it.
    var commentAnchor: DocumentBlock? { blocks.first }
}

extension TextDocument {
    var segments: [DocumentSegment] {
        var result: [DocumentSegment] = []
        var run: [DocumentBlock] = []
        func flushRun() {
            guard let first = run.first else { return }
            result.append(DocumentSegment(id: ObjectIdentifier(first), kind: .text, blocks: run))
            run = []
        }
        for block in sortedBlocks {
            switch block.kind {
            case .table:
                flushRun()
                result.append(DocumentSegment(id: ObjectIdentifier(block), kind: .table, blocks: [block]))
            case .equation:
                flushRun()
                result.append(DocumentSegment(id: ObjectIdentifier(block), kind: .equation, blocks: [block]))
            case .tableOfContents:
                flushRun()
                result.append(DocumentSegment(id: ObjectIdentifier(block), kind: .tableOfContents, blocks: [block]))
            default:
                run.append(block)
            }
        }
        flushRun()
        return result
    }

    /// The marker text for `block` if it's a list item (`nil` otherwise) —
    /// its position among the *consecutive* blocks immediately before it
    /// that share the same list kind and level, so inserting, deleting or
    /// reordering list items renumbers automatically rather than needing
    /// the stored text to be rewritten. A run breaks (numbering restarts)
    /// at any block that isn't a list item at that same kind/level,
    /// One line per heading currently in the document (`title`/`heading1`/
    /// `heading2`/`heading3` paragraphs, in document order), with an
    /// indentation level for a nested display — the source `.tableOfContents`
    /// blocks are built from (see `TextDocumentView.insertTableOfContents`
    /// and `refreshTableOfContents`). Recomputed on demand, not cached, so
    /// it's never stale — the cost is scanning every block once, cheap at
    /// the sizes these documents actually reach.
    var tableOfContentsLines: [(level: Int, text: String)] {
        sortedBlocks.compactMap { block -> (Int, String)? in
            guard block.kind == .paragraph else { return nil }
            let level: Int
            switch block.paragraphStyle {
            case .title: level = 0
            case .heading1: level = 1
            case .heading2: level = 2
            case .heading3: level = 3
            default: return nil
            }
            let text = DocumentBody.decode(block.bodyData).string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (level, text)
        }
    }

    /// including a table or equation segment in between — the same
    /// "separate list instance" behavior Word defaults to.
    func listMarker(for block: DocumentBlock) -> String? {
        guard let kind = block.listKind else { return nil }
        let all = sortedBlocks
        guard let blockIndex = all.firstIndex(where: { $0 === block }) else { return nil }

        var position = 1
        var i = blockIndex - 1
        while i >= 0, all[i].listKind == kind, all[i].listLevel == block.listLevel {
            position += 1
            i -= 1
        }

        switch kind {
        case .bulleted:
            let glyphs = ["•", "◦", "▪"]
            return glyphs[min(block.listLevel, glyphs.count - 1)]
        case .numbered:
            switch block.listLevel {
            case 0: return "\(position)."
            case 1: return "\(Self.lowercaseLetter(for: position))."
            default: return "\(Self.lowercaseRoman(for: position))."
            }
        }
    }

    /// 1 → "a", 2 → "b", …, 27 → "aa" — the level-2 numbered-list style.
    private static func lowercaseLetter(for position: Int) -> String {
        var n = position
        var letters = ""
        while n > 0 {
            n -= 1
            let index = n % 26
            letters = String(UnicodeScalar(UInt8(97 + index))) + letters
            n /= 26
        }
        return letters
    }

    /// 1 → "i", 2 → "ii", 4 → "iv", … — the level-3+ numbered-list style.
    private static func lowercaseRoman(for position: Int) -> String {
        let values: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = position
        var result = ""
        for (value, symbol) in values {
            while remaining >= value {
                result += symbol
                remaining -= value
            }
        }
        return result
    }

    /// Replaces `oldRun` — a contiguous run of `.paragraph` blocks belonging
    /// to this document, i.e. a `.text` segment's `blocks` — with fresh
    /// blocks built from `text`, at the same position among `blocks`.
    ///
    /// Unlike `DocumentBlockMigration.replaceParagraphBlocks` (which rewrites
    /// *every* paragraph block from the document's one-time-migrated flat
    /// text and pushes every non-paragraph block to the end), this only
    /// touches the one run given to it — a table or another text segment
    /// before or after it keeps its position.
    @discardableResult
    func replaceParagraphRun(_ oldRun: [DocumentBlock], with text: NSAttributedString) -> [DocumentBlock] {
        var all = sortedBlocks
        // Reference identity, not `persistentModelID` equality — a block
        // that has never been inserted into a `ModelContext` (true for every
        // block created in the same editing session before the next save)
        // doesn't reliably have a distinct persistent ID yet.
        guard let first = oldRun.first,
              let startIndex = all.firstIndex(where: { $0 === first }) else {
            return oldRun
        }
        let endIndex = min(startIndex + oldRun.count - 1, all.count - 1)
        let newRun = DocumentBlockText.makeParagraphBlocks(from: text)
        for block in newRun { block.document = self }
        DocumentBlockText.carryOverListMetadata(from: oldRun, to: newRun)
        all.replaceSubrange(startIndex...endIndex, with: newRun)
        for (index, block) in all.enumerated() { block.order = index }
        blocks = all
        return newRun
    }

    /// A blank paragraph block at the very start or end of the document —
    /// what pulling past the top/bottom edge of the page inserts (design
    /// parity with the "pull to add a page" gesture slides/notebooks
    /// already have; a flowing document has no fixed "pages" to add, so
    /// this gives the same gesture "more room to write" instead).
    @discardableResult
    func insertBlankParagraph(atStart: Bool) -> DocumentBlock {
        // `sortedBlocks` must be captured *before* `block.document = self`
        // below — that assignment auto-syncs this relationship's inverse
        // array (`blocks`), so reading it afterward would already include
        // `block` once, and the manual insert further down would then add
        // a second, duplicate reference to the same object. The final
        // `blocks = all` assignment overwrites the relationship wholesale,
        // superseding whatever the auto-sync did in between — the same
        // reason `replaceParagraphRun` above captures its own snapshot
        // first too.
        var all = sortedBlocks
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.document = self
        if atStart {
            all.insert(block, at: 0)
        } else {
            all.append(block)
        }
        for (index, b) in all.enumerated() { b.order = index }
        blocks = all
        return block
    }

    /// Splits `segment` (a `.text` segment) at `cursorOffset` within
    /// `liveText` — the segment's current, possibly not-yet-saved content —
    /// and inserts a `rows`x`columns` table between the two halves. Returns
    /// the new table block and the segment for what comes after it, which is
    /// never empty of blocks (splitting always yields at least one, possibly
    /// empty, paragraph) — so there's always somewhere to keep typing right
    /// after the table, the way there would be in a word processor.
    @discardableResult
    func insertTable(rows: Int, columns: Int, splitting segment: DocumentSegment, liveText: NSAttributedString, at cursorOffset: Int) -> (table: DocumentBlock, after: DocumentSegment) {
        let table = DocumentBlock.makeTable(order: 0, rows: rows, columns: columns)
        let after = insertBlock(table, splitting: segment, liveText: liveText, at: cursorOffset)
        return (table, after)
    }

    /// Same split-and-splice as `insertTable`, for a `.equation` block
    /// instead of a table.
    func insertEquation(source: String, splitting segment: DocumentSegment, liveText: NSAttributedString, at cursorOffset: Int) -> (equation: DocumentBlock, after: DocumentSegment) {
        let equation = DocumentBlock(order: 0, kind: .equation)
        equation.equationSource = source
        let after = insertBlock(equation, splitting: segment, liveText: liveText, at: cursorOffset)
        return (equation, after)
    }

    /// Same split-and-splice as `insertTable`/`insertEquation`, for a table
    /// of contents. Carries no content of its own — `tableOfContentsLines`
    /// is recomputed from the document's current headings every time it's
    /// rendered, so the block just marks *where* the TOC sits.
    func insertTableOfContents(splitting segment: DocumentSegment, liveText: NSAttributedString, at cursorOffset: Int) -> (toc: DocumentBlock, after: DocumentSegment) {
        let toc = DocumentBlock(order: 0, kind: .tableOfContents)
        let after = insertBlock(toc, splitting: segment, liveText: liveText, at: cursorOffset)
        return (toc, after)
    }

    /// Every case-insensitive occurrence of `query` across every
    /// `.paragraph` block's text, in document order. Table cell text,
    /// equation source, and header/footer text aren't searched — search
    /// only covers the flowing body text, the same scope `bodyData`/
    /// `plainText` already treat as "the document's text" elsewhere.
    func searchMatches(for query: String) -> [DocumentSearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DocumentSearchMatch] = []
        for block in sortedBlocks where block.kind == .paragraph {
            let text = DocumentBody.decode(block.bodyData).string as NSString
            var searchStart = 0
            while searchStart < text.length {
                let searchRange = NSRange(location: searchStart, length: text.length - searchStart)
                let found = text.range(of: query, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                matches.append(DocumentSearchMatch(block: block, range: found))
                searchStart = found.location + max(found.length, 1)
            }
        }
        return matches
    }

    /// Replaces one match's text in its own block directly (not through the
    /// live editor) — search/replace operates on every block in the
    /// document, most of which aren't the one currently loaded into
    /// `TextDocumentView.attributedText`, so there's no single live text
    /// buffer to route every replacement through the way ordinary typing
    /// does. `TextDocumentView.replaceCurrentMatch` reloads the active
    /// segment's displayed text afterward if this touched one of its blocks.
    func replaceMatch(_ match: DocumentSearchMatch, with replacement: String) {
        let text = NSMutableAttributedString(attributedString: DocumentBody.decode(match.block.bodyData))
        guard match.range.location + match.range.length <= text.length else { return }
        let attributes = text.attributes(at: match.range.location, effectiveRange: nil)
        text.replaceCharacters(in: match.range, with: NSAttributedString(string: replacement, attributes: attributes))
        match.block.bodyData = DocumentBody.encode(text)
    }

    /// Replaces every given match. Matches sharing the same block are
    /// applied last-range-first, so replacing one doesn't shift the stored
    /// range of another match still pending in that same block.
    func replaceAllMatches(_ matches: [DocumentSearchMatch], with replacement: String) {
        let byBlock = Dictionary(grouping: matches, by: { ObjectIdentifier($0.block) })
        for (_, blockMatches) in byBlock {
            guard let block = blockMatches.first?.block else { continue }
            let text = NSMutableAttributedString(attributedString: DocumentBody.decode(block.bodyData))
            for match in blockMatches.sorted(by: { $0.range.location > $1.range.location }) {
                guard match.range.location + match.range.length <= text.length else { continue }
                let attributes = text.attributes(at: match.range.location, effectiveRange: nil)
                text.replaceCharacters(in: match.range, with: NSAttributedString(string: replacement, attributes: attributes))
            }
            block.bodyData = DocumentBody.encode(text)
        }
    }

    /// Splits `segment` (a `.text` segment) at `cursorOffset` within
    /// `liveText` — the segment's current, possibly not-yet-saved content —
    /// and inserts `newBlock` between the two halves. Returns the segment
    /// for what comes after it, which is never empty of blocks (splitting
    /// always yields at least one, possibly empty, paragraph) — so there's
    /// always somewhere to keep typing right after `newBlock`, the way there
    /// would be in a word processor.
    private func insertBlock(_ newBlock: DocumentBlock, splitting segment: DocumentSegment, liveText: NSAttributedString, at cursorOffset: Int) -> DocumentSegment {
        // Captured before any new block's `.document` is set below — setting
        // that inverse relationship can eagerly append the block into
        // `self.blocks` on its own (SwiftData maintains inverses both ways),
        // and a snapshot taken afterward would then double up on it once
        // this function also splices it in explicitly.
        var all = sortedBlocks

        let clampedOffset = max(0, min(cursorOffset, liveText.length))
        let before = liveText.attributedSubstring(from: NSRange(location: 0, length: clampedOffset))
        let after = liveText.attributedSubstring(from: NSRange(location: clampedOffset, length: liveText.length - clampedOffset))

        let beforeRun = DocumentBlockText.makeParagraphBlocks(from: before)
        let afterRun = DocumentBlockText.makeParagraphBlocks(from: after)
        DocumentBlockText.carryOverListMetadata(from: segment.blocks, to: beforeRun + afterRun)
        for block in beforeRun + afterRun { block.document = self }
        newBlock.document = self

        let replacement = beforeRun + [newBlock] + afterRun
        // Reference identity — see `replaceParagraphRun`'s comment on why
        // `persistentModelID` isn't safe to compare here.
        if let first = segment.blocks.first,
           let startIndex = all.firstIndex(where: { $0 === first }) {
            let endIndex = min(startIndex + segment.blocks.count - 1, all.count - 1)
            all.replaceSubrange(startIndex...endIndex, with: replacement)
        } else {
            all.append(contentsOf: replacement)
        }
        for (index, block) in all.enumerated() { block.order = index }
        blocks = all

        return DocumentSegment(id: ObjectIdentifier(afterRun[0]), kind: .text, blocks: afterRun)
    }
}

// MARK: - PowerPoint-style slide deck

/// A slide deck.
///
/// Slides are built from *layout placeholders* rather than a free-form
/// canvas, which is how PowerPoint itself is structured: a layout decides
/// which boxes exist and where, and the content fills them. That keeps a deck
/// visually consistent, makes changing a slide's layout a one-tap operation,
/// and means a theme can restyle every slide at once.
@Model
final class SlideDeck {
    var title: String = "無題のスライド"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var folderName: String = ""
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var trashedAt: Date?
    var themeRawValue: String = SlideTheme.classic.rawValue
    var aspectRawValue: String = SlideAspect.widescreen.rawValue
    /// Deck-wide typography, the way a PowerPoint theme carries a font pair
    /// rather than each box choosing for itself.
    var fontFamilyRawValue: String = "system"
    /// Multiplies every placeholder's size, so one control scales a whole
    /// deck instead of retyping sizes per slide.
    var textScale: Double = 1.0
    var titleIsBold: Bool = true
    var bodyIsItalic: Bool = false
    /// Whether `slides`' legacy flat fields (`titleText`/`bodyText`/
    /// `secondaryText`/`imageData`/`legacyLayoutRawValue`) have been
    /// converted into `master`/`SlideElement`s yet, via
    /// `SlideBlockMigration.migrateIfNeeded` — mirrors
    /// `TextDocument.isMigratedToBlocks` exactly, including leaving the old
    /// fields populated (not cleared) even after a successful migration, as
    /// a fallback.
    var isMigratedToElements: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Slide.deck)
    var slides: [Slide]?
    @Relationship(deleteRule: .cascade, inverse: \SlideMaster.deck)
    var master: SlideMaster?

    init(title: String = "無題のスライド") {
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Appends to the CloudKit-required optional relationship, creating the
    /// backing array on first use.
    func addSlide(_ slide: Slide) {
        if slides == nil { slides = [] }
        slides?.append(slide)
    }

    var theme: SlideTheme {
        get { SlideTheme(rawValue: themeRawValue) ?? .classic }
        set { themeRawValue = newValue.rawValue }
    }

    var aspect: SlideAspect {
        get { SlideAspect(rawValue: aspectRawValue) ?? .widescreen }
        set { aspectRawValue = newValue.rawValue }
    }

    var fontFamily: DocumentFontFamily {
        get { DocumentFontFamily(rawValue: fontFamilyRawValue) ?? .system }
        set { fontFamilyRawValue = newValue.rawValue }
    }

    var sortedSlides: [Slide] {
        (slides ?? []).sorted { $0.order < $1.order }
    }

    func renumberSlides() {
        for (index, slide) in sortedSlides.enumerated() { slide.order = index }
    }

    /// Inserts `slide` immediately before/after `reference` (shifting every
    /// slide at or past that position back by one first) and renumbers —
    /// the model-side half of "pull past the canvas edge to add a slide."
    /// The caller still owns telling `modelContext` about the new slide and
    /// running migration on it, the same as `addSlide` itself.
    func insertSlide(_ slide: Slide, adjacentTo reference: Slide, before: Bool) {
        let order = before ? reference.order : reference.order + 1
        slide.order = order
        for later in sortedSlides where later.order >= order { later.order += 1 }
        addSlide(slide)
        renumberSlides()
    }
}

@Model
final class Slide {
    var order: Int = 0
    /// The pre-canvas fixed-layout choice — kept only as migration input
    /// for `SlideBlockMigration`; the live editor reads `layout` instead.
    var legacyLayoutRawValue: String = SlideLayout.titleAndBody.rawValue
    /// Legacy flat content fields — superseded by `elements`, kept
    /// unconverted as a migration fallback (see
    /// `SlideDeck.isMigratedToElements`).
    var titleText: String = ""
    /// One bullet per line, the way a content placeholder behaves.
    var bodyText: String = ""
    /// The second column of a two-content layout.
    var secondaryText: String = ""
    @Attribute(.externalStorage) var imageData: Data?
    /// Speaker notes — shown to the presenter, never on the slide. Not part
    /// of the legacy/new split above: this field's meaning hasn't changed,
    /// so migration carries it over as-is.
    var notes: String = ""
    /// How this slide transitions *in* during presentation playback
    /// (design step 6) — attached to the incoming slide, matching
    /// PowerPoint's own convention of a transition belonging to the slide
    /// it brings on screen, not the one it leaves.
    var transitionRawValue: String = SlideTransitionKind.none.rawValue
    var deck: SlideDeck?
    var layout: SlideLayoutTemplate?
    @Relationship(deleteRule: .cascade, inverse: \SlideElement.slide)
    var elements: [SlideElement]?

    init(order: Int, layout: SlideLayout = .titleAndBody) {
        self.order = order
        self.legacyLayoutRawValue = layout.rawValue
    }

    var legacyLayout: SlideLayout {
        get { SlideLayout(rawValue: legacyLayoutRawValue) ?? .titleAndBody }
        set { legacyLayoutRawValue = newValue.rawValue }
    }

    var transition: SlideTransitionKind {
        get { SlideTransitionKind(rawValue: transitionRawValue) ?? .none }
        set { transitionRawValue = newValue.rawValue }
    }

    /// Bullets, with blank lines dropped so a trailing newline doesn't render
    /// as an empty bullet.
    var bullets: [String] {
        bodyText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var secondaryBullets: [String] {
        secondaryText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var sortedElements: [SlideElement] {
        (elements ?? []).sorted { $0.layerIndex < $1.layerIndex }
    }

    /// This slide's animated elements (`animationKind != .none`), grouped
    /// into click-driven reveal steps for presentation playback (design
    /// step 6): each `.onClick` element starts a new step; a
    /// `.withPrevious`/`.afterPrevious` element joins whichever step
    /// precedes it in `animationOrder` — or step 0, revealed immediately
    /// when the slide appears, if nothing precedes it yet.
    /// `SlidePresentationView` walks one step per tap. This is a
    /// deliberately simplified sequencing model, not a full animation-pane
    /// timing engine — `.withPrevious` and `.afterPrevious` both just mean
    /// "no extra click needed," without modeling the exact delay between
    /// them that real PowerPoint offers.
    var animationSteps: [[SlideElement]] {
        let animated = sortedElements
            .filter { $0.animationKind != .none }
            .sorted { $0.animationOrder < $1.animationOrder }
        var steps: [[SlideElement]] = [[]]
        for element in animated {
            if element.animationTrigger == .onClick {
                steps.append([element])
            } else {
                steps[steps.count - 1].append(element)
            }
        }
        return steps
    }

    /// The `animationOrder` a *newly*-animated element on this slide should
    /// get — one past whatever's currently highest among elements that
    /// already have an animation, so a fresh animation always plays last by
    /// default (matching PowerPoint's own "new animations append to the
    /// end of the sequence" behaviour), without needing a manual reorder
    /// UI. A slide with no animated elements yet starts at 0.
    func nextAnimationOrder() -> Int {
        let currentMax = sortedElements
            .filter { $0.animationKind != .none }
            .map(\.animationOrder)
            .max() ?? -1
        return currentMax + 1
    }

    @discardableResult
    func addElement(_ element: SlideElement) -> SlideElement {
        element.slide = self
        elements = (elements ?? []) + [element]
        return element
    }

    func element(for role: SlidePlaceholderRole) -> SlideElement? {
        sortedElements.first { $0.sourcePlaceholder?.role == role }
    }

    /// Wraps `members` (2 or more, all already on this slide) into a new
    /// `.group` element sized to their combined bounding box — design step
    /// 4's grouping command. Each member is detached from any placeholder
    /// it was still inheriting from first, since a grouped element's
    /// position has to be a real, storable value for `SlideElement.moveGroup`
    /// to add deltas to. Returns `nil` (no-op) for fewer than 2 members.
    @discardableResult
    func group(_ members: [SlideElement]) -> SlideElement? {
        guard members.count >= 2 else { return nil }
        for member in members { member.bakeInGeometryIfNeeded() }
        let minX = members.map { $0.centerX - $0.width / 2 }.min() ?? 0
        let maxX = members.map { $0.centerX + $0.width / 2 }.max() ?? 1
        let minY = members.map { $0.centerY - $0.height / 2 }.min() ?? 0
        let maxY = members.map { $0.centerY + $0.height / 2 }.max() ?? 1
        let newGroup = SlideElement(kind: .group, layerIndex: (members.map(\.layerIndex).max() ?? 0) + 1)
        newGroup.overrideCenterX = (minX + maxX) / 2
        newGroup.overrideCenterY = (minY + maxY) / 2
        newGroup.overrideWidth = max(0.02, maxX - minX)
        newGroup.overrideHeight = max(0.02, maxY - minY)
        addElement(newGroup)
        for member in members { member.parentGroup = newGroup }
        return newGroup
    }

    /// Detaches every member of `groupElement` (keeping each one's current
    /// absolute position — nothing visibly moves) and removes the
    /// now-empty group element itself.
    func ungroup(_ groupElement: SlideElement) {
        for member in groupElement.groupMembers ?? [] { member.parentGroup = nil }
        elements?.removeAll { $0 === groupElement }
    }

    /// Switches to `newLayout`, matching existing elements to the new
    /// layout's placeholders by role so content survives the switch (design
    /// step 5's "still a one-tap operation" requirement):
    /// - an element whose placeholder's role also exists in `newLayout`
    ///   re-links to that role's new placeholder — kept overrides stay as
    ///   overrides, still-inheriting elements simply pick up the new
    ///   placeholder's position instead.
    /// - a role present in `newLayout` with nothing already filling it gets
    ///   a freshly created, fully-inheriting element.
    /// - an element whose role doesn't exist in `newLayout` is detached
    ///   (`sourcePlaceholder = nil`) rather than deleted — it becomes a free
    ///   element, keeping whatever it last showed.
    func changeLayout(to newLayout: SlideLayoutTemplate) {
        for element in sortedElements {
            guard let role = element.sourcePlaceholder?.role else { continue }
            if let matchingPlaceholder = newLayout.placeholder(for: role) {
                element.sourcePlaceholder = matchingPlaceholder
            } else {
                element.bakeInGeometryIfNeeded()
                element.sourcePlaceholder = nil
            }
        }
        for placeholder in newLayout.sortedPlaceholders where element(for: placeholder.role) == nil {
            let fresh = SlideElement(kind: placeholder.kind, layerIndex: Double(sortedElements.count))
            fresh.sourcePlaceholder = placeholder
            addElement(fresh)
        }
        layout = newLayout
    }
}

enum SlideAspect: String, CaseIterable, Identifiable {
    case widescreen, standard

    var id: String { rawValue }
    var title: String { self == .widescreen ? "16:9" : "4:3" }
    var ratio: CGFloat { self == .widescreen ? 16.0 / 9.0 : 4.0 / 3.0 }
    /// PowerPoint's own point dimensions for the two sizes.
    var size: CGSize {
        self == .widescreen ? CGSize(width: 960, height: 540) : CGSize(width: 720, height: 540)
    }
}

/// The placeholder arrangements offered when adding or restyling a slide.
enum SlideLayout: String, CaseIterable, Identifiable {
    case titleSlide, titleAndBody, twoContent, sectionHeader, titleAndImage, imageOnly, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleSlide: "タイトル スライド"
        case .titleAndBody: "タイトルと内容"
        case .twoContent: "2つの内容"
        case .sectionHeader: "セクション見出し"
        case .titleAndImage: "タイトルと画像"
        case .imageOnly: "画像のみ"
        case .blank: "白紙"
        }
    }

    var icon: String {
        switch self {
        case .titleSlide: "textformat.size"
        case .titleAndBody: "list.bullet.rectangle"
        case .twoContent: "rectangle.split.2x1"
        case .sectionHeader: "text.aligncenter"
        case .titleAndImage: "photo.on.rectangle"
        case .imageOnly: "photo"
        case .blank: "rectangle"
        }
    }

    var hasTitle: Bool { self != .blank && self != .imageOnly }
    var hasBody: Bool {
        switch self {
        case .titleAndBody, .twoContent, .sectionHeader, .titleAndImage: true
        default: false
        }
    }
    var hasSecondary: Bool { self == .twoContent }
    var hasImage: Bool { self == .titleAndImage || self == .imageOnly }
    /// Title slides and section headers centre their text; content layouts
    /// run it top-left.
    var centersContent: Bool { self == .titleSlide || self == .sectionHeader }
}

/// A theme restyles every slide at once — background, title colour, body
/// colour and the accent used for bullets and rules.
enum SlideTheme: String, CaseIterable, Identifiable {
    case classic, midnight, paper, ocean, sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "クラシック"
        case .midnight: "ミッドナイト"
        case .paper: "ペーパー"
        case .ocean: "オーシャン"
        case .sunset: "サンセット"
        }
    }

    var background: Color {
        switch self {
        case .classic: .white
        case .midnight: Color(red: 0.09, green: 0.11, blue: 0.18)
        case .paper: Color(red: 0.98, green: 0.96, blue: 0.91)
        case .ocean: Color(red: 0.93, green: 0.97, blue: 1.0)
        case .sunset: Color(red: 1.0, green: 0.96, blue: 0.93)
        }
    }

    var titleColor: Color {
        switch self {
        case .classic: Color(red: 0.10, green: 0.12, blue: 0.16)
        case .midnight: .white
        case .paper: Color(red: 0.22, green: 0.17, blue: 0.11)
        case .ocean: Color(red: 0.06, green: 0.24, blue: 0.44)
        case .sunset: Color(red: 0.42, green: 0.16, blue: 0.10)
        }
    }

    var bodyColor: Color {
        switch self {
        case .classic: Color(red: 0.24, green: 0.26, blue: 0.30)
        case .midnight: Color(white: 0.86)
        case .paper: Color(red: 0.34, green: 0.29, blue: 0.23)
        case .ocean: Color(red: 0.16, green: 0.32, blue: 0.46)
        case .sunset: Color(red: 0.46, green: 0.30, blue: 0.24)
        }
    }

    var accent: Color {
        switch self {
        case .classic: Color(red: 0.16, green: 0.33, blue: 0.63)
        case .midnight: Color(red: 0.42, green: 0.66, blue: 1.0)
        case .paper: Color(red: 0.70, green: 0.45, blue: 0.16)
        case .ocean: Color(red: 0.0, green: 0.55, blue: 0.75)
        case .sunset: Color(red: 0.90, green: 0.42, blue: 0.24)
        }
    }
}
