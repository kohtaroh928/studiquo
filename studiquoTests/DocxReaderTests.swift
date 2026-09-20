import XCTest
@testable import studiquo

/// Coverage for `DocxReader`. The main tests round-trip through
/// `DocxWriter` (write a document, read it back, check the content
/// survives) — the two were designed as a matched pair, so this exercises
/// both together the way they'll actually be used. Separate tests feed
/// hand-written OOXML that varies from exactly what `DocxWriter` emits (an
/// explicit `w:val="0"`, no `numbering.xml` at all, …), since a real
/// docx — from actual Word, or any other tool — won't always match this
/// app's own writer byte-for-byte.
final class DocxReaderTests: XCTestCase {
    private func attributedText(_ text: String, bold: Bool = false, italic: Bool = false, link: URL? = nil) -> NSAttributedString {
        var attrs = DocumentBody.defaultAttributes()
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            let descriptor = UIFont.systemFont(ofSize: 13).fontDescriptor.withSymbolicTraits(traits) ?? UIFont.systemFont(ofSize: 13).fontDescriptor
            attrs[.font] = UIFont(descriptor: descriptor, size: 13)
        }
        if let link { attrs[.link] = link }
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: Round trip through DocxWriter

    func testRoundTripPreservesPlainParagraphText() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("これは本文です"))
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(DocumentBody.decode(readBack[0].bodyData).string, "これは本文です")
    }

    func testRoundTripPreservesHeadingStyle() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("見出し"))
        block.paragraphStyle = .heading2
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack[0].paragraphStyle, .heading2)
    }

    func testRoundTripPreservesBoldAndItalic() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("強調文字", bold: true, italic: true))
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        let text = DocumentBody.decode(readBack[0].bodyData)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(traits.contains(.traitBold))
        XCTAssertTrue(traits.contains(.traitItalic))
    }

    func testRoundTripPreservesHyperlinkURL() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("リンク", link: URL(string: "https://studiquo.example")!))
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        let text = DocumentBody.decode(readBack[0].bodyData)
        XCTAssertEqual(text.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://studiquo.example")!)
    }

    func testRoundTripPreservesListKindAndLevel() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("項目"))
        block.listKind = .numbered
        block.listLevel = 1
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack[0].listKind, .numbered)
        XCTAssertEqual(readBack[0].listLevel, 1)
    }

    func testRoundTripPreservesBulletedLists() throws {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.bodyData = DocumentBody.encode(attributedText("項目"))
        block.listKind = .bulleted
        document.blocks = [block]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack[0].listKind, .bulleted)
    }

    func testRoundTripPreservesTableCellsAndMergedSpan() throws {
        let document = TextDocument(title: "テスト")
        let table = DocumentBlock.makeTable(order: 0, rows: 2, columns: 2)
        table.sortedTableRows[0].sortedCells[0].text = "名前"
        table.sortedTableRows[0].sortedCells[1].text = "点数"
        table.sortedTableRows[1].sortedCells[0].text = "太郎"
        table.sortedTableRows[1].sortedCells[1].text = "95"
        table.mergeCellWithRight(row: table.sortedTableRows[0], cellIndex: 0)
        document.blocks = [table]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(readBack[0].kind, .table)
        let rows = readBack[0].sortedTableRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sortedCells.count, 1, "the merged row now has one stored cell spanning 2 columns")
        XCTAssertEqual(rows[0].sortedCells[0].columnSpan, 2)
        XCTAssertEqual(rows[1].sortedCells.map(\.text), ["太郎", "95"])
    }

    func testRoundTripPreservesOrderOfMixedContent() throws {
        let document = TextDocument(title: "テスト")
        let p1 = DocumentBlock(order: 0, kind: .paragraph)
        p1.bodyData = DocumentBody.encode(attributedText("段落1"))
        let table = DocumentBlock.makeTable(order: 1, rows: 1, columns: 1)
        table.sortedTableRows[0].sortedCells[0].text = "セル"
        let p2 = DocumentBlock(order: 2, kind: .paragraph)
        p2.bodyData = DocumentBody.encode(attributedText("段落2"))
        document.blocks = [p1, table, p2]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let readBack = try DocxReader.read(from: data).blocks

        XCTAssertEqual(readBack.map(\.kind), [.paragraph, .table, .paragraph])
        XCTAssertEqual(DocumentBody.decode(readBack[0].bodyData).string, "段落1")
        XCTAssertEqual(DocumentBody.decode(readBack[2].bodyData).string, "段落2")
    }

    // MARK: Robustness against real-world variation

    /// `<w:b w:val="0"/>` is valid OOXML for "bold explicitly off" — a
    /// naive reader that treats any `<w:b>` element as "bold on" regardless
    /// of its `w:val` would get this backwards.
    func testExplicitlyOffBooleanRunPropertyIsNotTreatedAsOn() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>普通の文字</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let blocks = try parseMinimalDocx(documentXML: xml)
        let text = DocumentBody.decode(blocks[0].bodyData)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testMissingNumberingXMLDoesNotCrashAndLeavesParagraphsUnlisted() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>項目</w:t></w:r></w:p></w:body>
        </w:document>
        """
        // No numbering.xml entry at all in this archive.
        let entries = [
            DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8)),
        ]
        let data = try DocxZip.write(entries)

        let blocks = try DocxReader.read(from: data).blocks

        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].listKind, "no numbering.xml to resolve numId 1 against, so it can't be classified as a list")
    }

    func testEmptyParagraphProducesAnEmptyTextBlockNotACrash() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p/></w:body>
        </w:document>
        """
        let blocks = try parseMinimalDocx(documentXML: xml)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(DocumentBody.decode(blocks[0].bodyData).string, "")
    }

    func testUnrecognizedParagraphStyleIDFallsBackToBodyRatherThanCrashing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:pPr><w:pStyle w:val="SomeCustomWordStyleThisAppDoesNotKnow"/></w:pPr><w:r><w:t>本文</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let blocks = try parseMinimalDocx(documentXML: xml)
        XCTAssertNil(blocks[0].paragraphStyle)
    }

    func testNonDocxDataThrowsRatherThanCrashing() {
        let notADocx = "plain text file".data(using: .utf8)!
        XCTAssertThrowsError(try DocxReader.read(from: notADocx).blocks) { error in
            XCTAssertEqual(error as? DocxReader.ReadError, .notADocx)
        }
    }

    func testZipWithoutADocumentPartThrowsMissingDocumentPart() {
        let entries = [DocxZip.Entry(path: "[Content_Types].xml", data: Data("<Types/>".utf8))]
        let data = try! DocxZip.write(entries)

        XCTAssertThrowsError(try DocxReader.read(from: data).blocks) { error in
            XCTAssertEqual(error as? DocxReader.ReadError, .missingDocumentPart)
        }
    }

    // MARK: droppedElementKinds — the "never silently lose content" report

    func testDocumentWithNoUnsupportedContentReportsNothingDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>普通の本文</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let entries = [DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8))]
        let data = try DocxZip.write(entries)

        let result = try DocxReader.read(from: data)

        XCTAssertTrue(result.droppedElementKinds.isEmpty)
    }

    func testImageElementIsReportedAsDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:drawing><wp:inline/></w:drawing></w:r></w:p></w:body>
        </w:document>
        """
        let entries = [DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8))]
        let data = try DocxZip.write(entries)

        let result = try DocxReader.read(from: data)

        XCTAssertEqual(result.droppedElementKinds, ["画像"])
    }

    func testEquationElementIsReportedAsDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><m:oMath><m:r><m:t>x</m:t></m:r></m:oMath></w:p></w:body>
        </w:document>
        """
        let entries = [DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8))]
        let data = try DocxZip.write(entries)

        let result = try DocxReader.read(from: data)

        XCTAssertEqual(result.droppedElementKinds, ["数式"])
    }

    func testMultipleDroppedElementsAreEachCountedSeparately() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        <w:p><w:r><w:drawing/></w:r></w:p>
        <w:p><w:r><w:drawing/></w:r></w:p>
        <w:p><m:oMath/></w:p>
        </w:body>
        </w:document>
        """
        let entries = [DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8))]
        let data = try DocxZip.write(entries)

        let result = try DocxReader.read(from: data)

        XCTAssertEqual(result.droppedElementKinds.filter { $0 == "画像" }.count, 2)
        XCTAssertEqual(result.droppedElementKinds.filter { $0 == "数式" }.count, 1)
    }

    /// Headers/footers live in separate archive parts this reader never
    /// opens — unlike the other dropped-element cases, this has to be
    /// detected by which *parts* exist in the archive, not anything found
    /// while walking `document.xml`.
    func testHeaderPartPresenceIsReportedAsDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>本文</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let entries = [
            DocxZip.Entry(path: "word/document.xml", data: Data(xml.utf8)),
            DocxZip.Entry(path: "word/header1.xml", data: Data("<w:hdr/>".utf8)),
        ]
        let data = try DocxZip.write(entries)

        let result = try DocxReader.read(from: data)

        XCTAssertEqual(result.droppedElementKinds, ["ヘッダー/フッター"])
    }

    func testOwnWritersOutputHasNothingDroppedForSupportedContent() throws {
        // The end-to-end sanity check: everything DocxWriter actually
        // emits should round-trip clean, with zero drops reported.
        let document = TextDocument(title: "テスト")
        let paragraph = DocumentBlock(order: 0, kind: .paragraph)
        paragraph.bodyData = DocumentBody.encode(attributedText("本文", bold: true))
        let table = DocumentBlock.makeTable(order: 1, rows: 1, columns: 1)
        document.blocks = [paragraph, table]

        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: document))
        let result = try DocxReader.read(from: data)

        XCTAssertTrue(result.droppedElementKinds.isEmpty)
    }

    // MARK: Helper

    private func parseMinimalDocx(documentXML: String) throws -> [DocumentBlock] {
        let entries = [DocxZip.Entry(path: "word/document.xml", data: Data(documentXML.utf8))]
        let data = try DocxZip.write(entries)
        return try DocxReader.read(from: data).blocks
    }
}
