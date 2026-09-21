import XCTest
@testable import studiquo

/// Coverage for `PptxReader`, mirroring `DocxReaderTests`' own two-pronged
/// approach: round-trip through `PptxWriter` (the two were designed as a
/// matched pair, so this exercises both together the way they'll actually
/// be used), plus hand-written OOXML for cases that deliberately diverge
/// from what `PptxWriter` itself emits — a real pptx, from actual
/// PowerPoint or any other tool, won't always match this app's own writer
/// byte-for-byte.
final class PptxReaderTests: XCTestCase {
    // MARK: Round trip through PptxWriter

    private func deck(aspect: SlideAspect = .widescreen, _ build: (SlideDeck) -> [Slide]) -> SlideDeck {
        let deck = SlideDeck(title: "テスト")
        deck.aspectRawValue = aspect.rawValue
        deck.master = SlideMaster.makeDefault()
        let slides = build(deck)
        for slide in slides { slide.deck = deck }
        deck.slides = slides
        return deck
    }

    func testRoundTripPreservesPlainSlideText() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        element.body = NSAttributedString(string: "これは本文です", attributes: element.defaultTextAttributes())
        slide.addElement(element)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        XCTAssertEqual(result.slides.count, 1)
        let readElement = try XCTUnwrap(result.slides[0].sortedElements.first)
        XCTAssertEqual(readElement.kind, .text)
        XCTAssertEqual(readElement.body.string, "これは本文です")
    }

    func testRoundTripPreservesAspectRatio() throws {
        let source = deck(aspect: .standard) { _ in [Slide(order: 0)] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)
        XCTAssertEqual(result.aspect, .standard)
    }

    func testRoundTripPreservesBoldItalicUnderline() throws {
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
        let result = try PptxReader.read(from: data)

        let readBody = try XCTUnwrap(result.slides.first?.sortedElements.first?.body)
        let font = readBody.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(traits.contains(.traitBold))
        XCTAssertTrue(traits.contains(.traitItalic))
        XCTAssertEqual(readBody.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testRoundTripPreservesBulletedListKindAndLevel() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.4
        let body = NSMutableAttributedString(string: "項目")
        SlideListText.setListKind(.bulleted, level: 1, forRange: NSRange(location: 0, length: body.length), in: body)
        element.body = body
        slide.addElement(element)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        let readBody = try XCTUnwrap(result.slides.first?.sortedElements.first?.body)
        XCTAssertEqual(SlideListText.listKind(at: 0, in: readBody), .bulleted)
        XCTAssertEqual(SlideListText.listLevel(at: 0, in: readBody), 1)
    }

    func testRoundTripPreservesCenterParagraphAlignment() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let body = NSMutableAttributedString(string: "中央揃え")
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        element.body = body
        slide.addElement(element)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        let readBody = try XCTUnwrap(result.slides.first?.sortedElements.first?.body)
        let readStyle = readBody.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(readStyle?.alignment, .center)
    }

    func testLeftAlignmentIsOmittedFromTheExportedXMLSinceItsTheDefault() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        let body = NSMutableAttributedString(string: "左揃え")
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        element.body = body
        slide.addElement(element)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let slideXML = try XCTUnwrap(try DocxZip.read(data).first { $0.path == "ppt/slides/slide1.xml" })
        let xmlString = try XCTUnwrap(String(data: slideXML.data, encoding: .utf8))
        XCTAssertFalse(xmlString.contains("algn="))
    }

    func testRoundTripPreservesRightParagraphAlignment() throws {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text)
        element.overrideCenterX = 0.5; element.overrideCenterY = 0.5
        element.overrideWidth = 0.6; element.overrideHeight = 0.2
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let body = NSMutableAttributedString(string: "右揃え")
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        element.body = body
        slide.addElement(element)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        let readBody = try XCTUnwrap(result.slides.first?.sortedElements.first?.body)
        let readStyle = readBody.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(readStyle?.alignment, .right)
    }

    func testRoundTripPreservesRectangleColorAndGeometry() throws {
        let slide = Slide(order: 0)
        let rect = SlideElement(kind: .rectangle)
        rect.overrideCenterX = 0.3; rect.overrideCenterY = 0.4; rect.overrideWidth = 0.2; rect.overrideHeight = 0.25
        rect.colorHex = "#FF3B30"
        slide.addElement(rect)
        let source = deck { _ in [slide] }

        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        let readElement = try XCTUnwrap(result.slides.first?.sortedElements.first)
        XCTAssertEqual(readElement.kind, .rectangle)
        XCTAssertEqual(readElement.colorHex.uppercased(), "#FF3B30")
        XCTAssertEqual(readElement.centerX, 0.3, accuracy: 0.001)
        XCTAssertEqual(readElement.centerY, 0.4, accuracy: 0.001)
        XCTAssertEqual(readElement.width, 0.2, accuracy: 0.001)
        XCTAssertEqual(readElement.height, 0.25, accuracy: 0.001)
    }

    func testRoundTripPreservesAnImagesPixelData() throws {
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
        let result = try PptxReader.read(from: data)

        let readElement = try XCTUnwrap(result.slides.first?.sortedElements.first)
        XCTAssertEqual(readElement.kind, .image)
        XCTAssertNotNil(readElement.imageData)
        XCTAssertNotNil(UIImage(data: readElement.imageData ?? Data()))
    }

    func testRoundTripPreservesOrderOfMultipleSlides() throws {
        let first = Slide(order: 0)
        let firstElement = SlideElement(kind: .text)
        firstElement.overrideCenterX = 0.5; firstElement.overrideCenterY = 0.5; firstElement.overrideWidth = 0.6; firstElement.overrideHeight = 0.2
        firstElement.body = NSAttributedString(string: "最初のスライド", attributes: firstElement.defaultTextAttributes())
        first.addElement(firstElement)

        let second = Slide(order: 1)
        let secondElement = SlideElement(kind: .text)
        secondElement.overrideCenterX = 0.5; secondElement.overrideCenterY = 0.5; secondElement.overrideWidth = 0.6; secondElement.overrideHeight = 0.2
        secondElement.body = NSAttributedString(string: "2枚目のスライド", attributes: secondElement.defaultTextAttributes())
        second.addElement(secondElement)

        let source = deck { _ in [first, second] }
        let data = try XCTUnwrap(PptxWriter.makeData(from: source))
        let result = try PptxReader.read(from: data)

        XCTAssertEqual(result.slides.count, 2)
        XCTAssertEqual(result.slides[0].sortedElements.first?.body.string, "最初のスライド")
        XCTAssertEqual(result.slides[1].sortedElements.first?.body.string, "2枚目のスライド")
    }

    // MARK: Robustness against real-world variation (hand-written OOXML)

    private func parseMinimalPptx(slideXML: String, width: Int = 12_192_000, height: Int = 6_858_000) throws -> PptxReader.Result {
        let presentationXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
        <p:sldSz cx="\(width)" cy="\(height)"/>
        </p:presentation>
        """
        let presentationRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
        </Relationships>
        """
        let entries = [
            DocxZip.Entry(path: "ppt/presentation.xml", data: Data(presentationXML.utf8)),
            DocxZip.Entry(path: "ppt/_rels/presentation.xml.rels", data: Data(presentationRelsXML.utf8)),
            DocxZip.Entry(path: "ppt/slides/slide1.xml", data: Data(slideXML.utf8)),
        ]
        let data = try DocxZip.write(entries)
        return try PptxReader.read(from: data)
    }

    func testNonPptxDataThrows() {
        let notAZip = Data("hello".utf8)
        XCTAssertThrowsError(try PptxReader.read(from: notAZip))
    }

    func testMissingPresentationPartThrows() throws {
        let data = try DocxZip.write([DocxZip.Entry(path: "ppt/slides/slide1.xml", data: Data())])
        XCTAssertThrowsError(try PptxReader.read(from: data)) { error in
            XCTAssertEqual(error as? PptxReader.ReadError, .missingPresentationPart)
        }
    }

    func testAGroupedShapeIsDroppedAndReported() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:grpSp><p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr></p:sp></p:grpSp>
        </p:spTree></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        XCTAssertEqual(result.slides[0].sortedElements.count, 0, "the grouped shape's inner <p:sp> must not leak out as a top-level element")
        XCTAssertTrue(result.droppedElementKinds.contains("グループ図形"))
    }

    func testAnUnrecognizedShapePresetIsDroppedAndReportedRatherThanGuessed() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm><a:prstGeom prst="star5"><a:avLst/></a:prstGeom></p:spPr></p:sp>
        </p:spTree></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        XCTAssertEqual(result.slides[0].sortedElements.count, 0)
        XCTAssertTrue(result.droppedElementKinds.contains("図形"))
    }

    func testATableGraphicFrameIsDroppedAndReported() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:graphicFrame><a:graphic><a:graphicData><a:tbl/></a:graphicData></a:graphic></p:graphicFrame>
        </p:spTree></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        XCTAssertEqual(result.slides[0].sortedElements.count, 0)
        XCTAssertTrue(result.droppedElementKinds.contains("表・グラフ"))
    }

    func testAnimationAndTransitionAreDroppedAndReported() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree/></p:cSld>
        <p:transition><p:fade/></p:transition>
        <p:timing/>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        XCTAssertTrue(result.droppedElementKinds.contains("画面切り替え"))
        XCTAssertTrue(result.droppedElementKinds.contains("アニメーション"))
    }

    func testStandardSizedSlideResolvesToTheStandardAspect() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree/></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML, width: 9_144_000, height: 6_858_000)
        XCTAssertEqual(result.aspect, .standard)
    }

    func testExplicitBuNoneIsNotTreatedAsAList() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree>
        <p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        <p:txBody><a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>普通の段落</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        let element = try XCTUnwrap(result.slides[0].sortedElements.first)
        XCTAssertEqual(element.kind, .text)
        XCTAssertNil(SlideListText.listKind(at: 0, in: element.body))
    }

    func testEmptySpTreeProducesASlideWithNoElementsNotACrash() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree/></p:cSld>
        </p:sld>
        """
        let result = try parseMinimalPptx(slideXML: slideXML)
        XCTAssertEqual(result.slides.count, 1)
        XCTAssertEqual(result.slides[0].sortedElements.count, 0)
    }
}
