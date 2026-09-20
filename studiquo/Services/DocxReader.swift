import Foundation
import UIKit

/// Converts real `.docx` bytes into `DocumentBlock`s — the reverse of
/// `DocxWriter`, and the harder direction: `DocxWriter` only ever has to
/// emit XML shaped exactly the way it expects to read it back, but this has
/// to cope with whatever a real docx (from actual Word, or any other tool)
/// actually contains.
///
/// Scope matches `DocxWriter`'s: paragraphs (bold/italic/underline/
/// strikethrough/color, paragraph styles, alignment, hyperlinks), lists,
/// and tables (including merged cells via `gridSpan`). Anything this
/// doesn't recognize — images, headers/footers, equations, comments,
/// track changes, content the writer never emits either — is dropped from
/// that run/paragraph, but never *silently*: `Result.droppedElementKinds`
/// records what kind of thing was found and skipped, so the app can tell
/// the person who imported the file rather than let content vanish without
/// a trace — the design's non-supported-element policy.
enum DocxReader {
    enum ReadError: Error, Equatable {
        case notADocx
        case missingDocumentPart
    }

    struct Result {
        let blocks: [DocumentBlock]
        /// One entry per occurrence (e.g. `["画像", "画像", "数式"]` for a
        /// document with two images and one equation) — a human-readable
        /// kind, not raw XML element names, so the import UI can group and
        /// count them directly (`Dictionary(grouping:by:)` on this).
        let droppedElementKinds: [String]
    }

    static func read(from data: Data) throws -> Result {
        let entries: [DocxZip.Entry]
        do {
            entries = try DocxZip.read(data)
        } catch {
            throw ReadError.notADocx
        }
        guard let documentEntry = entries.first(where: { $0.path == "word/document.xml" }) else {
            throw ReadError.missingDocumentPart
        }

        let relationships = parseRelationships(entries)
        let numbering = parseNumbering(entries)

        let bodyDelegate = DocumentBodyXMLDelegate(relationships: relationships)
        let parser = XMLParser(data: documentEntry.data)
        parser.delegate = bodyDelegate
        _ = parser.parse() // best-effort: a partially-malformed file still yields whatever parsed before the error

        let blocks = bodyDelegate.parsedBlocks.enumerated().map { index, parsedBlock in
            makeDocumentBlock(from: parsedBlock, order: index, numbering: numbering)
        }

        var dropped = bodyDelegate.droppedElementKinds
        if hasHeaderOrFooterParts(entries) {
            dropped.append("ヘッダー/フッター")
        }
        return Result(blocks: blocks, droppedElementKinds: dropped)
    }

    /// Headers/footers live in entirely separate parts (`word/header1.xml`,
    /// `word/footer1.xml`, …) this reader never opens at all — so unlike an
    /// unsupported element buried inside `document.xml`, their absence
    /// can't be noticed while walking that file. Detected instead by
    /// whether any part of the archive is named like one.
    private static func hasHeaderOrFooterParts(_ entries: [DocxZip.Entry]) -> Bool {
        entries.contains { entry in
            let name = (entry.path as NSString).lastPathComponent
            return name.hasPrefix("header") || name.hasPrefix("footer")
        }
    }

    // MARK: word/_rels/document.xml.rels → [relationship ID: target URL]

    private static func parseRelationships(_ entries: [DocxZip.Entry]) -> [String: String] {
        guard let entry = entries.first(where: { $0.path == "word/_rels/document.xml.rels" }) else { return [:] }
        let delegate = RelationshipsXMLDelegate()
        let parser = XMLParser(data: entry.data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.relationships
    }

    // MARK: word/numbering.xml → numId to bulleted/numbered

    private static func parseNumbering(_ entries: [DocxZip.Entry]) -> NumberingXMLDelegate {
        let delegate = NumberingXMLDelegate()
        if let entry = entries.first(where: { $0.path == "word/numbering.xml" }) {
            let parser = XMLParser(data: entry.data)
            parser.delegate = delegate
            _ = parser.parse()
        }
        return delegate
    }

    // MARK: Parsed intermediate representation → DocumentBlock

    private static func makeDocumentBlock(from parsedBlock: ParsedBlock, order: Int, numbering: NumberingXMLDelegate) -> DocumentBlock {
        switch parsedBlock {
        case .paragraph(let paragraph):
            let block = DocumentBlock(order: order, kind: .paragraph)
            block.bodyData = DocumentBody.encode(attributedString(from: paragraph))
            block.paragraphStyle = documentParagraphStyle(forWordStyleID: paragraph.styleID)
            if let numId = paragraph.numId, let kind = numbering.listKind(forNumId: numId) {
                block.listKind = kind
                block.listLevel = paragraph.ilvl
            }
            return block
        case .table(let table):
            let block = DocumentBlock(order: order, kind: .table)
            var rows: [DocumentTableRow] = []
            for (rowIndex, parsedRow) in table.rows.enumerated() {
                let row = DocumentTableRow(order: rowIndex)
                row.block = block
                var cells: [DocumentTableCell] = []
                for (cellIndex, parsedCell) in parsedRow.cells.enumerated() {
                    let cell = DocumentTableCell(order: cellIndex)
                    cell.columnSpan = max(1, parsedCell.gridSpan)
                    cell.row = row
                    let combinedText = parsedCell.paragraphs.map { attributedString(from: $0).string }.joined(separator: "\n")
                    cell.text = combinedText
                    cells.append(cell)
                }
                row.cells = cells
                rows.append(row)
            }
            block.tableRows = rows
            return block
        }
    }

    private static func attributedString(from paragraph: ParsedParagraph) -> NSAttributedString {
        guard !paragraph.runs.isEmpty else {
            return NSAttributedString(string: "", attributes: DocumentBody.defaultAttributes())
        }
        let result = NSMutableAttributedString()
        for run in paragraph.runs {
            var attributes = DocumentBody.defaultAttributes()
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }
            if run.italic { traits.insert(.traitItalic) }
            if !traits.isEmpty {
                let base = UIFont.systemFont(ofSize: 13)
                if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                    attributes[.font] = UIFont(descriptor: descriptor, size: 13)
                }
            }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let hex = run.colorHex { attributes[.foregroundColor] = UIColor(inkHex: hex) }
            if let urlString = run.hyperlinkURL, let url = URL(string: urlString) { attributes[.link] = url }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    /// The reverse of `DocxWriter.wordStyleID(for:)`. An unrecognized or
    /// absent style ID (any docx not produced by this app almost certainly
    /// uses different style IDs/names than these six) falls back to `nil` —
    /// plain body text — rather than guessing.
    private static func documentParagraphStyle(forWordStyleID styleID: String?) -> DocumentParagraphStyle? {
        switch styleID {
        case "Title": return .title
        case "Heading1": return .heading1
        case "Heading2": return .heading2
        case "Heading3": return .heading3
        case "Quote": return .quote
        case "Caption": return .caption
        default: return nil
        }
    }
}

// MARK: - Intermediate representation

private struct ParsedRun {
    var text: String = ""
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var colorHex: String?
    var hyperlinkURL: String?
}

private struct ParsedParagraph {
    var runs: [ParsedRun] = []
    var styleID: String?
    var numId: Int?
    var ilvl: Int = 0
}

private struct ParsedCell {
    var paragraphs: [ParsedParagraph] = []
    var gridSpan: Int = 1
}

private struct ParsedRow {
    var cells: [ParsedCell] = []
}

private struct ParsedTable {
    var rows: [ParsedRow] = []
}

private enum ParsedBlock {
    case paragraph(ParsedParagraph)
    case table(ParsedTable)
}

// MARK: - word/document.xml parsing

/// A SAX-style (`XMLParser`) walk of `word/document.xml`. Matches element
/// names by their literal `w:`/`r:` prefix rather than resolving XML
/// namespaces properly — technically OOXML allows a document to bind those
/// prefixes to something else via its root `xmlns:w=`/`xmlns:r=`
/// declarations, but in practice every real-world docx (Word's own, and
/// every other tool that generates one, including `DocxWriter`) uses these
/// exact prefixes verbatim.
private final class DocumentBodyXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var parsedBlocks: [ParsedBlock] = []
    private(set) var droppedElementKinds: [String] = []

    /// Structurally significant elements this reader has no representation
    /// for — content that's actually lost, as opposed to a run property or
    /// paragraph attribute this just doesn't happen to read. Matched by
    /// element name (not namespace-resolved — see the type-level doc
    /// comment on why that's an acceptable simplification here).
    private static let droppedElementNames: [String: String] = [
        "w:drawing": "画像", "w:pict": "画像", "w:object": "画像",
        "m:oMath": "数式", "m:oMathPara": "数式",
        "w:footnoteReference": "脚注", "w:endnoteReference": "脚注",
        "w:commentReference": "コメント", "w:commentRangeStart": "コメント",
        "w:sdt": "コンテンツコントロール",
    ]

    private let relationships: [String: String]
    init(relationships: [String: String]) {
        self.relationships = relationships
    }

    private var elementStack: [String] = []
    private var paragraphInProgress: ParsedParagraph?
    private var runInProgress: ParsedRun?
    private var textBuffer = ""
    private var hyperlinkRIDInProgress: String?

    private var tableInProgress: ParsedTable?
    private var rowInProgress: ParsedRow?
    private var cellInProgress: ParsedCell?
    private var cellGridSpanInProgress = 1

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        if let kind = Self.droppedElementNames[elementName] {
            droppedElementKinds.append(kind)
        }
        switch elementName {
        case "w:tbl":
            tableInProgress = ParsedTable()
        case "w:tr":
            rowInProgress = ParsedRow()
        case "w:tc":
            cellInProgress = ParsedCell()
            cellGridSpanInProgress = 1
        case "w:gridSpan":
            if let value = attributeDict["w:val"], let n = Int(value) { cellGridSpanInProgress = n }
        case "w:p":
            paragraphInProgress = ParsedParagraph()
        case "w:pStyle":
            paragraphInProgress?.styleID = attributeDict["w:val"]
        case "w:numId":
            if let value = attributeDict["w:val"], let n = Int(value) { paragraphInProgress?.numId = n }
        case "w:ilvl":
            if let value = attributeDict["w:val"], let n = Int(value) { paragraphInProgress?.ilvl = n }
        case "w:hyperlink":
            hyperlinkRIDInProgress = attributeDict["r:id"]
        case "w:r":
            runInProgress = ParsedRun()
        case "w:b":
            if !isExplicitlyOff(attributeDict) { runInProgress?.bold = true }
        case "w:i":
            if !isExplicitlyOff(attributeDict) { runInProgress?.italic = true }
        case "w:u":
            if attributeDict["w:val"] != "none" { runInProgress?.underline = true }
        case "w:strike":
            if !isExplicitlyOff(attributeDict) { runInProgress?.strikethrough = true }
        case "w:color":
            if let value = attributeDict["w:val"], value != "auto" { runInProgress?.colorHex = value }
        case "w:t":
            textBuffer = ""
        default:
            break
        }
    }

    /// A boolean run-property element (`<w:b/>`, `<w:i/>`, `<w:strike/>`)
    /// means "on" when bare, and can also appear as `<w:b w:val="0"/>` or
    /// `w:val="false"` to explicitly mean "off" — both forms are valid
    /// OOXML and real files use either.
    private func isExplicitlyOff(_ attributes: [String: String]) -> Bool {
        guard let value = attributes["w:val"] else { return false }
        return value == "0" || value == "false"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elementStack.last == "w:t" {
            textBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if elementStack.last == elementName { elementStack.removeLast() } }
        switch elementName {
        case "w:t":
            runInProgress?.text += textBuffer
        case "w:r":
            if var run = runInProgress {
                if let rid = hyperlinkRIDInProgress { run.hyperlinkURL = relationships[rid] }
                paragraphInProgress?.runs.append(run)
            }
            runInProgress = nil
        case "w:hyperlink":
            hyperlinkRIDInProgress = nil
        case "w:p":
            if let paragraph = paragraphInProgress {
                if cellInProgress != nil {
                    cellInProgress?.paragraphs.append(paragraph)
                } else {
                    parsedBlocks.append(.paragraph(paragraph))
                }
            }
            paragraphInProgress = nil
        case "w:tc":
            if var cell = cellInProgress {
                cell.gridSpan = cellGridSpanInProgress
                rowInProgress?.cells.append(cell)
            }
            cellInProgress = nil
        case "w:tr":
            if let row = rowInProgress { tableInProgress?.rows.append(row) }
            rowInProgress = nil
        case "w:tbl":
            if let table = tableInProgress { parsedBlocks.append(.table(table)) }
            tableInProgress = nil
        default:
            break
        }
    }
}

// MARK: - word/numbering.xml parsing

/// Only tracks enough to answer "is this numId a bulleted or a numbered
/// list" (its level-0 `numFmt`) — not the full numbering definition (custom
/// start values, restart rules, …), matching what `DocumentBlock.listKind`
/// itself can represent.
private final class NumberingXMLDelegate: NSObject, XMLParserDelegate {
    private var numIdToAbstractID: [Int: Int] = [:]
    private var abstractIDToKind: [Int: DocumentListKind] = [:]

    private var currentAbstractID: Int?
    private var currentLevel: Int?
    private var currentNumID: Int?

    func listKind(forNumId numId: Int) -> DocumentListKind? {
        numIdToAbstractID[numId].flatMap { abstractIDToKind[$0] }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:abstractNum":
            currentAbstractID = attributeDict["w:abstractNumId"].flatMap(Int.init)
        case "w:lvl":
            currentLevel = attributeDict["w:ilvl"].flatMap(Int.init)
        case "w:numFmt":
            if currentLevel == 0, let abstractID = currentAbstractID, let format = attributeDict["w:val"] {
                abstractIDToKind[abstractID] = format == "bullet" ? .bulleted : .numbered
            }
        case "w:num":
            currentNumID = attributeDict["w:numId"].flatMap(Int.init)
        case "w:abstractNumId":
            if let numID = currentNumID, let abstractID = attributeDict["w:val"].flatMap(Int.init) {
                numIdToAbstractID[numID] = abstractID
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:abstractNum" { currentAbstractID = nil }
        if elementName == "w:num" { currentNumID = nil }
    }
}

// MARK: - word/_rels/document.xml.rels parsing

private final class RelationshipsXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var relationships: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        relationships[id] = target
    }
}
