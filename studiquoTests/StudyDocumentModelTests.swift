import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class StudyDocumentModelTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    func testSortedFootnotesAndDynamicRenumberingFollowBlockOrderThenCreationTimeAndPlaceUnanchoredLast() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let doc = TextDocument(title: "論文")
        let blockFirst = DocumentBlock(order: 0, kind: .paragraph)
        let blockSecond = DocumentBlock(order: 1, kind: .paragraph)
        blockFirst.document = doc
        blockSecond.document = doc
        doc.blocks = [blockSecond, blockFirst]

        let fnSecondBlock = DocumentFootnote(text: "段落2の注", anchorBlock: blockSecond)
        fnSecondBlock.createdAt = Date(timeIntervalSince1970: 100)

        let fnFirstBlockEarly = DocumentFootnote(text: "段落1の注A", anchorBlock: blockFirst)
        fnFirstBlockEarly.createdAt = Date(timeIntervalSince1970: 200)

        let fnFirstBlockLate = DocumentFootnote(text: "段落1の注B", anchorBlock: blockFirst)
        fnFirstBlockLate.createdAt = Date(timeIntervalSince1970: 300)

        let fnOrphan = DocumentFootnote(text: "アンカーなし注", anchorBlock: nil)
        fnOrphan.createdAt = Date(timeIntervalSince1970: 50)

        doc.footnotes = [fnOrphan, fnSecondBlock, fnFirstBlockLate, fnFirstBlockEarly]
        context.insert(doc)

        XCTAssertEqual(
            doc.sortedFootnotes.map(\.text),
            ["段落1の注A", "段落1の注B", "段落2の注", "アンカーなし注"]
        )
        XCTAssertEqual(doc.footnoteNumber(for: fnFirstBlockEarly), 1)
        XCTAssertEqual(doc.footnoteNumber(for: fnFirstBlockLate), 2)
        XCTAssertEqual(doc.footnoteNumber(for: fnSecondBlock), 3)
        XCTAssertEqual(doc.footnoteNumber(for: fnOrphan), 4)

        // Swap paragraph order: footnotes renumber automatically without stored indices.
        blockSecond.order = -1
        XCTAssertEqual(doc.footnoteNumber(for: fnSecondBlock), 1)
        XCTAssertEqual(doc.footnoteNumber(for: fnFirstBlockEarly), 2)
        XCTAssertEqual(doc.footnoteNumber(for: fnFirstBlockLate), 3)

        let unrelatedFootnote = DocumentFootnote(text: "別文書の注", anchorBlock: nil)
        XCTAssertNil(doc.footnoteNumber(for: unrelatedFootnote))
    }

    func testHeaderFooterLazilyCreatesOncePerKind() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let doc = TextDocument(title: "レポート")
        context.insert(doc)

        XCTAssertNil(doc.header)
        XCTAssertNil(doc.footer)

        let header1 = doc.headerFooter(.header)
        header1.text = "章タイトル"
        let header2 = doc.headerFooter(.header)
        XCTAssertTrue(header1 === header2, "Repeated calls must return the existing header instance")
        XCTAssertEqual(doc.header?.text, "章タイトル")
        XCTAssertNil(doc.footer)

        let footer = doc.headerFooter(.footer)
        XCTAssertEqual(footer.kind, .footer)
        XCTAssertEqual(doc.headerFooters?.count, 2)
    }

    func testPendingChangeRecordsRejectRevertsBlockTextAndDocumentMetrics() {
        let doc = TextDocument(title: "テスト")
        doc.plainText = "Hello world\nStudiquo テスト"
        XCTAssertEqual(doc.wordCount, 4)
        XCTAssertEqual(doc.characterCount, "Hello worldStudiquo テスト".count)

        XCTAssertEqual(doc.pageSize, .a4)
        doc.pageSize = .b5
        XCTAssertEqual(doc.pageSizeRawValue, "b5")
        XCTAssertEqual(doc.pageSize.size, CGSize(width: 516, height: 729))

        doc.pageSizeRawValue = "unknown-size"
        XCTAssertEqual(doc.pageSize, .a4, "Invalid raw value falls back to A4")

        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: "変更後の本文", attributes: DocumentBody.defaultAttributes()))
        let pending = DocumentChangeRecord(author: "A", kind: .edit, previousText: "変更前の本文", newText: "変更後の本文", anchorBlock: block)
        let accepted = DocumentChangeRecord(author: "B", kind: .insert, previousText: "", newText: "追加", anchorBlock: nil)
        accepted.status = DocumentChangeStatus.accepted
        doc.changeRecords = [pending, accepted]

        XCTAssertEqual(doc.pendingChangeRecords.count, 1)
        XCTAssertTrue(doc.pendingChangeRecords.first === pending)

        pending.reject()
        XCTAssertEqual(pending.status, .rejected)
        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "変更前の本文")
        XCTAssertTrue(doc.pendingChangeRecords.isEmpty)
    }
}
