import XCTest
import UIKit
@testable import studiquo

/// Coverage for `DocumentBlockMigration`, the one-time conversion of a
/// legacy `TextDocument.bodyData` blob into `blocks`. The design this
/// implements calls for the migration to never lose content even if it has
/// a bug, so the tests below focus on that safety property as much as on
/// the conversion itself.
final class DocumentBlockMigrationTests: XCTestCase {
    private func attributedString(paragraphs: [String]) -> NSAttributedString {
        let joined = paragraphs.joined(separator: "\n")
        return NSAttributedString(string: joined, attributes: DocumentBody.defaultAttributes())
    }

    func testMigratesOneBlockPerParagraph() {
        let document = TextDocument(title: "テスト")
        document.bodyData = DocumentBody.encode(attributedString(paragraphs: ["1つ目の段落", "2つ目の段落", "3つ目の段落"]))

        DocumentBlockMigration.migrateIfNeeded(document)

        XCTAssertEqual(document.sortedBlocks.count, 3)
        let texts = document.sortedBlocks.map { DocumentBody.decode($0.bodyData).string }
        XCTAssertEqual(texts, ["1つ目の段落", "2つ目の段落", "3つ目の段落"])
        XCTAssertTrue(document.sortedBlocks.allSatisfy { $0.kind == .paragraph })
    }

    func testMarksDocumentAsMigrated() {
        let document = TextDocument(title: "テスト")
        document.bodyData = DocumentBody.encode(attributedString(paragraphs: ["本文"]))

        XCTAssertFalse(document.isMigratedToBlocks)
        DocumentBlockMigration.migrateIfNeeded(document)
        XCTAssertTrue(document.isMigratedToBlocks)
    }

    /// Never clears `bodyData` — the whole point is that a bug in `blocks`
    /// never loses content, only ever fails to reflect it.
    func testKeepsBodyDataAfterMigrating() {
        let document = TextDocument(title: "テスト")
        let original = attributedString(paragraphs: ["消えてはいけない本文"])
        document.bodyData = DocumentBody.encode(original)

        DocumentBlockMigration.migrateIfNeeded(document)

        XCTAssertNotNil(document.bodyData)
        XCTAssertEqual(DocumentBody.decode(document.bodyData).string, original.string)
    }

    /// Calling it twice (e.g. opening the same document again) must not
    /// duplicate blocks.
    func testIsIdempotent() {
        let document = TextDocument(title: "テスト")
        document.bodyData = DocumentBody.encode(attributedString(paragraphs: ["段落A", "段落B"]))

        DocumentBlockMigration.migrateIfNeeded(document)
        DocumentBlockMigration.migrateIfNeeded(document)

        XCTAssertEqual(document.sortedBlocks.count, 2)
    }

    /// A document created directly in the new model (no legacy `bodyData`,
    /// but already has `blocks`) must not be overwritten by a spurious
    /// migration from empty `bodyData`.
    func testDoesNotOverwriteExistingBlocks() {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedString(paragraphs: ["新モデルで直接作られた段落"]))
        block.document = document
        document.blocks = [block]

        DocumentBlockMigration.migrateIfNeeded(document)

        XCTAssertEqual(document.sortedBlocks.count, 1)
        XCTAssertTrue(document.isMigratedToBlocks)
    }

    func testEmptyBodyDataProducesOneEmptyParagraphBlockRatherThanNone() {
        let document = TextDocument(title: "テスト")
        document.bodyData = nil

        DocumentBlockMigration.migrateIfNeeded(document)

        XCTAssertEqual(document.sortedBlocks.count, 1)
        XCTAssertEqual(DocumentBody.decode(document.sortedBlocks[0].bodyData).string, "")
    }

    // MARK: replaceParagraphBlocks — the editor's save-checkpoint sync path

    func testReplaceParagraphBlocksGrowsWhenAParagraphIsAdded() {
        let document = TextDocument(title: "テスト")
        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["段落A"]))
        XCTAssertEqual(document.sortedBlocks.count, 1)

        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["段落A", "段落B"]))

        XCTAssertEqual(document.sortedBlocks.count, 2)
        XCTAssertEqual(document.sortedBlocks.map { DocumentBody.decode($0.bodyData).string }, ["段落A", "段落B"])
    }

    func testReplaceParagraphBlocksShrinksWhenAParagraphIsRemoved() {
        let document = TextDocument(title: "テスト")
        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["段落A", "段落B", "段落C"]))
        XCTAssertEqual(document.sortedBlocks.count, 3)

        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["段落A", "段落C"]))

        XCTAssertEqual(document.sortedBlocks.map { DocumentBody.decode($0.bodyData).string }, ["段落A", "段落C"])
    }

    func testReplaceParagraphBlocksUpdatesContentInPlace() {
        let document = TextDocument(title: "テスト")
        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["古い内容"]))

        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["新しい内容"]))

        XCTAssertEqual(document.sortedBlocks.count, 1)
        XCTAssertEqual(DocumentBody.decode(document.sortedBlocks[0].bodyData).string, "新しい内容")
    }

    /// A future table/image block must survive a paragraph-only resync —
    /// this is what lets `replaceParagraphBlocks` run on every editor save
    /// checkpoint without clobbering structural content it doesn't touch.
    func testReplaceParagraphBlocksLeavesNonParagraphBlocksAlone() {
        let document = TextDocument(title: "テスト")
        let table = DocumentBlock(order: 0, kind: .table)
        table.document = document
        document.blocks = [table]

        DocumentBlockMigration.replaceParagraphBlocks(in: document, with: attributedString(paragraphs: ["本文"]))

        XCTAssertTrue(document.sortedBlocks.contains { $0.kind == .table })
        XCTAssertTrue(document.sortedBlocks.contains { $0.kind == .paragraph })
        XCTAssertEqual(document.sortedBlocks.count, 2)
    }
}

/// Coverage for `DocumentBlock`'s table-editing helpers
/// (`addTableRow`/`addTableColumn`/`removeLastTableRow`/
/// `removeLastTableColumn`/`makeTable`), used directly by
/// `DocumentTableBlockView` in the editor.
final class DocumentTableBlockTests: XCTestCase {
    func testMakeTableCreatesTheRequestedShape() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 3)

        XCTAssertEqual(table.sortedTableRows.count, 2)
        XCTAssertTrue(table.sortedTableRows.allSatisfy { $0.sortedCells.count == 3 })
        XCTAssertEqual(table.tableColumnCount, 3)
    }

    func testMakeTableClampsToAtLeastOneRowAndColumn() {
        let table = DocumentBlock.makeTable(order: 0, rows: 0, columns: 0)

        XCTAssertEqual(table.sortedTableRows.count, 1)
        XCTAssertEqual(table.tableColumnCount, 1)
    }

    func testAddTableRowMatchesExistingColumnCount() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)

        table.addTableRow()

        XCTAssertEqual(table.sortedTableRows.count, 2)
        XCTAssertEqual(table.sortedTableRows[1].sortedCells.count, 3)
    }

    func testAddTableColumnAddsACellToEveryRow() {
        let table = DocumentBlock.makeTable(order: 0, rows: 3, columns: 2)

        table.addTableColumn()

        XCTAssertEqual(table.tableColumnCount, 3)
        XCTAssertTrue(table.sortedTableRows.allSatisfy { $0.sortedCells.count == 3 })
    }

    func testRemoveLastTableRowLeavesAtLeastOneRow() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 2)

        table.removeLastTableRow()

        XCTAssertEqual(table.sortedTableRows.count, 1, "a table can't drop below one row")
    }

    func testRemoveLastTableColumnLeavesAtLeastOneColumn() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 1)

        table.removeLastTableColumn()

        XCTAssertEqual(table.tableColumnCount, 1, "a table can't drop below one column")
    }

    func testRemoveLastTableRowAndColumnActuallyShrink() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)

        table.removeLastTableRow()
        XCTAssertEqual(table.sortedTableRows.count, 1)

        table.removeLastTableColumn()
        XCTAssertEqual(table.tableColumnCount, 1)
    }

    func testCellTextRoundTripsThroughBodyData() {
        let cell = DocumentTableCell(order: 0)
        cell.text = "セルの中身"
        XCTAssertEqual(cell.text, "セルの中身")
    }

    // MARK: mergeCellWithRight

    func testMergeCellWithRightCombinesTextAndRemovesTheRightCell() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)
        let row = table.sortedTableRows[0]
        row.sortedCells[0].text = "左"
        row.sortedCells[1].text = "右"

        table.mergeCellWithRight(row: row, cellIndex: 0)

        XCTAssertEqual(row.sortedCells.count, 2, "one cell absorbed the other")
        XCTAssertEqual(row.sortedCells[0].text, "左 右")
    }

    func testMergeCellWithRightAbsorbsColumnSpan() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)
        let row = table.sortedTableRows[0]

        table.mergeCellWithRight(row: row, cellIndex: 0)

        XCTAssertEqual(row.sortedCells[0].columnSpan, 2)
    }

    func testMergeCellWithRightKeepsTheTablesLogicalColumnCount() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)
        let row = table.sortedTableRows[0]

        table.mergeCellWithRight(row: row, cellIndex: 0)

        // 3 columns, one merge: 2 stored cells, but still 3 columns wide.
        XCTAssertEqual(table.tableColumnCount, 3)
    }

    func testMergeCellWithRightOnTheLastCellIsANoOp() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 2)
        let row = table.sortedTableRows[0]

        table.mergeCellWithRight(row: row, cellIndex: 1)

        XCTAssertEqual(row.sortedCells.count, 2, "nothing to the right of the last cell to merge with")
    }

    func testAddTableRowAfterAMergeUsesTheLogicalColumnCount() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)
        table.mergeCellWithRight(row: table.sortedTableRows[0], cellIndex: 0)

        table.addTableRow()

        XCTAssertEqual(table.sortedTableRows[1].sortedCells.count, 3, "a fresh row isn't merged, so it needs all 3 cells")
    }

    func testEmptyLeftCellMergeDoesNotLeaveALeadingSpace() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 2)
        let row = table.sortedTableRows[0]
        row.sortedCells[1].text = "右のみ"

        table.mergeCellWithRight(row: row, cellIndex: 0)

        XCTAssertEqual(row.sortedCells[0].text, "右のみ")
    }

    // MARK: mergeCellWithBelow

    func testMergeCellWithBelowCombinesTextAndRemovesTheLowerCell() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)
        let top = table.sortedTableRows[0]
        let bottom = table.sortedTableRows[1]
        top.sortedCells[0].text = "上"
        bottom.sortedCells[0].text = "下"

        table.mergeCellWithBelow(row: top, cellIndex: 0)

        XCTAssertEqual(bottom.sortedCells.count, 1, "the top row absorbed the cell below it")
        XCTAssertEqual(top.sortedCells[0].text, "上 下")
    }

    func testMergeCellWithBelowAbsorbsRowSpan() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)
        let top = table.sortedTableRows[0]

        table.mergeCellWithBelow(row: top, cellIndex: 0)

        XCTAssertEqual(top.sortedCells[0].rowSpan, 2)
    }

    func testMergeCellWithBelowOnTheLastRowIsANoOp() {
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 2)
        let row = table.sortedTableRows[0]

        table.mergeCellWithBelow(row: row, cellIndex: 0)

        XCTAssertEqual(row.sortedCells.count, 2, "nothing below the last row to merge with")
    }

    func testMergeCellWithBelowFindsTheRightCellByVisualColumnNotArrayIndex() {
        // Bottom row: columns 0-1 merged into one cell (array index 0, span
        // 2), so its remaining column-2 cell sits at array index 1, not 2.
        // Merging the top row's column-2 cell (array index 2) below must
        // still find that array-index-1 cell — matching by visual column,
        // not by raw array index.
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 3)
        let top = table.sortedTableRows[0]
        let bottom = table.sortedTableRows[1]
        table.mergeCellWithRight(row: bottom, cellIndex: 0) // bottom: [span-2(cols 0-1), col2]
        top.sortedCells[2].text = "上"
        bottom.sortedCells[1].text = "下"

        table.mergeCellWithBelow(row: top, cellIndex: 2)

        XCTAssertEqual(top.sortedCells[2].text, "上 下")
        XCTAssertEqual(bottom.sortedCells.count, 1, "only the column-2 cell (bottom's array index 1) was absorbed")
    }

    func testMergeCellWithBelowRefusesMismatchedColumnSpans() {
        // Top row has a 2-wide merged cell at columns 0-1; the row below is
        // unmerged, so no single cell there starts at column 0 with the
        // same width — merging would leave the grid without a consistent
        // column boundary, so this must be a no-op.
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 3)
        let top = table.sortedTableRows[0]
        let bottom = table.sortedTableRows[1]
        table.mergeCellWithRight(row: top, cellIndex: 0)

        table.mergeCellWithBelow(row: top, cellIndex: 0)

        XCTAssertEqual(top.sortedCells[0].rowSpan, 1, "mismatched widths must not merge")
        XCTAssertEqual(bottom.sortedCells.count, 3)
    }

    // MARK: tableGridRows

    func testTableGridRowsIsAllCellsForAnUnmergedTable() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)

        let grid = table.tableGridRows

        XCTAssertEqual(grid.count, 2)
        XCTAssertTrue(grid.allSatisfy { row in
            row.allSatisfy { if case .cell = $0 { return true } else { return false } }
        })
    }

    func testTableGridRowsInsertsACoveredPlaceholderBelowAVerticalMerge() {
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)
        table.mergeCellWithBelow(row: table.sortedTableRows[0], cellIndex: 0)

        let grid = table.tableGridRows

        // Bottom row, column 0 must be `.covered`, not simply missing — the
        // remaining bottom-row cell (originally column 1) must still render
        // under column 1, not shift left into column 0's slot.
        guard case .covered(let span) = grid[1][0] else {
            return XCTFail("expected the bottom-left slot to be covered by the merge above it")
        }
        XCTAssertEqual(span, 1)
        guard case .cell(let cell) = grid[1][1] else {
            return XCTFail("expected the bottom-right slot to still hold its own cell")
        }
        XCTAssertTrue(cell === table.sortedTableRows[1].sortedCells[0], "the surviving bottom cell is still the original column-1 cell")
    }
}

/// Coverage for `DocumentBlock.addComment` and the anchor being a real
/// relationship rather than a snapshotted `order` number — the regression
/// this guards against: `order` gets renumbered on essentially every
/// structural edit (`insertTable`, `replaceParagraphRun`), so a comment
/// anchored by a stored order number would silently drift onto the wrong
/// block the moment anything before it shifted.
final class DocumentCommentTests: XCTestCase {
    func testAddCommentAttachesToTheBlockAndTheDocument() {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.document = document
        document.blocks = [block]

        let comment = block.addComment(author: "太郎", text: "ここ直して")

        XCTAssertEqual(block.sortedAnchoredComments.map(\.text), ["ここ直して"])
        XCTAssertTrue(comment.anchorBlock === block)
        XCTAssertTrue(comment.document === document)
    }

    func testCommentAnchorSurvivesTheBlocksOrderChanging() {
        let document = TextDocument(title: "テスト")
        let first = DocumentBlock(order: 0, kind: .paragraph)
        first.document = document
        let second = DocumentBlock(order: 1, kind: .paragraph)
        second.document = document
        document.blocks = [first, second]
        let comment = second.addComment(author: "太郎", text: "この段落について")

        // Simulate a structural edit renumbering every block's `order` —
        // e.g. a table inserted before both of these.
        for (index, block) in [second, first].enumerated() { block.order = index }

        XCTAssertTrue(comment.anchorBlock === second, "the anchor is unaffected by order renumbering")
    }

    func testHasUnresolvedCommentsReflectsResolution() {
        let block = DocumentBlock(order: 0, kind: .paragraph)
        let comment = block.addComment(author: "太郎", text: "確認して")

        XCTAssertTrue(block.hasUnresolvedComments)
        comment.isResolved = true
        XCTAssertFalse(block.hasUnresolvedComments)
    }

    func testMultipleCommentsAreSortedOldestFirst() {
        let block = DocumentBlock(order: 0, kind: .paragraph)
        let first = block.addComment(author: "A", text: "最初")
        first.createdAt = Date(timeIntervalSince1970: 0)
        let second = block.addComment(author: "B", text: "次")
        second.createdAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(block.sortedAnchoredComments.map(\.text), ["最初", "次"])
    }

    func testCommentAnchorOnATextSegmentIsItsFirstBlock() {
        let document = TextDocument(title: "テスト")
        let paragraphs = ["段落A", "段落B"].enumerated().map { index, text -> DocumentBlock in
            let block = DocumentBlock(order: index, kind: .paragraph)
            block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
            block.document = document
            return block
        }
        document.blocks = paragraphs

        let segment = document.segments[0]

        XCTAssertTrue(segment.commentAnchor === paragraphs[0])
    }
}

/// Coverage for `DocumentChangeRecord`, in particular `reject()` reverting
/// the anchor block's text and the record surviving its anchor block being
/// deleted (the whole reason it stores `previousText`/`newText` directly
/// rather than only pointing at the block).
final class DocumentChangeRecordTests: XCTestCase {
    private func block(text: String) -> DocumentBlock {
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
        return block
    }

    func testRejectRestoresThePreviousTextToTheAnchorBlock() {
        let anchor = block(text: "編集後の文章")
        let record = DocumentChangeRecord(author: "太郎", kind: .edit, previousText: "編集前の文章", newText: "編集後の文章", anchorBlock: anchor)

        record.reject()

        XCTAssertEqual(DocumentBody.decode(anchor.bodyData).string, "編集前の文章")
        XCTAssertEqual(record.status, .rejected)
    }

    func testRejectWithNoAnchorBlockStillMarksRejected() {
        let record = DocumentChangeRecord(author: "太郎", kind: .edit, previousText: "前", newText: "後", anchorBlock: nil)

        record.reject()

        XCTAssertEqual(record.status, .rejected)
    }

    func testNewRecordDefaultsToPending() {
        let record = DocumentChangeRecord(author: "太郎", kind: .edit, previousText: "前", newText: "後", anchorBlock: nil)
        XCTAssertEqual(record.status, .pending)
    }

    func testPendingChangeRecordsFiltersByStatus() {
        let document = TextDocument(title: "テスト")
        let pending = DocumentChangeRecord(author: "A", kind: .edit, previousText: "1", newText: "2", anchorBlock: nil)
        let accepted = DocumentChangeRecord(author: "B", kind: .edit, previousText: "3", newText: "4", anchorBlock: nil)
        accepted.status = .accepted
        document.changeRecords = [pending, accepted]

        XCTAssertEqual(document.pendingChangeRecords.map(\.author), ["A"])
    }
}

/// Coverage for hyperlinks: `.link` is a native `NSAttributedString`
/// attribute (`TextDocumentView` just applies/removes it plus color and
/// underline styling), so the one thing actually worth verifying here is
/// that `DocumentBody`'s archive/unarchive round trip — the same one every
/// paragraph's text goes through — doesn't silently drop the URL, the way
/// an insecure-coding unarchiver reasonably might for a non-string value.
final class DocumentHyperlinkTests: XCTestCase {
    func testLinkAttributeSurvivesEncodeAndDecode() {
        let url = URL(string: "https://example.com/notes")!
        let text = NSMutableAttributedString(string: "参考資料", attributes: DocumentBody.defaultAttributes())
        text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))

        let decoded = DocumentBody.decode(DocumentBody.encode(text))

        XCTAssertEqual(decoded.attribute(.link, at: 0, effectiveRange: nil) as? URL, url)
    }

    func testLinkColorAndUnderlineSurviveEncodeAndDecode() {
        let text = NSMutableAttributedString(string: "リンク", attributes: DocumentBody.defaultAttributes())
        let range = NSRange(location: 0, length: text.length)
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: range)
        text.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)

        let decoded = DocumentBody.decode(DocumentBody.encode(text))

        XCTAssertEqual(decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNotNil(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    /// A link only over part of a paragraph must not bleed into the
    /// surrounding plain text — the boundary the `longestEffectiveRange`
    /// lookup in `existingLinkRange` depends on.
    func testLinkRangeDoesNotExtendPastItsOwnBoundary() {
        let text = NSMutableAttributedString(string: "見てxリンクxはここ", attributes: DocumentBody.defaultAttributes())
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 2, length: 4))

        var range = NSRange(location: 0, length: 0)
        let value = text.attribute(.link, at: 3, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length))

        XCTAssertNotNil(value)
        XCTAssertEqual(range, NSRange(location: 2, length: 4))
    }
}
