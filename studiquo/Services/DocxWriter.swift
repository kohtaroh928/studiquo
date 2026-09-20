import Foundation
import UIKit

/// Converts a `TextDocument` into real `.docx` bytes — the OOXML/
/// WordprocessingML XML parts (see the step-by-step design this
/// implements), zipped via `DocxZip`.
///
/// Scope for this first pass: paragraphs (bold/italic/underline/
/// strikethrough/color, paragraph styles, alignment, hyperlinks), real
/// lists (`listKind`/`listLevel`), and tables (including column-merged
/// cells via `gridSpan`). Not yet covered — skipped rather than
/// crashing or corrupting the file — images, headers/footers, equations,
/// comments, track changes, and the table of contents; each needs its own
/// additional OOXML parts/relationships beyond what this pass wires up.
enum DocxWriter {
    static func makeDocxData(from document: TextDocument) -> Data? {
        var hyperlinkURLs: [String] = [] // in first-seen order; index+1 is its rId offset
        let documentBodyXML = bodyXML(for: document, hyperlinkURLs: &hyperlinkURLs)

        let entries = [
            DocxZip.Entry(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            DocxZip.Entry(path: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            DocxZip.Entry(path: "word/document.xml", data: Data(documentXML(body: documentBodyXML).utf8)),
            DocxZip.Entry(path: "word/styles.xml", data: Data(stylesXML.utf8)),
            DocxZip.Entry(path: "word/numbering.xml", data: Data(numberingXML.utf8)),
            DocxZip.Entry(path: "word/_rels/document.xml.rels", data: Data(documentRelsXML(hyperlinkURLs: hyperlinkURLs).utf8)),
        ]
        return try? DocxZip.write(entries)
    }

    // MARK: word/document.xml

    private static func documentXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>
        \(body)
        <w:sectPr/>
        </w:body>
        </w:document>
        """
    }

    private static func bodyXML(for document: TextDocument, hyperlinkURLs: inout [String]) -> String {
        document.segments.map { segment in
            switch segment.kind {
            case .text:
                return segment.blocks.map { paragraphXML($0, hyperlinkURLs: &hyperlinkURLs) }.joined(separator: "\n")
            case .table:
                guard let block = segment.blocks.first else { return "" }
                return tableXML(block, hyperlinkURLs: &hyperlinkURLs)
            case .equation, .tableOfContents:
                // Out of scope for this pass — see the type's doc comment.
                return ""
            }
        }.joined(separator: "\n")
    }

    private static func paragraphXML(_ block: DocumentBlock, hyperlinkURLs: inout [String]) -> String {
        var pPr = "<w:pPr>"
        pPr += "<w:pStyle w:val=\"\(wordStyleID(for: block.paragraphStyle))\"/>"
        if let listKind = block.listKind {
            pPr += "<w:numPr><w:ilvl w:val=\"\(block.listLevel)\"/><w:numId w:val=\"\(listKind == .bulleted ? 1 : 2)\"/></w:numPr>"
        }
        let text = DocumentBody.decode(block.bodyData)
        if let alignment = paragraphAlignment(of: text) {
            pPr += "<w:jc w:val=\"\(alignment)\"/>"
        }
        pPr += "</w:pPr>"

        let runsXML = runs(of: text).map { run in
            runXML(run, hyperlinkURLs: &hyperlinkURLs)
        }.joined()

        return "<w:p>\(pPr)\(runsXML)</w:p>"
    }

    private struct Run {
        let text: String
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let strikethrough: Bool
        let colorHex: String?
        let linkURL: String?
    }

    private static func runs(of text: NSAttributedString) -> [Run] {
        guard text.length > 0 else { return [] }
        var result: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let substring = (text.string as NSString).substring(with: range)
            guard !substring.isEmpty else { return }
            let font = attributes[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let color = (attributes[.foregroundColor] as? UIColor).flatMap(hexString(from:))
            let link = (attributes[.link] as? URL)?.absoluteString
            result.append(Run(
                text: substring,
                bold: traits.contains(.traitBold),
                italic: traits.contains(.traitItalic),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                colorHex: color,
                linkURL: link
            ))
        }
        return result
    }

    private static func runXML(_ run: Run, hyperlinkURLs: inout [String]) -> String {
        var rPr = ""
        if run.bold { rPr += "<w:b/>" }
        if run.italic { rPr += "<w:i/>" }
        if run.underline { rPr += "<w:u w:val=\"single\"/>" }
        if run.strikethrough { rPr += "<w:strike/>" }
        if let colorHex = run.colorHex { rPr += "<w:color w:val=\"\(colorHex)\"/>" }
        let rPrXML = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
        let runElement = "<w:r>\(rPrXML)<w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t></w:r>"

        guard let url = run.linkURL else { return runElement }
        let rID = relationshipID(for: url, in: &hyperlinkURLs)
        return "<w:hyperlink r:id=\"\(rID)\">\(runElement)</w:hyperlink>"
    }

    /// Hyperlink relationship IDs start after the two fixed ones
    /// (`word/_rels/document.xml.rels`'s styles/numbering relationships),
    /// and are shared by every run linking to the same URL rather than
    /// minted fresh each time.
    private static func relationshipID(for url: String, in hyperlinkURLs: inout [String]) -> String {
        if let existingIndex = hyperlinkURLs.firstIndex(of: url) {
            return "rId\(existingIndex + 3)"
        }
        hyperlinkURLs.append(url)
        return "rId\(hyperlinkURLs.count + 2)"
    }

    private static func paragraphAlignment(of text: NSAttributedString) -> String? {
        guard text.length > 0 else { return nil }
        guard let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        switch style.alignment {
        case .center: return "center"
        case .right: return "right"
        case .justified: return "both"
        default: return nil // .natural/.left is Word's own paragraph default — no need to state it
        }
    }

    private static func wordStyleID(for style: DocumentParagraphStyle?) -> String {
        switch style {
        case .title: return "Title"
        case .heading1: return "Heading1"
        case .heading2: return "Heading2"
        case .heading3: return "Heading3"
        case .quote: return "Quote"
        case .caption: return "Caption"
        case .body, nil: return "Normal"
        }
    }

    // MARK: Tables

    private static func tableXML(_ block: DocumentBlock, hyperlinkURLs: inout [String]) -> String {
        let columnCount = block.tableColumnCount
        let gridXML = (0..<max(columnCount, 1)).map { _ in "<w:gridCol/>" }.joined()
        let rowsXML = block.sortedTableRows.map { row -> String in
            let cellsXML = row.sortedCells.map { cell -> String in
                let cellText = DocumentBody.decode(cell.bodyData)
                let runsXML = runs(of: cellText).map { runXML($0, hyperlinkURLs: &hyperlinkURLs) }.joined()
                let paragraph = "<w:p><w:pPr><w:pStyle w:val=\"Normal\"/></w:pPr>\(runsXML)</w:p>"
                let spanXML = cell.columnSpan > 1 ? "<w:gridSpan w:val=\"\(cell.columnSpan)\"/>" : ""
                return "<w:tc><w:tcPr>\(spanXML)</w:tcPr>\(paragraph)</w:tc>"
            }.joined()
            return "<w:tr>\(cellsXML)</w:tr>"
        }.joined()

        return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>" +
            "<w:top w:val=\"single\" w:sz=\"4\"/><w:left w:val=\"single\" w:sz=\"4\"/>" +
            "<w:bottom w:val=\"single\" w:sz=\"4\"/><w:right w:val=\"single\" w:sz=\"4\"/>" +
            "<w:insideH w:val=\"single\" w:sz=\"4\"/><w:insideV w:val=\"single\" w:sz=\"4\"/>" +
            "</w:tblBorders></w:tblPr><w:tblGrid>\(gridXML)</w:tblGrid>\(rowsXML)</w:tbl>"
    }

    // MARK: [Content_Types].xml, _rels/.rels

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func documentRelsXML(hyperlinkURLs: [String]) -> String {
        var relationships = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for (index, url) in hyperlinkURLs.enumerated() {
            relationships += "\n<Relationship Id=\"rId\(index + 3)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(url))\" TargetMode=\"External\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships)
        </Relationships>
        """
    }

    // MARK: word/styles.xml

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:rPr><w:b/><w:sz w:val="56"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:rPr><w:i/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:rPr><w:i/><w:sz w:val="18"/></w:rPr></w:style>
    </w:styles>
    """

    // MARK: word/numbering.xml

    /// Two abstract numbering definitions — bulleted (numId 1) and numbered
    /// (numId 2) — each with 3 levels, matching the glyphs/styles
    /// `TextDocument.listMarker(for:)` already renders in-app (•/◦/▪ and
    /// 1./a./i.), so a docx exported here looks the same when reopened in
    /// this app or in Word.
    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
    <w:lvl w:ilvl="2"><w:numFmt w:val="bullet"/><w:lvlText w:val="▪"/><w:pPr><w:ind w:left="1080" w:hanging="360"/></w:pPr></w:lvl>
    </w:abstractNum>
    <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
    <w:lvl w:ilvl="2"><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%3."/><w:pPr><w:ind w:left="1080" w:hanging="360"/></w:pPr></w:lvl>
    </w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    // MARK: Helpers

    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func hexString(from color: UIColor) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        // Black is Word's own run default — omitting it keeps the XML
        // smaller and avoids stating the obvious for the overwhelming
        // majority of plain text.
        if red < 0.01, green < 0.01, blue < 0.01 { return nil }
        return String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}
