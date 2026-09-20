import Foundation
import UIKit

/// Converts real `.pptx` bytes into `Slide`s (with their `SlideElement`s
/// already attached) — the reverse of `PptxWriter`, and the harder
/// direction for the same reason `DocxReader` is harder than `DocxWriter`:
/// this has to cope with whatever a real pptx (from actual PowerPoint, or
/// any other tool) contains, not just what this app itself would emit.
///
/// Scope matches `PptxWriter`'s: text boxes (bold/italic/underline/color/
/// size, bulleted/numbered lists), rectangles/ellipses/lines, and images —
/// each read as its own free-floating `SlideElement` with fully-resolved
/// absolute geometry (`sourcePlaceholder` always `nil`; this doesn't try to
/// reconstruct the source file's own master/layout/placeholder structure
/// into this app's inheritance system, matching `PptxWriter`'s own
/// decision not to build one on export either). Anything this doesn't
/// recognize — grouped shapes, tables/charts (`graphicFrame`), connector
/// lines, animations, transitions, speaker notes — is dropped, but never
/// *silently*: `Result.droppedElementKinds` records what kind of thing was
/// found and skipped, matching `DocxReader.droppedElementKinds`'s policy.
enum PptxReader {
    enum ReadError: Error, Equatable {
        case notAPptx
        case missingPresentationPart
    }

    struct Result {
        let slides: [Slide]
        let aspect: SlideAspect
        /// One entry per occurrence, human-readable kind — see the type's
        /// doc comment. Grouped/counted the same way the docx import UI
        /// already does with `DocxReader.Result.droppedElementKinds`.
        let droppedElementKinds: [String]
    }

    static func read(from data: Data) throws -> Result {
        let entries: [DocxZip.Entry]
        do {
            entries = try DocxZip.read(data)
        } catch {
            throw ReadError.notAPptx
        }
        guard let presentationEntry = entries.first(where: { $0.path == "ppt/presentation.xml" }) else {
            throw ReadError.missingPresentationPart
        }

        let presentationDelegate = PresentationXMLDelegate()
        let presentationParser = XMLParser(data: presentationEntry.data)
        presentationParser.delegate = presentationDelegate
        _ = presentationParser.parse()

        let presentationRels = parseRelationships(entries, at: "ppt/_rels/presentation.xml.rels")
        let aspect = closestAspect(width: presentationDelegate.slideWidth, height: presentationDelegate.slideHeight)

        var slides: [Slide] = []
        var dropped: [String] = []

        for (order, rID) in presentationDelegate.slideRIDsInOrder.enumerated() {
            guard let target = presentationRels[rID] else { continue }
            let slidePath = resolvePath(basePath: "ppt/presentation.xml", relativeTarget: target)
            guard let slideEntry = entries.first(where: { $0.path == slidePath }) else { continue }

            let slideFileName = (slidePath as NSString).lastPathComponent
            let slideRelsPath = "ppt/slides/_rels/\(slideFileName).rels"
            let slideRels = parseRelationships(entries, at: slideRelsPath)

            let slideDelegate = SlideXMLDelegate()
            let slideParser = XMLParser(data: slideEntry.data)
            slideParser.delegate = slideDelegate
            _ = slideParser.parse() // best-effort, matching DocxReader

            let slide = Slide(order: order)
            for parsedShape in slideDelegate.shapes {
                if let element = makeSlideElement(
                    from: parsedShape, slideWidth: presentationDelegate.slideWidth,
                    slideHeight: presentationDelegate.slideHeight, slideRels: slideRels, entries: entries
                ) {
                    slide.addElement(element)
                }
            }
            dropped.append(contentsOf: slideDelegate.droppedElementKinds)
            slides.append(slide)
        }

        return Result(slides: slides, aspect: aspect, droppedElementKinds: dropped)
    }

    /// Picks whichever of this app's two supported aspect ratios the
    /// source file's own `<p:sldSz>` is closer to — pptx can in principle
    /// declare any size, but this app's canvas only has the two presets.
    private static func closestAspect(width: Int, height: Int) -> SlideAspect {
        guard width > 0, height > 0 else { return .widescreen }
        let ratio = Double(width) / Double(height)
        let widescreenDistance = abs(ratio - 16.0 / 9.0)
        let standardDistance = abs(ratio - 4.0 / 3.0)
        return widescreenDistance <= standardDistance ? .widescreen : .standard
    }

    /// Resolves a relationship `Target` (always relative to the part that
    /// declared it, per OOXML convention — `../media/image1.png` from
    /// `ppt/slides/slide1.xml` means `ppt/media/image1.png`) against the
    /// zip's own flat entry paths. A naive `"ppt/" + target` (stripping
    /// only the literal `"../"` substring) gets this wrong for any target
    /// that climbs more than one directory, or that doesn't climb at all.
    private static func resolvePath(basePath: String, relativeTarget: String) -> String {
        var components = basePath.split(separator: "/").map(String.init)
        components.removeLast() // the part itself, not a directory
        for segment in relativeTarget.split(separator: "/") {
            switch segment {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(segment))
            }
        }
        return components.joined(separator: "/")
    }

    private static func parseRelationships(_ entries: [DocxZip.Entry], at path: String) -> [String: String] {
        guard let entry = entries.first(where: { $0.path == path }) else { return [:] }
        let delegate = RelationshipsXMLDelegate()
        let parser = XMLParser(data: entry.data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.relationships
    }

    // MARK: Parsed shape → SlideElement

    private static func makeSlideElement(
        from shape: ParsedShape, slideWidth: Int, slideHeight: Int,
        slideRels: [String: String], entries: [DocxZip.Entry]
    ) -> SlideElement? {
        guard slideWidth > 0, slideHeight > 0 else { return nil }
        let centerX = (Double(shape.offX) + Double(shape.extCX) / 2) / Double(slideWidth)
        let centerY = (Double(shape.offY) + Double(shape.extCY) / 2) / Double(slideHeight)
        let width = Double(shape.extCX) / Double(slideWidth)
        let height = Double(shape.extCY) / Double(slideHeight)
        let rotation = Double(shape.rot) / 60000.0

        let element: SlideElement
        if shape.isPicture {
            guard let rID = shape.imageRID, let target = slideRels[rID] else { return nil }
            let mediaPath = resolvePath(basePath: "ppt/slides/slide.xml", relativeTarget: target)
            guard let mediaEntry = entries.first(where: { $0.path == mediaPath }) else { return nil }
            element = SlideElement(kind: .image)
            element.imageData = mediaEntry.data
        } else if hasReadableText(shape) {
            element = SlideElement(kind: .text)
            element.body = attributedString(from: shape.paragraphs)
        } else if shape.prstGeom == "rect" {
            element = SlideElement(kind: .rectangle)
            element.colorHex = "#" + (shape.lineHex ?? shape.fillHex ?? "1C1C1E")
            element.lineWidth = Double(shape.lineWidthEMU) / 12700
        } else if shape.prstGeom == "ellipse" {
            element = SlideElement(kind: .ellipse)
            element.colorHex = "#" + (shape.lineHex ?? shape.fillHex ?? "1C1C1E")
            element.lineWidth = Double(shape.lineWidthEMU) / 12700
        } else if shape.prstGeom == "line" {
            element = SlideElement(kind: .line)
            element.colorHex = "#" + (shape.fillHex ?? shape.lineHex ?? "1C1C1E")
            element.lineWidth = Double(shape.lineWidthEMU) / 12700
        } else {
            return nil // reported as "図形" by the caller via droppedElementKinds
        }

        element.overrideCenterX = centerX
        element.overrideCenterY = centerY
        element.overrideWidth = max(0.01, width)
        element.overrideHeight = max(0.01, height)
        element.overrideRotation = rotation
        return element
    }

    private static func hasReadableText(_ shape: ParsedShape) -> Bool {
        shape.paragraphs.contains { !$0.runs.isEmpty && $0.runs.contains { !$0.text.isEmpty } }
    }

    private static func attributedString(from paragraphs: [ParsedParagraph]) -> NSAttributedString {
        guard !paragraphs.isEmpty else {
            return NSAttributedString(string: "", attributes: DocumentBody.defaultAttributes())
        }
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let start = result.length
            if paragraph.runs.isEmpty {
                result.append(NSAttributedString(string: "", attributes: DocumentBody.defaultAttributes()))
            }
            for run in paragraph.runs {
                var attributes = DocumentBody.defaultAttributes()
                var traits: UIFontDescriptor.SymbolicTraits = []
                if run.bold { traits.insert(.traitBold) }
                if run.italic { traits.insert(.traitItalic) }
                let size = run.fontSize ?? 18
                if !traits.isEmpty, let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits) {
                    attributes[.font] = UIFont(descriptor: descriptor, size: size)
                } else {
                    attributes[.font] = UIFont.systemFont(ofSize: size)
                }
                if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if let hex = run.colorHex { attributes[.foregroundColor] = UIColor(inkHex: hex) }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            if index < paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: DocumentBody.defaultAttributes()))
            }
            if let kind = paragraph.listKind {
                let paragraphRange = NSRange(location: start, length: result.length - start)
                SlideListText.setListKind(kind, level: paragraph.level, forRange: paragraphRange, in: result)
            }
        }
        return result
    }
}

// MARK: - Intermediate representation

private struct ParsedRun {
    var text = ""
    var bold = false
    var italic = false
    var underline = false
    var colorHex: String?
    var fontSize: Double?
}

private struct ParsedParagraph {
    var runs: [ParsedRun] = []
    var listKind: DocumentListKind?
    var level = 0
}

private struct ParsedShape {
    var prstGeom: String?
    var offX = 0, offY = 0, extCX = 0, extCY = 0, rot = 0
    var fillHex: String?
    var lineHex: String?
    var lineWidthEMU = 12700
    var paragraphs: [ParsedParagraph] = []
    var isPicture = false
    var imageRID: String?
}

// MARK: - ppt/presentation.xml parsing

private final class PresentationXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var slideWidth = 0
    private(set) var slideHeight = 0
    private(set) var slideRIDsInOrder: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "p:sldSz":
            slideWidth = attributeDict["cx"].flatMap(Int.init) ?? 0
            slideHeight = attributeDict["cy"].flatMap(Int.init) ?? 0
        case "p:sldId":
            if let rID = attributeDict["r:id"] { slideRIDsInOrder.append(rID) }
        default:
            break
        }
    }
}

// MARK: - */_rels/*.rels parsing (shared shape — root/presentation/slide rels all look the same)

private final class RelationshipsXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var relationships: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}

// MARK: - ppt/slides/slideN.xml parsing

/// A SAX-style walk of one slide's shape tree. Matches element names by
/// their literal `p:`/`a:`/`r:` prefix, the same accepted simplification
/// `DocxReader` documents for `w:`/`r:` — every real-world pptx (from
/// PowerPoint or any other tool, including `PptxWriter`) uses these exact
/// prefixes verbatim.
private final class SlideXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var shapes: [ParsedShape] = []
    private(set) var droppedElementKinds: [String] = []

    private var elementStack: [String] = []
    private var shapeInProgress: ParsedShape?
    private var paragraphInProgress: ParsedParagraph?
    private var runInProgress: ParsedRun?
    private var textBuffer = ""
    private var insideLn = false
    private var fillContextStack: [FillContext] = []

    private enum FillContext { case shape, line, run }

    /// Depth-tracked skip for an entire unsupported subtree (`p:grpSp`,
    /// `p:graphicFrame`, `p:cxnSp`) — everything inside is ignored, however
    /// deeply nested, until the matching close tag for the element that
    /// started the skip.
    private var skippingElementName: String?
    private var skippingDepth = 0

    private static let skipTriggers: [String: String] = [
        "p:grpSp": "グループ図形",
        "p:graphicFrame": "表・グラフ",
        "p:cxnSp": "コネクタ",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)

        if skippingElementName != nil {
            return
        }
        if let kind = Self.skipTriggers[elementName] {
            skippingElementName = elementName
            skippingDepth = elementStack.count
            droppedElementKinds.append(kind)
            return
        }

        switch elementName {
        case "p:timing":
            droppedElementKinds.append("アニメーション")
        case "p:transition":
            droppedElementKinds.append("画面切り替え")
        case "p:sp":
            shapeInProgress = ParsedShape()
        case "p:pic":
            shapeInProgress = ParsedShape()
            shapeInProgress?.isPicture = true
        case "a:xfrm":
            if let rot = attributeDict["rot"].flatMap(Int.init) { shapeInProgress?.rot = rot }
        case "a:off":
            shapeInProgress?.offX = attributeDict["x"].flatMap(Int.init) ?? 0
            shapeInProgress?.offY = attributeDict["y"].flatMap(Int.init) ?? 0
        case "a:ext":
            shapeInProgress?.extCX = attributeDict["cx"].flatMap(Int.init) ?? 0
            shapeInProgress?.extCY = attributeDict["cy"].flatMap(Int.init) ?? 0
        case "a:prstGeom":
            shapeInProgress?.prstGeom = attributeDict["prst"]
        case "a:blip":
            shapeInProgress?.imageRID = attributeDict["r:embed"]
        case "a:ln":
            insideLn = true
            if let width = attributeDict["w"].flatMap(Int.init) { shapeInProgress?.lineWidthEMU = width }
        case "a:solidFill":
            fillContextStack.append(runInProgress != nil ? .run : (insideLn ? .line : .shape))
        case "a:srgbClr":
            guard let value = attributeDict["val"] else { break }
            switch fillContextStack.last {
            case .run: runInProgress?.colorHex = value
            case .line: shapeInProgress?.lineHex = value
            case .shape: shapeInProgress?.fillHex = value
            case nil: break
            }
        case "a:p":
            paragraphInProgress = ParsedParagraph()
        case "a:pPr":
            if let lvl = attributeDict["lvl"].flatMap(Int.init) { paragraphInProgress?.level = lvl }
        case "a:buChar":
            paragraphInProgress?.listKind = .bulleted
        case "a:buAutoNum":
            paragraphInProgress?.listKind = .numbered
        case "a:r":
            runInProgress = ParsedRun()
        case "a:rPr":
            runInProgress?.bold = attributeDict["b"] == "1"
            runInProgress?.italic = attributeDict["i"] == "1"
            runInProgress?.underline = (attributeDict["u"] ?? "none") != "none"
            if let sz = attributeDict["sz"].flatMap(Int.init) { runInProgress?.fontSize = Double(sz) / 100 }
        case "a:t":
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elementStack.last == "a:t" { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if elementStack.last == elementName { elementStack.removeLast() } }

        if let skippingElementName {
            if elementName == skippingElementName, elementStack.count == skippingDepth {
                self.skippingElementName = nil
            }
            return
        }

        switch elementName {
        case "a:t":
            runInProgress?.text += textBuffer
        case "a:r":
            if let run = runInProgress { paragraphInProgress?.runs.append(run) }
            runInProgress = nil
        case "a:solidFill":
            if !fillContextStack.isEmpty { fillContextStack.removeLast() }
        case "a:ln":
            insideLn = false
        case "a:p":
            if let paragraph = paragraphInProgress { shapeInProgress?.paragraphs.append(paragraph) }
            paragraphInProgress = nil
        case "p:sp", "p:pic":
            if let shape = shapeInProgress {
                if shape.isPicture, shape.imageRID == nil {
                    // A picture shape with no actual image reference is
                    // malformed enough that there's nothing useful to keep.
                    break
                }
                if !shape.isPicture, !hasContent(shape) {
                    droppedElementKinds.append("図形")
                    break
                }
                shapes.append(shape)
            }
            shapeInProgress = nil
        default:
            break
        }
    }

    /// A non-picture shape is worth keeping only if it has actual text, or
    /// is one of the three presets `PptxReader` knows how to turn into a
    /// rectangle/ellipse/line `SlideElement` — anything else (a star, an
    /// arrow, a custom freeform path, …) is reported as an unsupported
    /// shape rather than silently approximated as a plain rectangle.
    private func hasContent(_ shape: ParsedShape) -> Bool {
        let hasText = shape.paragraphs.contains { !$0.runs.isEmpty && $0.runs.contains { !$0.text.isEmpty } }
        let isKnownPreset = shape.prstGeom == "rect" || shape.prstGeom == "ellipse" || shape.prstGeom == "line"
        return hasText || isKnownPreset
    }
}
