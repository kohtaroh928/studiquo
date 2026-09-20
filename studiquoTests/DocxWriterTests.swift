import XCTest
@testable import studiquo

/// Coverage for `DocxWriter`. Its output was already independently
/// validated once by hand — the generated file opened correctly in
/// `python-docx` (a real, independent OOXML library — separate from
/// anything this app's own code assumes), with correct paragraph styles,
/// bold runs, hyperlinks (including the actual target URL), list numbering,
/// and table contents. These tests re-check the same ground so a future
/// regression is caught automatically.
final class DocxWriterTests: XCTestCase {
    private func document(_ blocks: (TextDocument) -> [DocumentBlock]) -> TextDocument {
        let document = TextDocument(title: "テスト")
        document.blocks = blocks(document)
        return document
    }

    private func paragraph(_ order: Int, _ text: String, style: DocumentParagraphStyle? = nil) -> DocumentBlock {
        let block = DocumentBlock(order: order, kind: .paragraph)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
        block.paragraphStyle = style
        return block
    }

    /// Every extracted XML part must itself be well-formed — parseable by
    /// `XMLParser` without error. A malformed part is a docx Word simply
    /// refuses to open, with no useful error message pointing back here.
    private func assertAllPartsAreWellFormedXML(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try DocxZip.read(data)
        for entry in entries {
            let parser = XMLParser(data: entry.data)
            let delegate = CollectingXMLDelegate()
            parser.delegate = delegate
            XCTAssertTrue(parser.parse(), "\(entry.path) is not well-formed XML: \(delegate.error?.localizedDescription ?? "?")", file: file, line: line)
        }
    }

    private final class CollectingXMLDelegate: NSObject, XMLParserDelegate {
        var error: Error?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    func testProducesAValidZipWithTheRequiredOOXMLParts() throws {
        let doc = document { _ in [paragraph(0, "本文", style: nil)] }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let entries = try DocxZip.read(data)
        let paths = Set(entries.map(\.path))

        for required in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/_rels/document.xml.rels"] {
            XCTAssertTrue(paths.contains(required), "missing required part: \(required)")
        }
    }

    func testEveryGeneratedXMLPartIsWellFormed() throws {
        let doc = document { _ in
            [
                paragraph(0, "タイトル", style: .title),
                paragraph(1, "本文<>&\"'に特殊文字を含む段落"),
            ]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))
        try assertAllPartsAreWellFormedXML(data)
    }

    func testParagraphTextAppearsInDocumentXML() throws {
        let doc = document { _ in [paragraph(0, "検索できる特徴的な文字列XYZABC")] }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = String(data: documentXML.data, encoding: .utf8)

        XCTAssertTrue(xmlString?.contains("検索できる特徴的な文字列XYZABC") ?? false)
    }

    func testSpecialCharactersAreXMLEscaped() throws {
        let doc = document { _ in [paragraph(0, "A & B < C > D")] }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))
        try assertAllPartsAreWellFormedXML(data) // would fail to parse if unescaped

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))

        XCTAssertTrue(xmlString.contains("A &amp; B &lt; C &gt; D"))
    }

    func testHeadingStyleMapsToTheExpectedWordStyleID() throws {
        let doc = document { _ in [paragraph(0, "見出し", style: .heading2)] }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))

        XCTAssertTrue(xmlString.contains(#"w:pStyle w:val="Heading2""#))
    }

    func testListItemGetsNumPrReferencingTheRightNumId() throws {
        let doc = document { _ -> [DocumentBlock] in
            let block = DocumentBlock(order: 0, kind: .paragraph)
            block.bodyData = DocumentBody.encode(NSAttributedString(string: "項目", attributes: DocumentBody.defaultAttributes()))
            block.listKind = .numbered
            block.listLevel = 1
            return [block]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))

        XCTAssertTrue(xmlString.contains(#"<w:ilvl w:val="1"/>"#))
        XCTAssertTrue(xmlString.contains(#"<w:numId w:val="2"/>"#), "numbered lists use numId 2 — see DocxWriter.numberingXML")
    }

    func testHyperlinkProducesAWellFormedRelationshipToTheURL() throws {
        let doc = document { _ -> [DocumentBlock] in
            let block = DocumentBlock(order: 0, kind: .paragraph)
            var attrs = DocumentBody.defaultAttributes()
            attrs[.link] = URL(string: "https://studiquo.example/notes")!
            block.bodyData = DocumentBody.encode(NSAttributedString(string: "リンク", attributes: attrs))
            return [block]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))
        try assertAllPartsAreWellFormedXML(data)

        let relsXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/_rels/document.xml.rels" }))
        let relsString = try XCTUnwrap(String(data: relsXML.data, encoding: .utf8))
        XCTAssertTrue(relsString.contains("https://studiquo.example/notes"))
        XCTAssertTrue(relsString.contains("TargetMode=\"External\""))

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let documentString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))
        XCTAssertTrue(documentString.contains("<w:hyperlink r:id="))
    }

    /// Two runs linking to the *same* URL must share one relationship, not
    /// mint a duplicate — a real risk given each run is processed
    /// independently.
    func testRepeatedLinksToTheSameURLShareOneRelationship() throws {
        let doc = document { _ -> [DocumentBlock] in
            let url = URL(string: "https://example.com")!
            var attrs = DocumentBody.defaultAttributes()
            attrs[.link] = url
            let first = DocumentBlock(order: 0, kind: .paragraph)
            first.bodyData = DocumentBody.encode(NSAttributedString(string: "1つ目", attributes: attrs))
            let second = DocumentBlock(order: 1, kind: .paragraph)
            second.bodyData = DocumentBody.encode(NSAttributedString(string: "2つ目", attributes: attrs))
            return [first, second]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let relsXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/_rels/document.xml.rels" }))
        let relsString = try XCTUnwrap(String(data: relsXML.data, encoding: .utf8))
        let occurrences = relsString.components(separatedBy: "https://example.com").count - 1
        XCTAssertEqual(occurrences, 1, "the URL should appear in exactly one relationship, reused by both runs")
    }

    func testTableProducesGridSpanForAMergedCell() throws {
        let doc = document { _ -> [DocumentBlock] in
            let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 3)
            table.mergeCellWithRight(row: table.sortedTableRows[0], cellIndex: 0)
            return [table]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))
        try assertAllPartsAreWellFormedXML(data)

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains(#"<w:gridSpan w:val="2"/>"#))
    }

    func testBoldItalicUnderlineStrikethroughProduceTheExpectedRunProperties() throws {
        let doc = document { _ -> [DocumentBlock] in
            let block = DocumentBlock(order: 0, kind: .paragraph)
            var attrs = DocumentBody.defaultAttributes()
            let descriptor = UIFont.systemFont(ofSize: 13).fontDescriptor
                .withSymbolicTraits([.traitBold, .traitItalic]) ?? UIFont.systemFont(ofSize: 13).fontDescriptor
            attrs[.font] = UIFont(descriptor: descriptor, size: 13)
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            block.bodyData = DocumentBody.encode(NSAttributedString(string: "装飾文字", attributes: attrs))
            return [block]
        }
        let data = try XCTUnwrap(DocxWriter.makeDocxData(from: doc))

        let documentXML = try XCTUnwrap(try DocxZip.read(data).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))

        XCTAssertTrue(xmlString.contains("<w:b/>"))
        XCTAssertTrue(xmlString.contains("<w:i/>"))
        XCTAssertTrue(xmlString.contains(#"<w:u w:val="single"/>"#))
        XCTAssertTrue(xmlString.contains("<w:strike/>"))
    }

    func testEquationAndTableOfContentsBlocksAreSkippedRatherThanCrashing() throws {
        let doc = document { _ -> [DocumentBlock] in
            let equation = DocumentBlock(order: 0, kind: .equation)
            equation.equationSource = "x^2"
            let toc = DocumentBlock(order: 1, kind: .tableOfContents)
            let normal = paragraph(2, "本文はちゃんと出る")
            return [equation, toc, normal]
        }

        let data = DocxWriter.makeDocxData(from: doc)

        XCTAssertNotNil(data)
        let documentXML = try XCTUnwrap(try DocxZip.read(data!).first(where: { $0.path == "word/document.xml" }))
        let xmlString = try XCTUnwrap(String(data: documentXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("本文はちゃんと出る"))
    }
}
