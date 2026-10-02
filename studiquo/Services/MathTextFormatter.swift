import Foundation

/// Turns the LaTeX and Markdown an AI model writes into text a person can
/// read without any typesetting: `x^2` → `x²`, `\frac{a}{b}` → `a/b`,
/// `\sum_{i=1}^{n}` → `Σ(i = 1〜n)`.
///
/// This is the plain-text form of a reply. It is what gets copied, pasted
/// onto a page, read by VoiceOver and shown in notifications, and what stands
/// in on screen when a formula cannot be typeset. It never changes stored
/// data; it runs when text is shown.
enum MathTextFormatter {
    /// One formula, without delimiters. May be several lines (`aligned`).
    static func readableMath(from latex: String) -> String {
        var parser = TeXParser(latex)
        let nodes = parser.parseAll()
        let rendered = TeXRenderer().string(nodes)
        return normalize(rendered)
    }

    /// Puts a display formula on a line of its own.
    private static func appendDisplay(_ math: String, to out: inout String) {
        while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        out += math
    }

    /// A reply with its math converted and everything else left as written
    /// (Markdown markers included). Code is never touched.
    static func readableText(from source: String) -> String {
        var out = ""
        var needsLineBreak = false
        for segment in MathSegmenter.segments(in: source) {
            switch segment {
            case .text(var t):
                if needsLineBreak {
                    t = String(t.drop(while: { $0 == " " || $0 == "\t" }))
                    if !t.hasPrefix("\n") { out += "\n" }
                    needsLineBreak = false
                }
                out += t
            case .code(let c), .incomplete(let c):
                if needsLineBreak { out += "\n"; needsLineBreak = false }
                out += c
            case .inlineMath(let m):
                if needsLineBreak { out += "\n"; needsLineBreak = false }
                out += readableMath(from: m)
            case .displayMath(let m):
                appendDisplay(readableMath(from: m), to: &out)
                needsLineBreak = true
            }
        }
        return out
    }

    /// `readableText` with the Markdown markers removed as well (`**bold**`,
    /// `## heading`, `- item`, tables, links), for places that show plain
    /// text only.
    static func plainText(from source: String) -> String {
        var codeBlocks: [String] = []
        var text = ""
        var needsLineBreak = false
        for segment in MathSegmenter.segments(in: source) {
            switch segment {
            case .text(var t):
                if needsLineBreak {
                    t = String(t.drop(while: { $0 == " " || $0 == "\t" }))
                    if !t.hasPrefix("\n") { text += "\n" }
                    needsLineBreak = false
                }
                text += t
            case .code(let c):
                if needsLineBreak { text += "\n"; needsLineBreak = false }
                text += "\u{E000}\(codeBlocks.count)\u{E001}"
                codeBlocks.append(unfenced(c))
            case .incomplete(let c):
                if needsLineBreak { text += "\n"; needsLineBreak = false }
                text += c
            case .inlineMath(let m):
                if needsLineBreak { text += "\n"; needsLineBreak = false }
                text += readableMath(from: m)
            case .displayMath(let m):
                appendDisplay(readableMath(from: m), to: &text)
                needsLineBreak = true
            }
        }
        var result = strippingMarkdown(text)
        for (index, block) in codeBlocks.enumerated() {
            result = result.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: block)
        }
        return result
    }

    // MARK: Markdown

    private static func unfenced(_ code: String) -> String {
        if code.hasPrefix("```") || code.hasPrefix("~~~") {
            var lines = code.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.hasPrefix("```") || last.hasPrefix("~~~") { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        return code.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    private static func strippingMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for var line in text.components(separatedBy: "\n") {
            if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil,
               line.range(of: #"^\s*[-*]\s+\S"#, options: .regularExpression) == nil { continue }
            if line.range(of: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil,
               line.contains("-") && line.contains("|") { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)>\s?"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1・", options: .regularExpression)
            if line.hasPrefix("|") || line.range(of: #"^\s*\|"#, options: .regularExpression) != nil {
                line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("|") { line.removeFirst() }
                if line.hasSuffix("|") { line.removeLast() }
                line = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
            }
            line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*\*(.+?)\*\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func normalize(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var collapsed = line.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            collapsed = collapsed.trimmingCharacters(in: .whitespaces)
            return collapsed
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Parsing

private indirect enum TeX {
    case char(Character)
    case command(String)
    case group([TeX])
    case scripted(base: TeX?, sub: TeX?, sup: TeX?)
    case frac(TeX, TeX)
    case binom(TeX, TeX)
    case sqrt(TeX?, TeX)
    case rawText(String)
    case styled(String, TeX)
    case accent(String, TeX)
    case delimited(String, [TeX], String)
    case env(String, [[[TeX]]])
    case arrow(String, TeX?, TeX?)
    case over(String, TeX)
    case two(String, TeX, TeX)
    case negated(TeX)
    case unknown(String, [TeX])
    case chem(String)
    case space(String)
    case newline
    case align
}

private struct TeXParser {
    private let chars: [Character]
    private var i = 0
    private var macros: [String: [TeX]] = [:]
    private var depth = 0

    init(_ source: String) { chars = Array(source) }

    private enum Stop { case none, brace, bracket, end, right }

    mutating func parseAll() -> [TeX] { parseSequence(stop: .none) }

    // MARK: Sequences

    private mutating func parseSequence(stop: Stop) -> [TeX] {
        var nodes: [TeX] = []
        depth += 1
        defer { depth -= 1 }
        guard depth < 60 else { i = chars.count; return nodes }
        while i < chars.count {
            let c = chars[i]
            switch stop {
            case .brace where c == "}": return nodes
            case .bracket where c == "]": return nodes
            case .end where matches("\\end{"): return nodes
            case .right where matches("\\right") && !isLetter(at: i + 6): return nodes
            default: break
            }
            if c == "}" { i += 1; continue }
            if c.isWhitespace { i += 1; continue }
            if c == "^" || c == "_" {
                nodes.append(parseScripts(base: nil))
                continue
            }
            guard let atom = parseAtom() else { continue }
            skipSpaces()
            if i < chars.count, chars[i] == "^" || chars[i] == "_" {
                nodes.append(parseScripts(base: atom))
            } else {
                nodes.append(atom)
            }
        }
        return nodes
    }

    private mutating func parseScripts(base: TeX?) -> TeX {
        var sub: TeX?
        var sup: TeX?
        while true {
            skipSpaces()
            guard i < chars.count else { break }
            if chars[i] == "^", sup == nil {
                i += 1
                sup = parseArgument()
            } else if chars[i] == "_", sub == nil {
                i += 1
                sub = parseArgument()
            } else if chars[i] == "'" {
                i += 1
                sup = .char("′")
            } else {
                break
            }
        }
        return .scripted(base: base, sub: sub, sup: sup)
    }

    // MARK: Atoms

    private mutating func parseAtom() -> TeX? {
        guard i < chars.count else { return nil }
        let c = chars[i]
        switch c {
        case "{":
            i += 1
            let inner = parseSequence(stop: .brace)
            if i < chars.count, chars[i] == "}" { i += 1 }
            // `1{,}000`: a comma that is part of the number
            if inner.count == 1, case .char(let only) = inner[0], only == "," { return .command("delim:,") }
            return .group(inner)
        case "\\":
            return parseCommand()
        case "&":
            i += 1
            return .align
        case "~":
            i += 1
            return .space(" ")
        case "'":
            i += 1
            return .char("′")
        case "%":
            // a LaTeX comment runs to the end of the line
            while i < chars.count, chars[i] != "\n" { i += 1 }
            return nil
        default:
            i += 1
            return .char(c)
        }
    }

    /// The argument of a command or script: `{…}`, a command, or one character.
    private mutating func parseArgument() -> TeX {
        skipSpaces()
        guard i < chars.count else { return .group([]) }
        if chars[i] == "{" {
            i += 1
            let inner = parseSequence(stop: .brace)
            if i < chars.count, chars[i] == "}" { i += 1 }
            return .group(inner)
        }
        if chars[i] == "\\" { return parseCommand() ?? .group([]) }
        let c = chars[i]
        i += 1
        return .char(c)
    }

    private mutating func parseOptionalArgument() -> TeX? {
        skipSpaces()
        guard i < chars.count, chars[i] == "[" else { return nil }
        i += 1
        let inner = parseSequence(stop: .bracket)
        if i < chars.count, chars[i] == "]" { i += 1 }
        return .group(inner)
    }

    /// The text of a `{…}` argument, braces balanced, nothing interpreted.
    private mutating func parseRawArgument() -> String {
        skipSpaces()
        guard i < chars.count else { return "" }
        guard chars[i] == "{" else {
            let c = chars[i]
            i += 1
            return String(c)
        }
        i += 1
        var level = 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "{" || next == "}" { out.append(next); i += 2; continue }
                if next == " " || next == "," || next == ";" { out.append(" "); i += 2; continue }
                if next == "\\" { out.append(" "); i += 2; continue }
                if next == "%" || next == "$" || next == "#" || next == "&" || next == "_" { out.append(next); i += 2; continue }
            }
            if c == "{" { level += 1 }
            if c == "}" {
                level -= 1
                if level == 0 { i += 1; return out }
            }
            if c == "~" { out.append(" "); i += 1; continue }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: Commands

    private static let rawTextCommands: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "textnormal", "mbox", "hbox", "emph", "textup",
    ]
    private static let styledCommands: Set<String> = [
        "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathbb", "mathcal", "mathscr", "mathfrak",
        "boldsymbol", "bm", "operatorname", "mathop", "mathbin", "mathrel", "mathord", "mathnormal", "pmb",
    ]
    private static let noOpCommands: Set<String> = [
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "nonumber",
        "notag", "hline", "cline", "toprule", "midrule", "bottomrule", "left.", "right.", "relax", "protect",
        "mathstrut", "strut", "allowbreak", "centering", "normalsize", "small", "large", "Large",
    ]

    private mutating func parseCommand() -> TeX? {
        i += 1 // the backslash
        guard i < chars.count else { return .char("\\") }
        let first = chars[i]

        // single-character commands
        if !(first.isASCII && first.isLetter) {
            i += 1
            switch first {
            case ",", ";", ":", ">", " ": return .space(" ")
            case "!": return .space("")
            case "\\":
                skipSpaces()
                if i < chars.count, chars[i] == "[" {
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    if i < chars.count { i += 1 }
                }
                return .newline
            case "{", "}", "%", "$", "#", "&", "_": return .char(first)
            case "|": return .char("‖")
            default: return .command(String(first))
            }
        }

        var name = ""
        while i < chars.count, chars[i].isASCII, chars[i].isLetter { name.append(chars[i]); i += 1 }
        if (name == "operatorname" || name == "begin" || name == "end"), i < chars.count, chars[i] == "*" {
            // operatorname* ; begin/end names carry their own star inside braces
            if name == "operatorname" { i += 1 }
        }

        if Self.noOpCommands.contains(name) { return nil }
        if let macro = macros[name] { return .group(macro) }

        switch name {
        case "quad", "enspace", "thinspace", "medspace", "thickspace": return .space(" ")
        case "qquad": return .space("  ")
        case "hspace", "vspace", "kern", "mkern", "mskip", "hskip", "vskip", "rule":
            _ = parseRawArgument(); return .space(" ")
        case "label", "tag", "ref", "eqref", "cite":
            _ = parseRawArgument(); return nil
        case "color":
            _ = parseRawArgument(); return nil
        case "textcolor", "colorbox":
            _ = parseRawArgument(); return parseArgument()
        case "href":
            let url = parseRawArgument()
            return .two("href", .rawText(url), parseArgument())
        case "url":
            return .rawText(parseRawArgument())
        case "ce", "cf":
            return .chem(parseRawArgument())
        case "frac", "dfrac", "tfrac", "cfrac":
            let a = parseArgument(), b = parseArgument()
            return .frac(a, b)
        case "binom", "dbinom", "tbinom":
            let a = parseArgument(), b = parseArgument()
            return .binom(a, b)
        case "sqrt":
            let index = parseOptionalArgument()
            return .sqrt(index, parseArgument())
        case "boxed", "fbox", "framebox", "cancel", "bcancel", "xcancel", "underbrace", "overbrace", "phantom", "hphantom", "vphantom", "substack":
            if name == "substack" { return parseSubstack() }
            return .over(name, parseArgument())
        case "stackrel", "overset", "underset":
            let a = parseArgument(), b = parseArgument()
            return .two(name, a, b)
        case "xrightarrow", "xleftarrow", "xRightarrow", "xLeftarrow", "xleftrightarrow", "xmapsto", "xlongequal":
            let below = parseOptionalArgument()
            let above = parseArgument()
            return .arrow(name, above, below)
        case "not":
            skipSpaces()
            return .negated(parseArgument())
        case "left":
            return parseDelimited()
        case "right", "middle":
            let delim = readDelimiter()
            return .char(Character(MathSymbols.delimiterText(delim).isEmpty ? " " : String(MathSymbols.delimiterText(delim).first!)))
        case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "bigm", "Bigl", "Bigr", "Bigm", "biggl", "biggr", "biggm", "Biggl", "Biggr", "Biggm":
            let delim = readDelimiter()
            let text = MathSymbols.delimiterText(delim)
            return text.isEmpty ? nil : .command("delim:" + text)
        case "begin":
            return parseEnvironment()
        case "newcommand", "renewcommand", "providecommand", "def", "DeclareMathOperator":
            parseMacroDefinition(name)
            return nil
        default:
            break
        }

        if Self.rawTextCommands.contains(name) { return .rawText(parseRawArgument()) }
        if Self.styledCommands.contains(name) { return .styled(name, parseArgument()) }
        if MathSymbols.accents[name] != nil { return .accent(name, parseArgument()) }

        // a known symbol or function: no arguments
        if MathSymbols.atom(name) != nil
            || MathSymbols.bigOperators[name] != nil
            || MathSymbols.integrals[name] != nil
            || ["argmax", "argmin", "limits", "bmod", "pmod"].contains(name) {
            return .command(name)
        }

        // an unknown command: keep its brace arguments with it
        var args: [TeX] = []
        skipSpaces()
        while i < chars.count, chars[i] == "{" {
            args.append(parseArgument())
            skipSpaces()
        }
        return args.isEmpty ? .command(name) : .unknown(name, args)
    }

    private mutating func readDelimiter() -> String {
        skipSpaces()
        guard i < chars.count else { return "." }
        if chars[i] == "\\" {
            i += 1
            guard i < chars.count else { return "." }
            if chars[i].isASCII, chars[i].isLetter {
                var name = ""
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { name.append(chars[i]); i += 1 }
                return name
            }
            let c = chars[i]
            i += 1
            return "\\" + String(c)
        }
        let c = chars[i]
        i += 1
        return String(c)
    }

    private mutating func parseDelimited() -> TeX {
        let open = MathSymbols.delimiterText(readDelimiter())
        let inner = parseSequence(stop: .right)
        var close = ""
        if matches("\\right") {
            i += 6
            close = MathSymbols.delimiterText(readDelimiter())
        }
        return .delimited(open, inner, close)
    }

    private mutating func parseSubstack() -> TeX {
        let argument = parseArgument()
        if case .group(let nodes) = argument { return .env("substack", split(nodes)) }
        return argument
    }

    private mutating func parseEnvironment() -> TeX {
        let name = parseRawArgument()
        if name == "array" || name == "tabular" || name == "alignat" || name == "alignat*" || name == "tabularx" {
            _ = parseRawArgument() // column spec
        }
        let nodes = parseSequence(stop: .end)
        if matches("\\end{") {
            i += 4 // "\\end"; the braces and name are read as an argument
            _ = parseRawArgument()
        }
        return .env(name, split(nodes))
    }

    private func split(_ nodes: [TeX]) -> [[[TeX]]] {
        var rows: [[[TeX]]] = []
        var cells: [[TeX]] = []
        var cell: [TeX] = []
        for node in nodes {
            switch node {
            case .newline:
                cells.append(cell); cell = []
                rows.append(cells); cells = []
            case .align:
                cells.append(cell); cell = []
            default:
                cell.append(node)
            }
        }
        if !cell.isEmpty || !cells.isEmpty {
            cells.append(cell)
            rows.append(cells)
        }
        return rows.filter { row in row.contains { !$0.isEmpty } }
    }

    private mutating func parseMacroDefinition(_ command: String) {
        skipSpaces()
        var name = ""
        if i < chars.count, chars[i] == "{" {
            i += 1
            skipSpaces()
            if i < chars.count, chars[i] == "\\" {
                i += 1
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { name.append(chars[i]); i += 1 }
            }
            while i < chars.count, chars[i] != "}" { i += 1 }
            if i < chars.count { i += 1 }
        } else if i < chars.count, chars[i] == "\\" {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isLetter { name.append(chars[i]); i += 1 }
        }
        _ = parseOptionalArgument() // argument count: macros with arguments are not expanded
        skipSpaces()
        guard i < chars.count, chars[i] == "{" else { return }
        i += 1
        let body = parseSequence(stop: .brace)
        if i < chars.count, chars[i] == "}" { i += 1 }
        if command == "DeclareMathOperator" {
            // \DeclareMathOperator{\name}{text}
            macros[name] = [.styled("operatorname", .group(body))]
        } else if !name.isEmpty {
            macros[name] = body
        }
    }

    // MARK: Helpers

    private mutating func skipSpaces() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    private func matches(_ s: String) -> Bool {
        let pattern = Array(s)
        guard i + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[i + k] != pattern[k] { return false }
        return true
    }

    private func isLetter(at index: Int) -> Bool {
        index < chars.count && chars[index].isASCII && chars[index].isLetter
    }
}

// MARK: - Rendering

private struct Frag {
    var text: String
    var kind: MathAtomKind
    /// A space follows even before a bracket (`lim(x → 0) (…)`).
    var forcesSpace = false
}

private struct TeXRenderer {
    func string(_ nodes: [TeX]) -> String { join(frags(nodes)) }

    func frags(_ nodes: [TeX]) -> [Frag] { nodes.flatMap(frags) }

    func frags(_ node: TeX) -> [Frag] {
        switch node {
        case .char(let c): return [character(c)]
        case .command(let name): return [command(name)]
        case .group(let nodes): return frags(nodes)
        case .scripted(let base, let sub, let sup): return [scripted(base: base, sub: sub, sup: sup)]
        case .frac(let n, let d): return [fraction(n, d)]
        case .binom(let n, let k): return [binomial(n, k)]
        case .sqrt(let index, let arg): return [squareRoot(index: index, arg)]
        case .rawText(let s): return [Frag(text: s, kind: .text)]
        case .styled(let name, let arg): return [styled(name, arg)]
        case .accent(let name, let arg): return [accent(name, arg)]
        case .delimited(let open, let inner, let close):
            return [Frag(text: open + string(inner) + close, kind: .ordinary)]
        case .env(let name, let rows): return [environment(name, rows)]
        case .arrow(let name, let above, let below): return [arrow(name, above, below)]
        case .over(let name, let arg): return [over(name, arg)]
        case .two(let name, let a, let b): return [two(name, a, b)]
        case .negated(let arg): return [negated(arg)]
        case .unknown(let name, let args):
            let rendered = args.map { string([$0]) }.joined(separator: ", ")
            return [Frag(text: "\\\(name)(\(rendered))", kind: .ordinary)]
        case .chem(let s): return [Frag(text: chemistry(s), kind: .ordinary)]
        case .space(let s): return s.isEmpty ? [] : [Frag(text: s, kind: .space)]
        case .newline: return [Frag(text: "\n", kind: .space)]
        case .align: return []
        }
    }

    // MARK: Atoms

    private func character(_ c: Character) -> Frag {
        switch c {
        case "+": return Frag(text: "+", kind: .binary)
        case "-", "−": return Frag(text: "−", kind: .binary)
        case "*": return Frag(text: "∗", kind: .binary)
        case "=", "<", ">": return Frag(text: String(c), kind: .relation)
        case ":": return Frag(text: ":", kind: .relation)
        case ",", ";": return Frag(text: String(c), kind: .punctuation)
        case "(", "[": return Frag(text: String(c), kind: .open)
        case ")", "]": return Frag(text: String(c), kind: .close)
        default: return Frag(text: String(c), kind: .ordinary)
        }
    }

    private func command(_ name: String) -> Frag {
        if name.hasPrefix("delim:") {
            let text = String(name.dropFirst(6))
            let kind: MathAtomKind = text.contains(where: { "([{⟨⌈⌊".contains($0) }) ? .open
                : (text.contains(where: { ")]}⟩⌉⌋".contains($0) }) ? .close : .ordinary)
            return Frag(text: text, kind: kind)
        }
        if let big = MathSymbols.bigOperators[name] { return Frag(text: big, kind: .function, forcesSpace: true) }
        if let integral = MathSymbols.integrals[name] { return Frag(text: integral, kind: .function, forcesSpace: true) }
        if name == "argmax" || name == "argmin" { return Frag(text: name == "argmax" ? "arg max" : "arg min", kind: .function) }
        if let atom = MathSymbols.atom(name) { return Frag(text: atom.text, kind: atom.kind) }
        return Frag(text: "\\" + name, kind: .ordinary)
    }

    // MARK: Scripts

    private func scripted(base: TeX?, sub: TeX?, sup: TeX?) -> Frag {
        let subText = sub.map { string([$0]) }
        let supText = sup.map { string([$0]) }

        guard let base else {
            return Frag(text: (subText.flatMap(subscriptText) ?? "") + (supText.flatMap(superscriptText) ?? ""), kind: .ordinary)
        }

        // big operators and limits: Σ(i = 1〜n), ∫₀¹, lim(x → 0)
        if case .command(let name) = base {
            if let symbol = MathSymbols.bigOperators[name] {
                return Frag(text: symbol + limits(subText, supText, preferScripts: false), kind: .function, forcesSpace: true)
            }
            if let symbol = MathSymbols.integrals[name] {
                return Frag(text: symbol + limits(subText, supText, preferScripts: true), kind: .function, forcesSpace: true)
            }
            if MathSymbols.underLimitFunctions.contains(name) || name == "argmax" || name == "argmin" {
                let word = MathSymbols.functions[name] ?? (name == "argmax" ? "arg max" : "arg min")
                let under = subText.map { "(\($0))" } ?? ""
                return Frag(text: word + under + (supText.map(superscriptText) ?? ""), kind: .function, forcesSpace: subText != nil)
            }
        }
        if case .over(let kind, let inner) = base, kind == "underbrace" || kind == "overbrace" {
            let note = subText ?? supText ?? ""
            return Frag(text: string([inner]) + (note.isEmpty ? "" : " (\(note))"), kind: .ordinary)
        }

        let baseFrags = frags(base)
        let baseText = join(baseFrags)
        var kind = baseFrags.last?.kind ?? .ordinary
        if baseFrags.count > 1 { kind = .ordinary }
        var out = baseText
        if let subText { out += subscriptText(subText) }
        if let supText { out += superscriptText(supText) }
        // `log₂ 8` keeps its space, `sin²θ` does not
        if kind == .function, sub == nil { kind = .ordinary }
        if kind == .binary || kind == .relation { kind = .ordinary }
        return Frag(text: out, kind: kind)
    }

    private func superscriptText(_ s: String) -> String {
        let compact = s.trimmingCharacters(in: .whitespaces)
        if compact == "∘" || compact == "°" { return "°" }
        if let converted = MathSymbols.superscript(compact) { return converted }
        return "^" + (isSingleToken(compact) ? compact : "(\(compact))")
    }

    private func subscriptText(_ s: String) -> String {
        let compact = s.trimmingCharacters(in: .whitespaces)
        if let converted = MathSymbols.subscripted(compact) { return converted }
        return "_" + (isSingleToken(compact) ? compact : "(\(compact))")
    }

    /// Limits of a sum or integral: `(i = 1〜n)`, or `₀¹` when both fit in
    /// Unicode scripts and `preferScripts` is set.
    private func limits(_ lower: String?, _ upper: String?, preferScripts: Bool) -> String {
        if preferScripts {
            let lo = lower.map { MathSymbols.subscripted($0) }
            let up = upper.map { MathSymbols.superscript($0) }
            if (lower == nil || lo! != nil) && (upper == nil || up! != nil) {
                return (lo.flatMap { $0 } ?? "") + (up.flatMap { $0 } ?? "")
            }
        }
        switch (lower, upper) {
        case (let lo?, let up?): return "(\(lo)〜\(up))"
        case (let lo?, nil): return "(\(lo))"
        case (nil, let up?): return "^(\(up))"
        default: return ""
        }
    }

    // MARK: Structures

    private func fraction(_ n: TeX, _ d: TeX) -> Frag {
        let numerator = string([n])
        let denominator = string([d])
        let top = isAtomic(numerator) ? numerator : "(\(numerator))"
        let bottom = isSingleToken(denominator) ? denominator : "(\(denominator))"
        return Frag(text: "\(top)/\(bottom)", kind: .ordinary)
    }

    private func binomial(_ n: TeX, _ k: TeX) -> Frag {
        let top = string([n]), bottom = string([k])
        if let sub = MathSymbols.subscripted(top), let low = MathSymbols.subscripted(bottom) {
            return Frag(text: "\(sub)C\(low)", kind: .ordinary)
        }
        return Frag(text: "C(\(top), \(bottom))", kind: .ordinary)
    }

    private func squareRoot(index: TeX?, _ arg: TeX) -> Frag {
        let inner = string([arg])
        let radicand = isPlainToken(inner) ? inner : "(\(inner))"
        guard let index else { return Frag(text: "√" + radicand, kind: .ordinary) }
        let n = string([index])
        let prefix = MathSymbols.superscript(n) ?? "[\(n)]"
        return Frag(text: prefix + "√" + radicand, kind: .ordinary)
    }

    private func styled(_ name: String, _ arg: TeX) -> Frag {
        let inner = joinTight(frags([arg]))
        switch name {
        case "mathbb":
            return Frag(text: String(inner.map { MathSymbols.blackboard[$0].map(Character.init) ?? $0 }.map(String.init).joined()), kind: .ordinary)
        case "mathcal", "mathscr":
            let mapped = inner.map { MathSymbols.script[$0] ?? String($0) }.joined()
            return Frag(text: mapped, kind: .ordinary)
        case "operatorname", "mathop":
            return Frag(text: inner, kind: .function)
        default:
            return Frag(text: inner, kind: .ordinary)
        }
    }

    private func accent(_ name: String, _ arg: TeX) -> Frag {
        let inner = joinTight(frags([arg]))
        guard let mark = MathSymbols.accents[name], !inner.isEmpty else { return Frag(text: inner, kind: .ordinary) }
        if MathSymbols.accentsOnEveryCharacter.contains(name) {
            return Frag(text: inner.map { "\($0)\(mark)" }.joined(), kind: .ordinary)
        }
        return Frag(text: inner + mark, kind: .ordinary)
    }

    private func over(_ name: String, _ arg: TeX) -> Frag {
        let inner = string([arg])
        switch name {
        case "boxed", "fbox", "framebox": return Frag(text: "[\(inner)]", kind: .ordinary)
        case "cancel", "bcancel", "xcancel": return Frag(text: inner.map { "\($0)\u{0336}" }.joined(), kind: .ordinary)
        case "phantom", "hphantom", "vphantom": return Frag(text: "", kind: .space)
        default: return Frag(text: inner, kind: .ordinary)
        }
    }

    private func two(_ name: String, _ a: TeX, _ b: TeX) -> Frag {
        switch name {
        case "href": return Frag(text: "\(string([b])) (\(string([a])))", kind: .ordinary)
        case "stackrel", "overset":
            let note = string([a]), base = string([b])
            return Frag(text: base + (MathSymbols.superscript(note) ?? "(\(note))"), kind: .relation)
        default: // underset
            let note = string([a]), base = string([b])
            return Frag(text: base + (MathSymbols.subscripted(note) ?? "(\(note))"), kind: .relation)
        }
    }

    private func arrow(_ name: String, _ above: TeX?, _ below: TeX?) -> Frag {
        let top = above.map { string([$0]) } ?? ""
        let label = top.isEmpty ? (below.map { string([$0]) } ?? "") : top
        let left = name.contains("left")
        switch name {
        case "xlongequal": return Frag(text: label.isEmpty ? "＝" : "=\(label)=", kind: .relation)
        default:
            let head = name.hasPrefix("xR") ? "⇒" : (name.hasPrefix("xL") ? "⇐" : (left ? "←" : "→"))
            let body = label.isEmpty ? head : (left ? "\(head)\(label)─" : "─\(label)\(head)")
            return Frag(text: body, kind: .relation)
        }
    }

    private func negated(_ arg: TeX) -> Frag {
        let inner = string([arg])
        let table = ["=": "≠", "∈": "∉", "⊂": "⊄", "⊆": "⊈", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱", "∋": "∌", "≡": "≢", "≈": "≉", "∣": "∤", "|": "∤"]
        return Frag(text: table[inner] ?? (inner + "\u{0338}"), kind: .relation)
    }

    private func chemistry(_ s: String) -> String {
        var out = ""
        var previous: Character?
        var index = s.startIndex
        while index < s.endIndex {
            let c = s[index]
            if c.isNumber, let p = previous, p.isLetter || p == ")" || p == "]" {
                out.append(MathSymbols.subscripts[c] ?? c)
            } else if c == "^" {
                index = s.index(after: index)
                var charge = ""
                if index < s.endIndex, s[index] == "{" {
                    index = s.index(after: index)
                    while index < s.endIndex, s[index] != "}" { charge.append(s[index]); index = s.index(after: index) }
                } else if index < s.endIndex {
                    charge.append(s[index])
                }
                out += MathSymbols.superscript(charge.replacingOccurrences(of: "−", with: "-")) ?? "^\(charge)"
                if index < s.endIndex { index = s.index(after: index) }
                previous = nil
                continue
            } else if c == "-", s[index...].hasPrefix("->") {
                out += " → "
                index = s.index(index, offsetBy: 2)
                previous = nil
                continue
            } else if c == "<", s[index...].hasPrefix("<=>") {
                out += " ⇌ "
                index = s.index(index, offsetBy: 3)
                previous = nil
                continue
            } else {
                out.append(c)
            }
            previous = c
            index = s.index(after: index)
        }
        return out
    }

    // MARK: Environments

    private func environment(_ name: String, _ rows: [[[TeX]]]) -> Frag {
        let rowStrings = rows.map { row in row.map { string($0) } }
        func listRows(_ separator: String) -> String {
            rowStrings.map { $0.joined(separator: separator) }.joined(separator: "; ")
        }
        switch name {
        case "pmatrix": return Frag(text: "(\(listRows(", ")))", kind: .ordinary)
        case "bmatrix", "matrix", "smallmatrix": return Frag(text: "[\(listRows(", "))]", kind: .ordinary)
        case "Bmatrix": return Frag(text: "{\(listRows(", "))}", kind: .ordinary)
        case "vmatrix": return Frag(text: "|\(listRows(", "))|", kind: .ordinary)
        case "Vmatrix": return Frag(text: "‖\(listRows(", "))‖", kind: .ordinary)
        case "cases":
            let body = rows.map { row in join(row.flatMap { frags($0) + [Frag(text: " ", kind: .space)] }) }.joined(separator: "; ")
            return Frag(text: "{ \(body) }", kind: .ordinary)
        case "array", "tabular", "tabularx":
            return Frag(text: rowStrings.map { $0.joined(separator: " | ") }.joined(separator: "\n"), kind: .ordinary)
        case "substack":
            return Frag(text: rowStrings.map { $0.joined(separator: " ") }.joined(separator: ", "), kind: .ordinary)
        default:
            // aligned, align, gather, equation, split, …: one line per row
            let lines = rows.map { row in join(row.flatMap { frags($0) + [Frag(text: " ", kind: .space)] }) }
            return Frag(text: lines.joined(separator: "\n"), kind: .ordinary)
        }
    }

    // MARK: Laying fragments out

    /// Joins fragments with the spaces plain text needs: around `=`, `+`,
    /// after commas and function names, none inside brackets.
    func join(_ fragments: [Frag]) -> String {
        var out = ""
        var previous: Frag?
        var pendingSpace = false
        var previousWasUnary = false

        for fragment in fragments {
            if fragment.kind == .space {
                if fragment.text == "\n" {
                    out += "\n"
                    previous = nil
                    pendingSpace = false
                    previousWasUnary = false
                } else {
                    pendingSpace = true
                }
                continue
            }
            if fragment.text.isEmpty { continue }

            var kind = fragment.kind
            var isUnary = false
            if kind == .binary {
                if let p = previous {
                    if [.open, .relation, .binary, .punctuation].contains(p.kind) || (p.kind == .function && !p.forcesSpace) {
                        isUnary = true
                    }
                } else {
                    isUnary = true
                }
                if isUnary { kind = .ordinary }
            }

            var separator = ""
            if let p = previous {
                switch kind {
                case .relation: separator = " "
                case .binary: separator = " "
                case .punctuation, .close: separator = ""
                case .open:
                    separator = (p.forcesSpace || p.kind == .relation || p.kind == .binary || p.kind == .punctuation) && !previousWasUnary ? " " : ""
                case .ordinary, .function, .text:
                    if previousWasUnary { separator = "" }
                    else if [.relation, .binary, .punctuation].contains(p.kind) { separator = " " }
                    else if p.kind == .function || p.forcesSpace { separator = " " }
                    else if kind == .function && [.ordinary, .close].contains(p.kind) { separator = " " }
                    else { separator = "" }
                case .space: break
                }
            }
            if pendingSpace && separator.isEmpty && !out.isEmpty && !out.hasSuffix("\n") { separator = " " }
            out += separator + fragment.text
            pendingSpace = false
            previousWasUnary = isUnary
            var recorded = fragment
            recorded.kind = kind
            previous = recorded
        }
        return out
    }

    /// Joins with no added spaces (inside `\mathrm{…}` and accents).
    private func joinTight(_ fragments: [Frag]) -> String {
        fragments.map(\.text).joined()
    }

    // MARK: Deciding when brackets are needed

    /// A product of plain factors with nothing to split on at the top level,
    /// such as `k(k + 1)` or `x²`; safe to put next to `/` or `√` unbracketed
    /// as a numerator.
    func isAtomic(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var level = 0
        for c in s {
            if "([{⟨".contains(c) { level += 1; continue }
            if ")]}⟩".contains(c) { level -= 1; continue }
            if level > 0 { continue }
            if c.isWhitespace || "+−±∓×÷=<>≤≥≠≈/,;:|".contains(c) { return false }
        }
        return level == 0
    }

    /// One number, one letter with its scripts, or one bracketed group: what
    /// can follow `/` or `√` or `^` without being mistaken for a product.
    func isSingleToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil { return true }
        if let first = s.first, "([{⟨".contains(first), isBracketed(s) { return true }
        // a differential (dx, ∂x), a factorial (n!)
        if s.range(of: #"^[d∂][A-Za-z]$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[A-Za-z]!$"#, options: .regularExpression) != nil { return true }
        // a call: f(x), P(A ∩ B)
        if let open = s.firstIndex(where: { "([{⟨".contains($0) }), open != s.startIndex,
           s[s.startIndex..<open].allSatisfy({ $0.isLetter }), isBracketed(String(s[open...])) { return true }
        // a Japanese word
        if s.allSatisfy({ !$0.isASCII && $0.isLetter }) { return true }
        var iterator = s.makeIterator()
        guard let head = iterator.next(), head.isLetter else { return false }
        while let c = iterator.next() {
            let scalars = c.unicodeScalars
            let isMark = scalars.allSatisfy { CharacterSet.nonBaseCharacters.contains($0) }
            let isScript = MathSymbols.superscripts.values.contains(c) || MathSymbols.subscripts.values.contains(c) || c == "′"
            if !(isMark || isScript) { return false }
        }
        return true
    }

    /// A number, one letter, or a bracketed group: unambiguous after `√`.
    /// `x²` is not (√x² could be (√x)²).
    func isPlainToken(_ s: String) -> Bool {
        if s.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil { return true }
        if s.count == 1, s.first!.isLetter { return true }
        if let first = s.first, "([{⟨".contains(first), isBracketed(s) { return true }
        return false
    }

    private func isBracketed(_ s: String) -> Bool {
        var level = 0
        for (offset, c) in s.enumerated() {
            if "([{⟨".contains(c) { level += 1 }
            if ")]}⟩".contains(c) {
                level -= 1
                if level == 0 && offset != s.count - 1 { return false }
            }
        }
        return level == 0
    }
}
