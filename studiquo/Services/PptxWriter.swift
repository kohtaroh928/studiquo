import Foundation
import UIKit

/// Converts a `SlideDeck` into real `.pptx` bytes — the OOXML/
/// PresentationML/DrawingML XML parts, zipped via `DocxZip` (a fully
/// generic ZIP reader/writer despite its name — see its doc comment).
///
/// Scope for this first pass, matching `DocxWriter`'s own narrow-first-cut
/// precedent for docx: every slide's *resolved, absolute* `SlideElement`
/// geometry (text/image/rectangle/ellipse/line) is written directly as a
/// freeform shape on that slide — this does **not** attempt to recreate
/// this app's own master/placeholder inheritance system as real PowerPoint
/// slide-master placeholders. One fixed, minimal slide master/layout/theme
/// is emitted (required parts for a valid pptx) and every slide's shapes
/// live entirely in the slide's own shape tree, each with its own explicit
/// color rather than a theme reference — so the exported file looks right
/// without the theme itself needing to be a faithful reconstruction of
/// anything. `.group` elements are flattened: their members already store
/// absolute canvas-fraction positions (`SlideElement.moveGroup` adds deltas
/// straight to each member), so the wrapping group carries no extra
/// information PowerPoint needs and is skipped.
///
/// Not yet covered — skipped, not crashing or corrupting the file —
/// animations, slide transitions, and speaker notes; each needs its own
/// additional OOXML parts/relationships beyond what this pass wires up,
/// the same reasoning `DocxWriter` gives for images/headers/footers/etc.
enum PptxWriter {
    /// Standard PowerPoint slide sizes in EMU (914400 per inch) for this
    /// app's two `SlideAspect` cases — 13.333in×7.5in (16:9) and
    /// 10in×7.5in (4:3), matching what PowerPoint itself uses for those
    /// presets.
    private static func slideSizeEMU(for aspect: SlideAspect) -> (width: Int, height: Int) {
        switch aspect {
        case .widescreen: return (12_192_000, 6_858_000)
        case .standard: return (9_144_000, 6_858_000)
        }
    }

    static func makeData(from deck: SlideDeck) -> Data? {
        let (slideWidth, slideHeight) = slideSizeEMU(for: deck.aspect)
        let slides = deck.sortedSlides

        var entries: [DocxZip.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypesXML(slideCount: slides.count).utf8)),
            .init(path: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            .init(path: "ppt/presentation.xml", data: Data(presentationXML(slideCount: slides.count, width: slideWidth, height: slideHeight).utf8)),
            .init(path: "ppt/_rels/presentation.xml.rels", data: Data(presentationRelsXML(slideCount: slides.count).utf8)),
            .init(path: "ppt/slideMasters/slideMaster1.xml", data: Data(slideMasterXML.utf8)),
            .init(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data(slideMasterRelsXML.utf8)),
            .init(path: "ppt/slideLayouts/slideLayout1.xml", data: Data(slideLayoutXML.utf8)),
            .init(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data(slideLayoutRelsXML.utf8)),
            .init(path: "ppt/theme/theme1.xml", data: Data(themeXML.utf8)),
        ]

        var mediaIndex = 0
        for (slideIndex, slide) in slides.enumerated() {
            let slideNumber = slideIndex + 1
            var mediaRelationships: [(rID: String, path: String)] = []
            let shapesXML = slide.sortedElements.compactMap { element -> String? in
                shapeXML(
                    for: element, slideWidth: slideWidth, slideHeight: slideHeight,
                    mediaIndex: &mediaIndex, mediaRelationships: &mediaRelationships, entries: &entries
                )
            }.joined(separator: "\n")

            let backgroundHex = deck.master?.backgroundColorHex
            entries.append(.init(
                path: "ppt/slides/slide\(slideNumber).xml",
                data: Data(slideXML(shapes: shapesXML, backgroundHex: backgroundHex).utf8)
            ))
            entries.append(.init(
                path: "ppt/slides/_rels/slide\(slideNumber).xml.rels",
                data: Data(slideRelsXML(mediaRelationships: mediaRelationships).utf8)
            ))
        }

        return try? DocxZip.write(entries)
    }

    // MARK: One slide's shape tree

    /// One `<p:sp>`/`<p:pic>` per element, or `nil` for a kind this pass
    /// doesn't export (`.group` — its members are exported individually
    /// instead, so the group wrapper itself would be redundant; an image
    /// element whose data can't actually be decoded).
    private static func shapeXML(
        for element: SlideElement, slideWidth: Int, slideHeight: Int,
        mediaIndex: inout Int, mediaRelationships: inout [(rID: String, path: String)],
        entries: inout [DocxZip.Entry]
    ) -> String? {
        let id = ObjectIdentifier(element).hashValue // uniqueness only, PowerPoint doesn't care about the actual value
        let shapeID = abs(id) % 1_000_000 + 2
        let xfrm = xfrmXML(for: element, slideWidth: slideWidth, slideHeight: slideHeight)

        switch element.kind {
        case .group:
            return nil
        case .text:
            return textShapeXML(element, shapeID: shapeID, xfrm: xfrm)
        case .rectangle:
            return outlinedShapeXML(element, shapeID: shapeID, xfrm: xfrm, preset: "rect")
        case .ellipse:
            return outlinedShapeXML(element, shapeID: shapeID, xfrm: xfrm, preset: "ellipse")
        case .line:
            return filledShapeXML(element, shapeID: shapeID, xfrm: xfrm)
        case .image:
            guard let data = element.imageData, let image = UIImage(data: data), let pngData = image.pngData() else { return nil }
            mediaIndex += 1
            let mediaPath = "ppt/media/image\(mediaIndex).png"
            entries.append(.init(path: mediaPath, data: pngData))
            let rID = "rId\(mediaRelationships.count + 2)" // rId1 is always the slide layout
            mediaRelationships.append((rID: rID, path: "../media/image\(mediaIndex).png"))
            return pictureXML(shapeID: shapeID, xfrm: xfrm, rID: rID)
        }
    }

    private static func xfrmXML(for element: SlideElement, slideWidth: Int, slideHeight: Int) -> String {
        let cx = max(1, Int(element.width * Double(slideWidth)))
        let cy = max(1, Int(element.height * Double(slideHeight)))
        let x = Int(element.centerX * Double(slideWidth)) - cx / 2
        let y = Int(element.centerY * Double(slideHeight)) - cy / 2
        // 60,000ths of a degree, matching `element.rotation`'s clockwise-
        // degrees convention (SwiftUI's `.rotationEffect` and PowerPoint's
        // `rot` both treat positive as clockwise in a y-down space).
        let rotationRaw = Int(element.rotation * 60000) % 21_600_000
        let rot = rotationRaw < 0 ? rotationRaw + 21_600_000 : rotationRaw
        let rotAttr = rot == 0 ? "" : " rot=\"\(rot)\""
        return "<a:xfrm\(rotAttr)><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
    }

    private static func textShapeXML(_ element: SlideElement, shapeID: Int, xfrm: String) -> String {
        """
        <p:sp>
        <p:nvSpPr><p:cNvPr id="\(shapeID)" name="TextBox \(shapeID)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr>\(xfrm)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphsXML(element.body))</p:txBody>
        </p:sp>
        """
    }

    /// Stroke-only, matching how `.rectangle`/`.ellipse` actually render
    /// in-app (`EditableSlideElement.elementContent`'s `.stroke(...)`, not
    /// a fill).
    private static func outlinedShapeXML(_ element: SlideElement, shapeID: Int, xfrm: String, preset: String) -> String {
        let lineEMU = max(1, Int(element.lineWidth * 12700)) // points → EMU
        return """
        <p:sp>
        <p:nvSpPr><p:cNvPr id="\(shapeID)" name="Shape \(shapeID)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr>\(xfrm)<a:prstGeom prst="\(preset)"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="\(lineEMU)"><a:solidFill><a:srgbClr val="\(hexValue(element.colorHex))"/></a:solidFill></a:ln></p:spPr>
        </p:sp>
        """
    }

    /// A `.line` element renders in-app as a thin *filled* bar
    /// (`Rectangle().fill(color)`), not a stroked diagonal connector, so a
    /// filled rect with no outline reproduces it exactly rather than
    /// mapping to PowerPoint's own `prst="line"` (a corner-to-corner
    /// diagonal) which would look wrong.
    private static func filledShapeXML(_ element: SlideElement, shapeID: Int, xfrm: String) -> String {
        """
        <p:sp>
        <p:nvSpPr><p:cNvPr id="\(shapeID)" name="Shape \(shapeID)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr>\(xfrm)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(hexValue(element.colorHex))"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
        </p:sp>
        """
    }

    private static func pictureXML(shapeID: Int, xfrm: String, rID: String) -> String {
        """
        <p:pic>
        <p:nvPicPr><p:cNvPr id="\(shapeID)" name="Picture \(shapeID)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="\(rID)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        <p:spPr>\(xfrm)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        </p:pic>
        """
    }

    // MARK: Text paragraphs/runs

    /// One `<a:p>` per paragraph in `text`, using `SlideListText.markers`
    /// to find paragraph boundaries and `listKind`/`listLevel` to decide
    /// bullet/number formatting — the same source of truth the in-app
    /// renderer (`SlideListText.renderedForDisplay`) reads, so a list that
    /// looks right in the editor looks right in the exported file too.
    private static func paragraphsXML(_ text: NSAttributedString) -> String {
        guard text.length > 0 else { return "<a:p><a:endParaRPr/></a:p>" }
        return SlideListText.markers(for: text).map { entry -> String in
            let (range, _) = entry
            let kind = SlideListText.listKind(at: range.location, in: text)
            let level = SlideListText.listLevel(at: range.location, in: text)
            let pPr = paragraphPropertiesXML(kind: kind, level: level)

            var runRange = range
            let rangeString = (text.string as NSString).substring(with: range)
            if rangeString.hasSuffix("\n") { runRange.length -= 1 }

            guard runRange.length > 0 else { return "<a:p>\(pPr)<a:endParaRPr/></a:p>" }
            let paragraphText = text.attributedSubstring(from: runRange)
            let runsXML = runs(of: paragraphText).map(runXML).joined()
            return "<a:p>\(pPr)\(runsXML)</a:p>"
        }.joined(separator: "\n")
    }

    private static func paragraphPropertiesXML(kind: DocumentListKind?, level: Int) -> String {
        guard let kind else { return "" }
        let indentEMU = 228600 + level * 228600 // ~0.25in per level
        let bullet: String
        switch kind {
        case .bulleted:
            let glyphs = ["•", "◦", "▪"]
            bullet = "<a:buChar char=\"\(glyphs[min(level, glyphs.count - 1)])\"/>"
        case .numbered:
            bullet = "<a:buAutoNum type=\"arabicPeriod\"/>"
        }
        return "<a:pPr marL=\"\(indentEMU)\" indent=\"-228600\" lvl=\"\(min(level, 8))\">\(bullet)</a:pPr>"
    }

    private struct Run {
        let text: String
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let colorHex: String?
        let fontSize: CGFloat?
    }

    private static func runs(of text: NSAttributedString) -> [Run] {
        guard text.length > 0 else { return [] }
        var result: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let substring = (text.string as NSString).substring(with: range)
            guard !substring.isEmpty else { return }
            let font = attributes[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let color = (attributes[.foregroundColor] as? UIColor).map { $0.toHex() }
            result.append(Run(
                text: substring,
                bold: traits.contains(.traitBold),
                italic: traits.contains(.traitItalic),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                colorHex: color,
                fontSize: font?.pointSize
            ))
        }
        return result
    }

    private static func runXML(_ run: Run) -> String {
        var rPr = ""
        if run.bold { rPr += " b=\"1\"" }
        if run.italic { rPr += " i=\"1\"" }
        if run.underline { rPr += " u=\"sng\"" }
        if let fontSize = run.fontSize { rPr += " sz=\"\(Int(fontSize * 100))\"" }
        var rPrInner = ""
        if let colorHex = run.colorHex {
            rPrInner = "<a:solidFill><a:srgbClr val=\"\(hexValue(colorHex))\"/></a:solidFill>"
        }
        let rPrXML = rPrInner.isEmpty ? "<a:rPr\(rPr) dirty=\"0\"/>" : "<a:rPr\(rPr) dirty=\"0\">\(rPrInner)</a:rPr>"
        return "<a:r>\(rPrXML)<a:t>\(xmlEscape(run.text))</a:t></a:r>"
    }

    // MARK: [Content_Types].xml, root/presentation rels

    private static func contentTypesXML(slideCount: Int) -> String {
        let slideOverrides = (1...max(slideCount, 0)).map {
            "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(slideOverrides)
        </Types>
        """
    }

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
    </Relationships>
    """

    private static func presentationXML(slideCount: Int, width: Int, height: Int) -> String {
        let slideIdList = (0..<slideCount).map { index in
            "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 2)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(slideIdList)</p:sldIdLst>
        <p:sldSz cx="\(width)" cy="\(height)"/>
        </p:presentation>
        """
    }

    private static func presentationRelsXML(slideCount: Int) -> String {
        let slideRels = (0..<slideCount).map { index in
            "<Relationship Id=\"rId\(index + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(index + 1).xml\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        \(slideRels)
        </Relationships>
        """
    }

    // MARK: Fixed master/layout/theme parts

    private static let slideMasterXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
    <p:cSld>
    <p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
    </p:spTree>
    </p:cSld>
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
    <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
    </p:sldMaster>
    """

    private static let slideMasterRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
    </Relationships>
    """

    private static let slideLayoutXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
    <p:cSld name="Blank">
    <p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
    </p:spTree>
    </p:cSld>
    <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
    </p:sldLayout>
    """

    private static let slideLayoutRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
    </Relationships>
    """

    /// A standard, fixed "Office" theme — used purely to satisfy the OOXML
    /// requirement that a theme part exists and is well-formed. Every shape
    /// and text run this writer emits sets its own explicit `srgbClr`
    /// rather than referencing a scheme color, so this theme's own palette
    /// never actually shows up anywhere — nothing here needs to reflect the
    /// deck's real colors.
    private static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office">
    <a:themeElements>
    <a:clrScheme name="Office">
    <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
    <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
    <a:dk2><a:srgbClr val="44546A"/></a:dk2>
    <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
    <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
    <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
    <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
    <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
    <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
    <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
    <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
    <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="Office">
    <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
    <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="Office">
    <a:fillStyleLst>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    </a:fillStyleLst>
    <a:lnStyleLst>
    <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
    <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
    <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
    </a:lnStyleLst>
    <a:effectStyleLst>
    <a:effectStyle><a:effectLst/></a:effectStyle>
    <a:effectStyle><a:effectLst/></a:effectStyle>
    <a:effectStyle><a:effectLst/></a:effectStyle>
    </a:effectStyleLst>
    <a:bgFillStyleLst>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
    </a:bgFillStyleLst>
    </a:fmtScheme>
    </a:themeElements>
    </a:theme>
    """

    // MARK: One slide's own XML/rels

    private static func slideXML(shapes: String, backgroundHex: String?) -> String {
        let backgroundXML = backgroundHex.map {
            "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(hexValue($0))\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        \(backgroundXML)
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        \(shapes)
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func slideRelsXML(mediaRelationships: [(rID: String, path: String)]) -> String {
        let mediaRels = mediaRelationships.map {
            "<Relationship Id=\"\($0.rID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\($0.path)\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        \(mediaRels)
        </Relationships>
        """
    }

    // MARK: Helpers

    /// `element.colorHex` is always stored with a leading `#`
    /// (`"#1C1C1E"`); DrawingML's `val=` attribute wants the six hex
    /// digits alone.
    private static func hexValue(_ hex: String) -> String {
        hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    }

    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
