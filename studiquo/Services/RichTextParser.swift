import Foundation

/// A run of text inside a paragraph, heading, list item or table cell.
struct RichSpan: Equatable {
    enum Content: Equatable {
        case text(String)
        /// LaTeX, without delimiters.
        case math(String)
        case code(String)
    }

    var content: Content
    var isBold = false
    var isItalic = false
    var isStrikethrough = false
    var link: String?

    init(_ content: Content, bold: Bool = false, italic: Bool = false, strike: Bool = false, link: String? = nil) {
        self.content = content
        self.isBold = bold
        self.isItalic = italic
        self.isStrikethrough = strike
        self.link = link
    }
}

/// What an AI reply is made of, block by block.
indirect enum RichBlock: Equatable {
    case heading(level: Int, spans: [RichSpan])
    case paragraph([RichSpan])
    /// A complete display formula (LaTeX, without delimiters).
    case displayMath(String)
    /// A display formula that has been opened but not closed yet, as written
    /// so far — the reply is still streaming.
    case incompleteMath(String)
    case codeBlock(language: String?, code: String, isClosed: Bool)
    /// Each item is the blocks inside it: its text, then any nested list.
    case list(ordered: Bool, start: Int, items: [[RichBlock]])
    case quote([RichBlock])
    case table(header: [[RichSpan]], rows: [[[RichSpan]]])
    case rule
}

/// Splits a reply — Japanese prose with Markdown and LaTeX mixed in — into
/// blocks and spans a screen can lay out.
///
/// The input may be a reply that is still arriving. Anything not yet closed
/// (`**bold`, `$x^`, a code fence, a table without its separator row)
/// stays literal text until the rest comes, and nothing in the parse can fail.
///
/// Math and code are lifted out first (via `MathSegmenter`) and replaced by
/// private-use markers, so the line-by-line Markdown parse never has to look
/// inside a formula: its `|`, `*` and `_` are not Markdown.
enum RichTextParser {
    static func parse(_ source: String) -> [RichBlock] {
        let prepared = Prepared(source)
        return BlockParser(prepared: prepared).parseBlocks(prepared.text.components(separatedBy: "\n"))
    }

    // MARK: Lifting math and code out

    fileprivate static let inlineOpen: Character = "\u{E100}"
    fileprivate static let inlineClose: Character = "\u{E101}"
    fileprivate static let blockOpen: Character = "\u{E200}"
    fileprivate static let blockClose: Character = "\u{E201}"

    fileprivate struct Prepared {
        var text = ""
        var inlines: [RichSpan.Content] = []
        var blocks: [RichBlock] = []

        init(_ source: String) {
            func startsOnBlankLine() -> Bool {
                guard let lastNewline = text.lastIndex(of: "\n") else {
                    return text.allSatisfy { $0 == " " || $0 == "\t" }
                }
                return text[text.index(after: lastNewline)...].allSatisfy { $0 == " " || $0 == "\t" }
            }
            func appendBlock(_ block: RichBlock) {
                if !text.isEmpty && !startsOnBlankLine() { text += "\n" }
                text += "\(RichTextParser.blockOpen)\(blocks.count)\(RichTextParser.blockClose)\n"
                blocks.append(block)
            }
            func appendInline(_ content: RichSpan.Content) {
                text += "\(RichTextParser.inlineOpen)\(inlines.count)\(RichTextParser.inlineClose)"
                inlines.append(content)
            }

            // A block marker is already followed by a newline, so the newline
            // that usually starts the next text must not become a blank line
            // (which would split a list around a formula).
            var afterBlock = false
            for segment in MathSegmenter.segments(in: source) {
                var isBlock = false
                switch segment {
                case .text(var t):
                    if afterBlock, t.hasPrefix("\n") { t.removeFirst() }
                    text += t
                case .inlineMath(let m):
                    appendInline(.math(m))
                case .displayMath(let m):
                    appendBlock(.displayMath(m)); isBlock = true
                case .code(let c):
                    if c.hasPrefix("```") || c.hasPrefix("~~~") {
                        appendBlock(Self.codeBlock(from: c)); isBlock = true
                    } else {
                        appendInline(.code(Self.inlineCode(from: c)))
                    }
                case .incomplete(let c):
                    if c.hasPrefix("$$") || c.hasPrefix("\\[") || c.hasPrefix("\\begin{") {
                        appendBlock(.incompleteMath(c)); isBlock = true
                    } else {
                        appendInline(.text(c))
                    }
                }
                afterBlock = isBlock
            }
        }

        private static func inlineCode(from raw: String) -> String {
            var body = raw
            let run = raw.prefix(while: { $0 == "`" }).count
            body.removeFirst(run)
            if body.hasSuffix(String(repeating: "`", count: run)) { body.removeLast(run) }
            if body.count >= 2, body.hasPrefix(" "), body.hasSuffix(" ") { body = String(body.dropFirst().dropLast()) }
            return body
        }

        private static func codeBlock(from raw: String) -> RichBlock {
            var lines = raw.components(separatedBy: "\n")
            let opening = lines.removeFirst()
            let marker = opening.hasPrefix("```") ? "```" : "~~~"
            let info = opening.dropFirst(opening.prefix(while: { String($0) == String(marker.first!) }).count)
                .trimmingCharacters(in: .whitespaces)
            var isClosed = false
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix(marker),
               last.trimmingCharacters(in: .whitespaces).allSatisfy({ String($0) == String(marker.first!) }) {
                lines.removeLast()
                isClosed = true
            }
            return .codeBlock(language: info.isEmpty ? nil : String(info.split(separator: " ").first ?? ""), code: lines.joined(separator: "\n"), isClosed: isClosed)
        }
    }

    // MARK: Blocks

    fileprivate struct BlockParser {
        let prepared: Prepared

        func parseBlocks(_ lines: [String]) -> [RichBlock] {
            var blocks: [RichBlock] = []
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

                if let index = blockMarker(in: line) {
                    if prepared.blocks.indices.contains(index) { blocks.append(prepared.blocks[index]) }
                    i += 1
                    continue
                }
                if let heading = heading(line) {
                    blocks.append(.heading(level: heading.level, spans: InlineParser(prepared: prepared).parse(heading.text)))
                    i += 1
                    continue
                }
                if isRule(line) { blocks.append(.rule); i += 1; continue }
                if isQuote(line) {
                    var inner: [String] = []
                    while i < lines.count, isQuote(lines[i]) {
                        inner.append(unquoted(lines[i]))
                        i += 1
                    }
                    blocks.append(.quote(parseBlocks(inner)))
                    continue
                }
                if listItem(line) != nil {
                    blocks.append(parseList(lines, &i))
                    continue
                }
                if i + 1 < lines.count, isTableRow(line), isTableSeparator(lines[i + 1]) {
                    blocks.append(parseTable(lines, &i))
                    continue
                }
                blocks.append(parseParagraph(lines, &i))
            }
            return blocks
        }

        // Paragraph ------------------------------------------------------

        private func parseParagraph(_ lines: [String], _ i: inout Int) -> RichBlock {
            var collected: [String] = []
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if !collected.isEmpty {
                    if blockMarker(in: line) != nil || heading(line) != nil || isRule(line) || isQuote(line) { break }
                    if let item = listItem(line), item.canInterruptParagraph { break }
                    if i + 1 < lines.count, isTableRow(line), isTableSeparator(lines[i + 1]) { break }
                }
                collected.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            return .paragraph(InlineParser(prepared: prepared).parse(collected.joined(separator: "\n")))
        }

        // Headings, rules, quotes ----------------------------------------

        private func heading(_ line: String) -> (level: Int, text: String)? {
            let trimmed = line.drop(while: { $0 == " " }).prefix(while: { _ in true })
            guard line.count - trimmed.count <= 3 else { return nil }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return (hashes, text.trimmingCharacters(in: .whitespaces))
        }

        private func isRule(_ line: String) -> Bool {
            line.range(of: #"^ {0,3}([-*_])( *\1){2,} *$"#, options: .regularExpression) != nil
        }

        private func isQuote(_ line: String) -> Bool {
            line.range(of: #"^ {0,3}>"#, options: .regularExpression) != nil
        }

        private func unquoted(_ line: String) -> String {
            line.replacingOccurrences(of: #"^ {0,3}> ?"#, with: "", options: .regularExpression)
        }

        private func blockMarker(in line: String) -> Int? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == RichTextParser.blockOpen, trimmed.last == RichTextParser.blockClose else { return nil }
            return Int(trimmed.dropFirst().dropLast())
        }

        // Lists ------------------------------------------------------------

        struct ListItemStart {
            var indent: Int
            var ordered: Bool
            var number: Int
            var contentOffset: Int
            var text: String
            var canInterruptParagraph: Bool
        }

        func listItem(_ line: String) -> ListItemStart? {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix(while: { $0 == " " }).count
            let rest = expanded.dropFirst(indent)
            guard let match = rest.range(of: #"^([-*+]|\d{1,9}[.)])( +|$)"#, options: .regularExpression) else { return nil }
            let marker = rest[match].trimmingCharacters(in: .whitespaces)
            let spaces = rest[match].count - marker.count
            // "- " followed by only spaces, or nothing: an empty item
            let text = String(rest[match.upperBound...])
            // a bullet needs a space after it; a horizontal rule is not a list
            if isRule(line) { return nil }
            let ordered = marker.first!.isNumber
            let number = ordered ? (Int(marker.dropLast()) ?? 1) : 0
            let offset = indent + marker.count + (spaces > 4 || spaces == 0 ? 1 : spaces)
            return ListItemStart(
                indent: indent, ordered: ordered, number: number, contentOffset: offset, text: text,
                canInterruptParagraph: !ordered || number == 1
            )
        }

        private func parseList(_ lines: [String], _ i: inout Int) -> RichBlock {
            guard let first = listItem(lines[i]) else { return .paragraph([]) }
            var items: [[RichBlock]] = []

            while i < lines.count, let start = listItem(lines[i]), start.ordered == first.ordered, start.indent <= first.indent + 3 {
                var itemLines: [String] = [start.text]
                i += 1
                itemLoop: while i < lines.count {
                    let line = lines[i]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        // a blank line: the item goes on only if what follows is indented under it
                        var k = i + 1
                        while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                        guard k < lines.count, indentation(of: lines[k]) >= start.contentOffset else { break itemLoop }
                        itemLines.append("")
                        i += 1
                        continue
                    }
                    if indentation(of: line) >= start.contentOffset {
                        itemLines.append(removeIndent(line, start.contentOffset))
                        i += 1
                        continue
                    }
                    if listItem(line) != nil { break itemLoop }
                    // lazy continuation of the item's paragraph
                    if blockMarker(in: line) != nil || heading(line) != nil || isRule(line) || isQuote(line) { break itemLoop }
                    itemLines.append(line.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                items.append(parseBlocks(itemLines))
                // a blank line between items does not end the list
                var k = i
                while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
                if k > i, k < lines.count, let next = listItem(lines[k]), next.ordered == first.ordered { i = k }
            }
            return .list(ordered: first.ordered, start: first.ordered ? first.number : 1, items: items)
        }

        private func indentation(of line: String) -> Int {
            line.replacingOccurrences(of: "\t", with: "    ").prefix(while: { $0 == " " }).count
        }

        private func removeIndent(_ line: String, _ amount: Int) -> String {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let leading = expanded.prefix(while: { $0 == " " }).count
            return String(expanded.dropFirst(min(leading, amount)))
        }

        // Tables -------------------------------------------------------------

        private func isTableRow(_ line: String) -> Bool { line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty }

        private func isTableSeparator(_ line: String) -> Bool {
            line.range(of: #"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
                && line.contains("-") && line.contains("|")
        }

        private func cells(_ line: String) -> [String] {
            var body = line.trimmingCharacters(in: .whitespaces)
            body = body.replacingOccurrences(of: "\\|", with: "\u{E300}")
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.components(separatedBy: "|").map {
                $0.replacingOccurrences(of: "\u{E300}", with: "|").trimmingCharacters(in: .whitespaces)
            }
        }

        private func parseTable(_ lines: [String], _ i: inout Int) -> RichBlock {
            let parser = InlineParser(prepared: prepared)
            let header = cells(lines[i]).map { parser.parse($0) }
            i += 2
            var rows: [[[RichSpan]]] = []
            while i < lines.count, isTableRow(lines[i]), blockMarker(in: lines[i]) == nil {
                var row = cells(lines[i]).map { parser.parse($0) }
                while row.count < header.count { row.append([]) }
                rows.append(Array(row.prefix(max(header.count, 1))))
                i += 1
            }
            return .table(header: header, rows: rows)
        }
    }

    // MARK: Inline

    fileprivate struct InlineParser {
        let prepared: Prepared

        struct Style {
            var bold = false, italic = false, strike = false
            var link: String?
        }

        func parse(_ text: String) -> [RichSpan] {
            var spans: [RichSpan] = []
            parse(Array(text), style: Style(), into: &spans, depth: 0)
            return spans
        }

        private func append(_ content: RichSpan.Content, style: Style, to spans: inout [RichSpan]) {
            let span = RichSpan(content, bold: style.bold, italic: style.italic, strike: style.strike, link: style.link)
            if case .text(let new) = content, var last = spans.last, case .text(let old) = last.content,
               last.isBold == span.isBold, last.isItalic == span.isItalic, last.isStrikethrough == span.isStrikethrough, last.link == span.link {
                last.content = .text(old + new)
                spans[spans.count - 1] = last
            } else {
                spans.append(span)
            }
        }

        private func parse(_ s: [Character], style: Style, into spans: inout [RichSpan], depth: Int) {
            guard depth < 12 else { append(.text(String(s)), style: style, to: &spans); return }
            var buffer = ""
            var i = 0
            func flush() {
                if !buffer.isEmpty { append(.text(buffer), style: style, to: &spans); buffer = "" }
            }

            while i < s.count {
                let c = s[i]

                // a lifted-out formula or code span
                if c == RichTextParser.inlineOpen, let close = s[i...].firstIndex(of: RichTextParser.inlineClose),
                   let index = Int(String(s[(i + 1)..<close])), prepared.inlines.indices.contains(index) {
                    flush()
                    append(prepared.inlines[index], style: style, to: &spans)
                    i = close + 1
                    continue
                }
                // a backslash-escaped Markdown character
                if c == "\\", i + 1 < s.count, "\\`*_[]()#!|~>".contains(s[i + 1]) {
                    buffer.append(s[i + 1])
                    i += 2
                    continue
                }
                // an image: keep its description
                if c == "!", i + 1 < s.count, s[i + 1] == "[", let link = link(in: s, at: i + 1) {
                    flush()
                    var inner = style
                    inner.link = nil
                    parse(link.text, style: inner, into: &spans, depth: depth + 1)
                    i = link.end
                    continue
                }
                if c == "[", let link = link(in: s, at: i) {
                    flush()
                    var inner = style
                    inner.link = String(link.url)
                    parse(link.text, style: inner, into: &spans, depth: depth + 1)
                    i = link.end
                    continue
                }
                if c == "*" || c == "_" || c == "~" {
                    let run = runLength(of: c, in: s, at: i)
                    if let emphasis = emphasis(c, run: run, in: s, at: i) {
                        flush()
                        var inner = style
                        switch (c, emphasis.length) {
                        case ("~", _): inner.strike = true
                        case (_, 1): inner.italic = true
                        case (_, 2): inner.bold = true
                        default: inner.bold = true; inner.italic = true
                        }
                        parse(emphasis.inner, style: inner, into: &spans, depth: depth + 1)
                        i = emphasis.end
                        continue
                    }
                    buffer.append(contentsOf: String(repeating: c, count: run))
                    i += run
                    continue
                }
                buffer.append(c)
                i += 1
            }
            flush()
        }

        private func runLength(of c: Character, in s: [Character], at i: Int) -> Int {
            var n = 0
            while i + n < s.count, s[i + n] == c { n += 1 }
            return n
        }

        /// `**…**`, `*…*`, `***…***`, `_…_`, `~~…~~` starting at `i`, if closed.
        private func emphasis(_ c: Character, run: Int, in s: [Character], at i: Int) -> (length: Int, inner: [Character], end: Int)? {
            let length: Int
            switch c {
            case "~": guard run >= 2 else { return nil }; length = 2
            default: length = min(run, 3)
            }
            let openEnd = i + length
            guard openEnd < s.count, !s[openEnd].isWhitespace else { return nil }
            if c == "_" {
                // intraword underscores (snake_case) are not emphasis
                if i > 0, s[i - 1].isLetter || s[i - 1].isNumber { return nil }
            }
            var j = openEnd
            while j < s.count {
                if s[j] == "\\" { j += 2; continue }
                if s[j] == c {
                    let closing = runLength(of: c, in: s, at: j)
                    if closing == length, !s[j - 1].isWhitespace, j > openEnd {
                        if c == "_", j + length < s.count, s[j + length].isLetter || s[j + length].isNumber {
                            j += closing
                            continue
                        }
                        return (length, Array(s[openEnd..<j]), j + length)
                    }
                    j += closing
                    continue
                }
                j += 1
            }
            return nil
        }

        /// `[text](url)` starting at `i` (the `[`).
        private func link(in s: [Character], at i: Int) -> (text: [Character], url: [Character], end: Int)? {
            var depth = 0
            var j = i
            while j < s.count {
                if s[j] == "\\" { j += 2; continue }
                if s[j] == "[" { depth += 1 }
                if s[j] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            guard j < s.count, s[j] == "]", j + 1 < s.count, s[j + 1] == "(" else { return nil }
            var k = j + 2
            while k < s.count, s[k] != ")", !s[k].isWhitespace { k += 1 }
            guard k < s.count, s[k] == ")" else { return nil }
            return (Array(s[(i + 1)..<j]), Array(s[(j + 2)..<k]), k + 1)
        }
    }
}
