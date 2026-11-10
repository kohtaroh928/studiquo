import XCTest
@testable import studiquo

/// A shared document's snapshot is written by another member of the room. These
/// check that one made by hand, with numbers no editor writes, cannot crash the
/// device that receives it: the values are bounded when the snapshot is read,
/// and the code that draws tables and list markers bounds them again.
final class CollabSnapshotValidationTests: XCTestCase {
    private func block(
        id: String = "b1", kind: String = "paragraph", listKind: String? = nil, listLevel: Int = 0,
        rows: [[DocumentSnapshot.Cell]]? = nil,
        comments: [DocumentSnapshot.Comment] = [], footnotes: [DocumentSnapshot.Footnote] = []
    ) -> DocumentSnapshot.Block {
        .init(id: id, kind: kind, body: nil, imageHash: nil, equationSource: "", listKind: listKind,
              listLevel: listLevel, paragraphStyle: nil, rows: rows, comments: comments, footnotes: footnotes)
    }

    private func snapshot(_ blocks: [DocumentSnapshot.Block], columnCount: Int = 1) -> DocumentSnapshot {
        DocumentSnapshot(title: "文書", pageSize: "a4", columnCount: columnCount, header: nil, footer: nil, blocks: blocks)
    }

    /// What arrives from the room: the snapshot as JSON text, read back the way the sync engine reads it.
    private func received(_ snapshot: DocumentSnapshot) -> DocumentSnapshot? {
        DocumentSnapshot.decoded(snapshot.encoded())
    }

    private func cell(_ columnSpan: Int, _ rowSpan: Int) -> DocumentSnapshot.Cell {
        .init(body: nil, columnSpan: columnSpan, rowSpan: rowSpan)
    }

    // MARK: Reading a snapshot

    func testOutOfRangeNumbersAreHeldToWhatTheAppCanDraw() throws {
        let hostile = snapshot([
            block(id: "low", listKind: "bulleted", listLevel: -1),
            block(id: "high", listKind: "numbered", listLevel: .max),
            block(id: "table", kind: "table", rows: [[cell(-5, 3), cell(0, 0)], [cell(.max, .max), cell(.min, .min)]]),
        ], columnCount: 0)

        let read = try XCTUnwrap(received(hostile))

        XCTAssertEqual(read.columnCount, 1)
        XCTAssertEqual(read.blocks[0].listLevel, 0)
        XCTAssertEqual(read.blocks[1].listLevel, DocumentSnapshot.Limits.maxListLevel)
        let rows = try XCTUnwrap(read.blocks[2].rows)
        XCTAssertEqual(rows[0].map(\.columnSpan), [1, 1])
        XCTAssertEqual(rows[0].map(\.rowSpan), [3, 1])
        XCTAssertEqual(rows[1].map(\.columnSpan), [DocumentTableCell.maxColumnSpan, 1])
        XCTAssertEqual(rows[1].map(\.rowSpan), [DocumentTableCell.maxRowSpan, 1])
        XCTAssertEqual(try XCTUnwrap(received(snapshot([], columnCount: 99))).columnCount, 3)
    }

    func testAnOrdinarySnapshotIsReadUnchanged() throws {
        let ordinary = snapshot([
            block(id: "a", listKind: "bulleted", listLevel: 2),
            block(id: "t", kind: "table", rows: [[cell(2, 1), cell(1, 2)], [cell(1, 1)]]),
        ], columnCount: 2)

        XCTAssertEqual(try XCTUnwrap(received(ordinary)), ordinary)
    }

    func testASnapshotOverTheLimitsIsRefusedWhole() {
        let limits = DocumentSnapshot.Limits.self
        let tooManyBlocks = snapshot((0...limits.maxBlocks).map { block(id: "b\($0)") })
        let tooManyRows = snapshot([block(kind: "table", rows: Array(repeating: [cell(1, 1)], count: limits.maxTableRows + 1))])
        let tooManyCells = snapshot([block(kind: "table", rows: [Array(repeating: cell(1, 1), count: limits.maxCellsPerRow + 1)])])
        let comment = DocumentSnapshot.Comment(author: "a", text: "t", createdAt: 0, isResolved: false)
        let tooManyComments = snapshot([block(comments: Array(repeating: comment, count: limits.maxCommentsPerBlock + 1))])
        let note = DocumentSnapshot.Footnote(text: "t", createdAt: 0)
        let tooManyNotes = snapshot([block(footnotes: Array(repeating: note, count: limits.maxFootnotesPerBlock + 1))])

        for refused in [tooManyBlocks, tooManyRows, tooManyCells, tooManyComments, tooManyNotes] {
            XCTAssertNil(received(refused))
        }
        // At the limit is still accepted.
        XCTAssertNotNil(received(snapshot((0..<limits.maxBlocks).map { block(id: "b\($0)") })))
    }

    // MARK: Applying a snapshot

    func testApplyingAHostileSnapshotLeavesADocumentThatCanBeDrawn() throws {
        let document = TextDocument(title: "文書")
        document.isMigratedToBlocks = true
        // Handed to apply without going through `decoded`, as a caller that forgot to check would.
        let hostile = snapshot([
            block(id: "list", listKind: "bulleted", listLevel: -7),
            block(id: "table", kind: "table", rows: [[cell(-5, 3), cell(.max, 2)], [cell(.max, .max)]]),
        ], columnCount: -4)

        DocumentSnapshotCodec.apply(hostile, to: document, assets: [:])

        XCTAssertEqual(document.columnCount, 1)
        let blocks = document.sortedBlocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].listLevel, 0)
        XCTAssertEqual(document.listMarker(for: blocks[0]), "•")
        let table = blocks[1]
        XCTAssertEqual(table.tableColumnCount, 1 + DocumentTableCell.maxColumnSpan)
        XCTAssertEqual(table.tableGridRows.count, 2)
    }

    func testApplyingASnapshotOverTheLimitsChangesNothing() {
        let document = TextDocument(title: "元の題")
        document.isMigratedToBlocks = true
        let kept = DocumentBlock(order: 0, kind: .paragraph)
        kept.collabID = "kept"
        kept.document = document
        document.blocks = [kept]
        var oversized = snapshot((0...DocumentSnapshot.Limits.maxBlocks).map { block(id: "b\($0)") })
        oversized.title = "書き換え"

        DocumentSnapshotCodec.apply(oversized, to: document, assets: [:])

        XCTAssertEqual(document.title, "元の題")
        XCTAssertEqual(document.sortedBlocks.map(\.collabID), ["kept"])
    }

    // MARK: Drawing values that are already stored

    /// Values stored before this check existed, or that came in another way (an imported file).
    func testTableLayoutSurvivesStoredSpansThatAreOutOfRange() {
        for (columnSpan, rowSpan) in [(-5, 3), (0, 2), (Int.max, Int.max), (Int.min, Int.min), (Int.max, 2)] {
            let table = DocumentBlock(order: 0, kind: .table)
            var rows: [DocumentTableRow] = []
            for rowIndex in 0..<3 {
                let row = DocumentTableRow(order: rowIndex)
                row.block = table
                var cells: [DocumentTableCell] = []
                for cellIndex in 0..<3 {
                    let cell = DocumentTableCell(order: cellIndex)
                    cell.columnSpan = columnSpan
                    cell.rowSpan = rowSpan
                    cell.row = row
                    cells.append(cell)
                }
                row.cells = cells
                rows.append(row)
            }
            table.tableRows = rows

            XCTAssertGreaterThan(table.tableColumnCount, 0, "spans \(columnSpan)x\(rowSpan)")
            XCTAssertLessThanOrEqual(table.tableColumnCount, 3 * DocumentTableCell.maxColumnSpan)
            XCTAssertEqual(table.tableGridRows.count, 3, "spans \(columnSpan)x\(rowSpan)")
        }
    }

    func testListMarkerSurvivesAStoredLevelThatIsOutOfRange() {
        for level in [-1, Int.min, 3, Int.max] {
            for kind in [DocumentListKind.bulleted, .numbered] {
                let document = TextDocument(title: "文書")
                let item = DocumentBlock(order: 0, kind: .paragraph)
                item.listKind = kind
                item.listLevel = level
                item.document = document
                document.blocks = [item]
                document.isMigratedToBlocks = true

                XCTAssertNotNil(document.listMarker(for: item), "level \(level)")
            }
        }
    }
}
