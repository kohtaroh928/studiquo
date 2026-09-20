import XCTest
@testable import studiquo

/// Coverage for `PptxWriter`, mirroring `DocxWriterTests`' own approach:
/// build a deck programmatically, generate `.pptx` bytes, and assert on
/// the resulting ZIP/XML structure directly. Unlike `DocxWriterTests`,
/// this output has *not* been independently validated by an external
/// OOXML library — there's no equivalent of `python-docx` available in
/// this environment — so these structural checks (every part present,
/// every part well-formed XML, specific attributes in the right place)
/// are the only verification this writer has had.
final class PptxWriterTests: XCTestCase {
    private func deck(aspect: SlideAspect = .widescreen, _ build: (SlideDeck) -> [Slide]) -> SlideDeck {
        let deck = SlideDeck(title: "テスト")
        deck.aspectRawValue = aspect.rawValue
        deck.master = SlideMaster.makeDefault()
        let slides = build(deck)
        for slide in slides { slide.deck = deck }
        deck.slides = slides
        return deck
    }

    private func textElement(_ text: String, layerIndex: Double = 0) -> SlideElement {
        let element = SlideElement(kind: .text, layerIndex: layerIndex)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        element.body = NSAttributedString(string: text, attributes: element.defaultTextAttributes())
        return element
    }

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
        let slide = Slide(order: 0)
        slide.addElement(textElement("本文"))
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let paths = Set(try DocxZip.read(data).map(\.path))
        for required in [
            "[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels",
            "ppt/slideMasters/slideMaster1.xml", "ppt/slideLayouts/slideLayout1.xml", "ppt/theme/theme1.xml",
            "ppt/slides/slide1.xml", "ppt/slides/_rels/slide1.xml.rels",
        ] {
            XCTAssertTrue(paths.contains(required), "missing required part: \(required)")
        }
    }

    func testEveryGeneratedXMLPartIsWellFormedIncludingWithSpecialCharacters() throws {
        let slide = Slide(order: 0)
        slide.addElement(textElement("本文<>&\"'に特殊文字を含む"))
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        try assertAllPartsAreWellFormedXML(data)
    }

    func testOneSlidePartPerSlideInTheDeckInOrder() throws {
        let first = Slide(order: 0)
        first.addElement(textElement("最初のスライド"))
        let second = Slide(order: 1)
        second.addElement(textElement("2枚目のスライド"))
        let source = deck { _ in [first, second] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let paths = Set(try DocxZip.read(data).map(\.path))
        XCTAssertTrue(paths.contains("ppt/slides/slide1.xml"))
        XCTAssertTrue(paths.contains("ppt/slides/slide2.xml"))

        let slide1 = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let slide1String = try XCTUnwrap(String(data: slide1.data, encoding: .utf8))
        XCTAssertTrue(slide1String.contains("最初のスライド"))
        XCTAssertFalse(slide1String.contains("2枚目のスライド"))
    }

    func testPresentationXMLDeclaresTheWidescreenSlideSize() throws {
        let slide = Slide(order: 0)
        let source = deck(aspect: .widescreen) { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let presentationXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/presentation.xml" })
        let xmlString = try XCTUnwrap(String(data: presentationXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains(#"cx="12192000" cy="6858000""#))
    }

    func testTextElementBecomesATextBoxShapeWithItsText() throws {
        let slide = Slide(order: 0)
        slide.addElement(textElement("検索できる特徴的な文字列XYZABC"))
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("txBox=\"1\""))
        XCTAssertTrue(xmlString.contains("検索できる特徴的な文字列XYZABC"))
    }

    func testBoldItalicUnderlineProduceTheExpectedRunProperties() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        let descriptor = UIFont.systemFont(ofSize: 18).fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? UIFont.systemFont(ofSize: 18).fontDescriptor
        var attrs: [NSAttributedString.Key: Any] = [.font: UIFont(descriptor: descriptor, size: 18)]
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        element.body = NSAttributedString(string: "装飾文字", attributes: attrs)
        slide.addElement(element)
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("b=\"1\""))
        XCTAssertTrue(xmlString.contains("i=\"1\""))
        XCTAssertTrue(xmlString.contains("u=\"sng\""))
        XCTAssertTrue(xmlString.contains("sz=\"1800\""))
    }

    func testBulletedListParagraphGetsABuCharAndUnnumberedGetsNone() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.4
        let body = NSMutableAttributedString(string: "箇条書き1\n普通の段落")
        SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: 0, length: 5), in: body)
        element.body = body
        slide.addElement(element)
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("<a:buChar char=\"•\"/>"))
        XCTAssertTrue(xmlString.contains("箇条書き1"))
        XCTAssertTrue(xmlString.contains("普通の段落"))
    }

    func testRectangleAndEllipseAreStrokeOnlyMatchingHowTheyRenderInApp() throws {
        let slide = Slide(order: 0)
        let rect = SlideElement(kind: .rectangle)
        rect.overrideCenterX = 0.3; rect.overrideCenterY = 0.3; rect.overrideWidth = 0.2; rect.overrideHeight = 0.2
        rect.colorHex = "#FF3B30"
        slide.addElement(rect)
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("prst=\"rect\""))
        XCTAssertTrue(xmlString.contains("<a:noFill/>"))
        XCTAssertTrue(xmlString.contains("FF3B30"))
    }

    func testImageElementBecomesAPictureWithAMediaRelationship() throws {
        let slide = Slide(order: 0)
        let image = SlideElement(kind: .image)
        image.overrideCenterX = 0.5; image.overrideCenterY = 0.5; image.overrideWidth = 0.4; image.overrideHeight = 0.4
        let uiImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        image.imageData = uiImage.pngData()
        slide.addElement(image)
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let entries = try DocxZip.read(data)
        XCTAssertTrue(entries.contains { $0.path == "ppt/media/image1.png" })

        let slideRels = try XCTUnwrap(entries.first { $0.path == "ppt/slides/_rels/slide1.xml.rels" })
        let relsString = try XCTUnwrap(String(data: slideRels.data, encoding: .utf8))
        XCTAssertTrue(relsString.contains("../media/image1.png"))

        let slideXML = try XCTUnwrap(entries.first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("<p:pic>"))
        XCTAssertTrue(xmlString.contains("r:embed="))
    }

    func testGroupElementItselfIsSkippedButItsMembersAreStillExported() throws {
        let slide = Slide(order: 0)
        let member = textElement("グループの中身")
        let otherMember = textElement("もう一つ", layerIndex: 1)
        slide.addElement(member)
        slide.addElement(otherMember)
        let group = slide.group([member, otherMember])
        XCTAssertNotNil(group)
        let source = deck { _ in [slide] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))

        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("グループの中身"))
        // A group has no shape of its own — the number of <p:sp> shapes
        // should equal the member count (2 text boxes), not 3.
        XCTAssertEqual(xmlString.components(separatedBy: "<p:sp>").count - 1, 2)
    }
}
