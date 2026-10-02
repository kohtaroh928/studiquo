import Foundation

/// A piece of AI output, split by what it is.
///
/// Models write math in LaTeX between delimiters (`$…$`, `$$…$$`, `\(…\)`,
/// `\[…\]`, or a bare `\begin{align}…`), mixed into Japanese prose and
/// Markdown. Splitting it out is the first step of every way of showing it:
/// the plain-text converter, the block parser and the on-screen renderer all
/// start from these segments.
enum MathSegment: Equatable {
    case text(String)
    case inlineMath(String)
    case displayMath(String)
    /// Inline code or a fenced block, verbatim including the backticks.
    /// Never converted: `\frac` inside code is meant literally.
    case code(String)
    /// An opened but unclosed `$…` / `\[…` / `\begin{…}`, verbatim. A reply
    /// that is still streaming is in this state until the closing delimiter
    /// arrives.
    case incomplete(String)
}

enum MathSegmenter {
    /// Environments that are display math even without `$$` around them.
    static let displayEnvironments: Set<String> = [
        "align", "align*", "aligned", "alignat", "alignat*", "gather", "gather*", "gathered",
        "equation", "equation*", "eqnarray", "eqnarray*", "multline", "multline*", "flalign", "flalign*",
        "split", "cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "array",
        "smallmatrix", "math", "displaymath",
    ]

    static func segments(in source: String) -> [MathSegment] {
        var scanner = Scanner(Array(source))
        var result: [MathSegment] = []
        var text = ""

        func flush() {
            if !text.isEmpty { result.append(.text(text)); text = "" }
        }

        while !scanner.isAtEnd {
            let i = scanner.index

            // Fenced code, only at the start of a line.
            if scanner.isAtLineStart, let fence = scanner.fenceMarker() {
                flush()
                let end = scanner.endOfFence(marker: fence)
                result.append(.code(scanner.substring(i, end)))
                scanner.index = end
                continue
            }
            // Inline code.
            if scanner.current == "`", let end = scanner.endOfInlineCode() {
                flush()
                result.append(.code(scanner.substring(i, end)))
                scanner.index = end
                continue
            }
            // Escaped dollar: a literal "$".
            if scanner.matches("\\$") {
                text.append("$")
                scanner.index += 2
                continue
            }
            if scanner.matches("$$") {
                if let close = scanner.find("$$", from: i + 2) {
                    flush()
                    result.append(.displayMath(scanner.trimmed(i + 2, close)))
                    scanner.index = close + 2
                } else {
                    flush()
                    result.append(.incomplete(scanner.substring(i, scanner.count)))
                    scanner.index = scanner.count
                }
                continue
            }
            if scanner.matches("\\[") {
                if let close = scanner.find("\\]", from: i + 2) {
                    flush()
                    result.append(.displayMath(scanner.trimmed(i + 2, close)))
                    scanner.index = close + 2
                } else {
                    flush()
                    result.append(.incomplete(scanner.substring(i, scanner.count)))
                    scanner.index = scanner.count
                }
                continue
            }
            if scanner.matches("\\(") {
                if let close = scanner.find("\\)", from: i + 2) {
                    flush()
                    result.append(.inlineMath(scanner.trimmed(i + 2, close)))
                    scanner.index = close + 2
                } else {
                    flush()
                    result.append(.incomplete(scanner.substring(i, scanner.count)))
                    scanner.index = scanner.count
                }
                continue
            }
            if scanner.matches("\\begin{"), let name = scanner.environmentName(at: i), displayEnvironments.contains(name) {
                let closing = "\\end{\(name)}"
                if let close = scanner.find(closing, from: i) {
                    flush()
                    result.append(.displayMath(scanner.substring(i, close + closing.count)))
                    scanner.index = close + closing.count
                } else {
                    flush()
                    result.append(.incomplete(scanner.substring(i, scanner.count)))
                    scanner.index = scanner.count
                }
                continue
            }
            if scanner.current == "$" {
                switch scanner.inlineDollar(at: i) {
                case .math(let content, let end):
                    flush()
                    result.append(.inlineMath(content))
                    scanner.index = end
                    continue
                case .incomplete:
                    flush()
                    result.append(.incomplete(scanner.substring(i, scanner.endOfParagraph(from: i))))
                    scanner.index = scanner.endOfParagraph(from: i)
                    continue
                case .literal:
                    break
                }
            }
            text.append(scanner.advance())
        }
        flush()
        return merged(result)
    }

    private static func merged(_ segments: [MathSegment]) -> [MathSegment] {
        var out: [MathSegment] = []
        for segment in segments {
            if case .text(let b) = segment, case .text(let a)? = out.last {
                out[out.count - 1] = .text(a + b)
            } else {
                out.append(segment)
            }
        }
        return out
    }

    // MARK: Scanner

    private struct Scanner {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var count: Int { chars.count }
        var isAtEnd: Bool { index >= chars.count }
        var current: Character? { index < chars.count ? chars[index] : nil }
        var isAtLineStart: Bool { index == 0 || chars[index - 1] == "\n" }

        mutating func advance() -> Character {
            defer { index += 1 }
            return chars[index]
        }

        func matches(_ s: String, at i: Int? = nil) -> Bool {
            let at = i ?? index
            let pattern = Array(s)
            guard at + pattern.count <= chars.count else { return false }
            for k in 0..<pattern.count where chars[at + k] != pattern[k] { return false }
            return true
        }

        func substring(_ from: Int, _ to: Int) -> String { String(chars[from..<min(to, chars.count)]) }
        func trimmed(_ from: Int, _ to: Int) -> String {
            substring(from, to).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Next occurrence of `closing` at or after `start`, skipping
        /// backslash-escaped characters (so `\$` and `\\` do not match).
        func find(_ closing: String, from start: Int) -> Int? {
            var j = start
            let startsWithBackslash = closing.first == "\\"
            while j < chars.count {
                if matches(closing, at: j) { return j }
                if chars[j] == "\\" && !startsWithBackslash { j += 2 } else { j += 1 }
            }
            return nil
        }

        func endOfParagraph(from start: Int) -> Int {
            var j = start
            while j < chars.count {
                if chars[j] == "\n", j + 1 < chars.count, chars[j + 1] == "\n" { return j }
                j += 1
            }
            return chars.count
        }

        func environmentName(at i: Int) -> String? {
            let open = Array("\\begin{")
            var j = i + open.count
            var name = ""
            while j < chars.count, chars[j] != "}" {
                name.append(chars[j]); j += 1
                if name.count > 30 { return nil }
            }
            return j < chars.count ? name : nil
        }

        // Code ---------------------------------------------------------

        func fenceMarker() -> String? {
            for marker in ["```", "~~~"] where matches(marker) { return marker }
            return nil
        }

        /// End of a fenced block: after the closing fence line, or the end of
        /// the text when it has not arrived yet.
        func endOfFence(marker: String) -> Int {
            var j = index
            // skip the opening line
            while j < chars.count, chars[j] != "\n" { j += 1 }
            while j < chars.count {
                j += 1 // past "\n"
                if matches(marker, at: j) {
                    while j < chars.count, chars[j] != "\n" { j += 1 }
                    return j
                }
                while j < chars.count, chars[j] != "\n" { j += 1 }
            }
            return chars.count
        }

        /// End of a `…` span, or nil when it never closes in this paragraph.
        func endOfInlineCode() -> Int? {
            var run = 0
            var j = index
            while j < chars.count, chars[j] == "`" { run += 1; j += 1 }
            let marker = String(repeating: "`", count: run)
            let limit = endOfParagraph(from: j)
            var k = j
            while k < limit {
                if matches(marker, at: k), (k + run >= chars.count || chars[k + run] != "`") {
                    return k + run
                }
                k += 1
            }
            return nil
        }

        // Single dollar -------------------------------------------------

        enum Dollar {
            case math(String, end: Int)
            case incomplete
            case literal
        }

        func inlineDollar(at i: Int) -> Dollar {
            let limit = endOfParagraph(from: i + 1)
            guard i + 1 < chars.count, !chars[i + 1].isWhitespace else { return .literal }
            // closing: next unescaped "$" that is not the start of "$$"
            var j = i + 1
            while j < limit {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "$" { break }
                j += 1
            }
            guard j < limit, chars[j] == "$" else {
                // never closed: a half-streamed formula, or a stray dollar
                let rest = substring(i + 1, limit)
                let looksLikeMath = rest.contains("\\") || rest.contains("^") || rest.contains("_") || rest.contains("{")
                return looksLikeMath ? .incomplete : .literal
            }
            let content = substring(i + 1, j)
            guard !content.isEmpty,
                  !(content.last?.isWhitespace ?? true),
                  // a price such as "$5 and $10": the closing "$" opens the next one
                  !(j + 1 < chars.count && chars[j + 1].isASCII && chars[j + 1].isNumber),
                  // Japanese prose without any LaTeX command is not a formula
                  !(MathSegmenter.containsJapanese(content) && !content.contains("\\"))
            else { return .literal }
            return .math(content, end: j + 1)
        }
    }

    static func containsJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x3000...0x30FF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }
    }
}
