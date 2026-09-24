import Foundation
import SwiftUI

/// A parsed math expression tree, from the small LaTeX-like subset an
/// equation block's source text is written in (see `MathExpressionParser`).
/// Deliberately not a full LaTeX/OMML implementation — fractions,
/// superscripts, subscripts, square roots, and the common Greek letters and
/// operators a student's notes actually need, rendered by
/// `MathExpressionView`.
indirect enum MathExpression: Equatable {
    case sequence([MathExpression])
    /// A number, a single-letter variable, or any other single character
    /// (`+`, `-`, `=`, parentheses, …) standing for itself.
    case text(String)
    /// A resolved `\command`'s display glyph, e.g. `\pi` → "π".
    case symbol(String)
    case fraction(MathExpression, MathExpression)
    case superscript(MathExpression, MathExpression)
    case subscriptExpression(MathExpression, MathExpression)
    case sqrt(MathExpression)
}

enum MathExpressionParser {
    /// Known `\command` names and what they render as — not a complete LaTeX
    /// symbol table, just the Greek letters and operators most likely to
    /// show up in a student's notes.
    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "kappa": "κ", "lambda": "λ",
        "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω", "Gamma": "Γ", "Theta": "Θ",
        "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "leq": "≤", "geq": "≥", "neq": "≠", "approx": "≈", "equiv": "≡",
        "infty": "∞", "cdot": "·", "sum": "Σ", "int": "∫", "partial": "∂",
        "rightarrow": "→", "leftarrow": "←", "in": "∈", "forall": "∀", "exists": "∃",
    ]

    static func parse(_ source: String) -> MathExpression {
        var scanner = Scanner(text: Array(source))
        return .sequence(parseSequence(&scanner, stopAt: nil))
    }

    private struct Scanner {
        let text: [Character]
        var index = 0

        var isAtEnd: Bool { index >= text.count }
        var current: Character? { isAtEnd ? nil : text[index] }

        @discardableResult
        mutating func advance() -> Character? {
            guard !isAtEnd else { return nil }
            defer { index += 1 }
            return text[index]
        }

        mutating func skipWhitespace() {
            while current == " " { index += 1 }
        }
    }

    private static func parseSequence(_ scanner: inout Scanner, stopAt: Character?) -> [MathExpression] {
        var terms: [MathExpression] = []
        scanner.skipWhitespace()
        while let c = scanner.current, c != stopAt {
            terms.append(parseFactor(&scanner))
            scanner.skipWhitespace()
        }
        return terms
    }

    /// `{...}` groups into one sequence; a bare atom (no braces) counts as
    /// its own one-token group — what lets `x^2` work without writing
    /// `x^{2}`.
    private static func parseGroup(_ scanner: inout Scanner) -> MathExpression {
        scanner.skipWhitespace()
        if scanner.current == "{" {
            scanner.advance()
            let inner = parseSequence(&scanner, stopAt: "}")
            if scanner.current == "}" { scanner.advance() }
            return .sequence(inner)
        }
        // An unbraced argument is exactly one character — standard LaTeX
        // convention (`x^123` means `x¹` followed by the literal text `23`,
        // not `x¹²³`; write `x^{123}` for a multi-character exponent). This
        // also has to hold for `\frac`'s two bare arguments specifically:
        // reusing `parseFactor`/`parseAtom` here would let its multi-digit
        // number rule swallow both digits of `\frac12` into the numerator,
        // leaving nothing for the denominator.
        guard let c = scanner.advance() else { return .text("") }
        if c == "\\" {
            var name = ""
            while let c2 = scanner.current, c2.isLetter {
                name.append(c2)
                scanner.advance()
            }
            return .symbol(symbols[name] ?? name)
        }
        return .text(String(c))
    }

    /// An atom, followed by any number of `^`/`_` superscript/subscript
    /// suffixes (so `x^2_i` attaches both to the same base, left to right).
    private static func parseFactor(_ scanner: inout Scanner) -> MathExpression {
        scanner.skipWhitespace()
        var base = parseAtom(&scanner)
        while true {
            if scanner.current == "^" {
                scanner.advance()
                base = .superscript(base, parseGroup(&scanner))
            } else if scanner.current == "_" {
                scanner.advance()
                base = .subscriptExpression(base, parseGroup(&scanner))
            } else {
                break
            }
        }
        return base
    }

    private static func parseAtom(_ scanner: inout Scanner) -> MathExpression {
        scanner.skipWhitespace()
        guard let c = scanner.current else { return .text("") }

        if c == "\\" {
            scanner.advance()
            var name = ""
            while let c2 = scanner.current, c2.isLetter {
                name.append(c2)
                scanner.advance()
            }
            switch name {
            case "frac":
                let numerator = parseGroup(&scanner)
                let denominator = parseGroup(&scanner)
                return .fraction(numerator, denominator)
            case "sqrt":
                return .sqrt(parseGroup(&scanner))
            default:
                return .symbol(symbols[name] ?? name)
            }
        }

        if c == "{" {
            return parseGroup(&scanner)
        }

        // A digit run (a number, optionally with a decimal point) or a
        // single letter (one variable) — kept to single tokens, not a
        // greedy multi-letter run, so `x^2` attaches the exponent to `x`
        // alone rather than to an entire preceding word.
        if c.isNumber {
            var run = ""
            while let c2 = scanner.current, c2.isNumber || c2 == "." {
                run.append(c2)
                scanner.advance()
            }
            return .text(run)
        }
        if c.isLetter {
            scanner.advance()
            return .text(String(c))
        }

        // Any other single character (`+`, `-`, `=`, `(`, `)`, …) stands
        // for itself.
        scanner.advance()
        return .text(String(c))
    }
}

/// Renders a `MathExpression` recursively — a fraction as a numerator over a
/// rule over a denominator, a superscript/subscript as a smaller, offset
/// sibling, a square root as a radical glyph plus an overline. Not a real
/// typesetting engine (no kerning, no italic-vs-upright distinction between
/// variables and function names, fixed relative sizing rather than proper
/// math-font metrics) — a purpose-built renderer for the small expression
/// tree `MathExpressionParser` produces, not a general one.
struct MathExpressionView: View {
    let expression: MathExpression
    var fontSize: CGFloat = 17

    var body: some View {
        switch expression {
        case .sequence(let items):
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MathExpressionView(expression: item, fontSize: fontSize)
                }
            }
        case .text(let string):
            Text(string.isEmpty ? " " : string)
                .font(.system(size: fontSize, design: .serif).italic())
        case .symbol(let glyph):
            Text(glyph)
                .font(.system(size: fontSize, design: .serif))
        case .fraction(let numerator, let denominator):
            VStack(spacing: 2) {
                MathExpressionView(expression: numerator, fontSize: fontSize * 0.85)
                Rectangle().frame(height: 1)
                MathExpressionView(expression: denominator, fontSize: fontSize * 0.85)
            }
            .fixedSize()
        case .superscript(let base, let exponent):
            HStack(alignment: .top, spacing: 0) {
                MathExpressionView(expression: base, fontSize: fontSize)
                MathExpressionView(expression: exponent, fontSize: fontSize * 0.65)
                    .offset(y: -fontSize * 0.3)
            }
        case .subscriptExpression(let base, let sub):
            HStack(alignment: .bottom, spacing: 0) {
                MathExpressionView(expression: base, fontSize: fontSize)
                MathExpressionView(expression: sub, fontSize: fontSize * 0.65)
                    .offset(y: fontSize * 0.25)
            }
        case .sqrt(let inner):
            HStack(alignment: .top, spacing: 2) {
                Text("√").font(.system(size: fontSize, design: .serif))
                MathExpressionView(expression: inner, fontSize: fontSize)
                    .padding(.top, 2)
                    .overlay(alignment: .top) { Rectangle().frame(height: 1) }
            }
        }
    }
}

// MARK: - Editable equation tree (fill-in-the-blank editor)

/// The mutable tree behind the equation editor: a Word-style "insert a
/// structure, then tap each blank to fill it" editor rather than a raw
/// LaTeX text field. A reference type (unlike `MathExpression`) so each
/// blank/run has a stable identity a tap can target and a mutation can
/// update in place, and so the same numerator box that was blank a moment
/// ago is still the thing the user is typing into after it becomes `.text`.
final class MathNode: ObservableObject, Identifiable {
    let id = UUID()
    @Published var kind: Kind
    /// Unowned-ish back-pointer used only to know how to delete/collapse
    /// this node on backspace — never used to traverse downward, so a
    /// retain cycle isn't a concern, but `weak` avoids one anyway.
    weak var parent: MathNode?

    enum Kind {
        /// An empty slot the user hasn't filled in yet — rendered as a
        /// dashed box, the way Word's equation placeholders look.
        case blank
        /// A run of typed characters (digits, letters, operators, or a
        /// pasted-in Greek glyph) — grows by appending to the same node
        /// while it stays selected.
        case text(String)
        case sequence([MathNode])
        case fraction(MathNode, MathNode)
        case power(MathNode, MathNode)
        case sub(MathNode, MathNode)
        case sqrt(MathNode)
    }

    init(_ kind: Kind, parent: MathNode? = nil) {
        self.kind = kind
        self.parent = parent
    }

    /// Depth-first search for the node with `id`, starting at `self`.
    func find(_ id: UUID) -> MathNode? {
        if self.id == id { return self }
        switch kind {
        case .blank, .text:
            return nil
        case .sequence(let children):
            for child in children {
                if let found = child.find(id) { return found }
            }
            return nil
        case .fraction(let a, let b), .power(let a, let b), .sub(let a, let b):
            return a.find(id) ?? b.find(id)
        case .sqrt(let inner):
            return inner.find(id)
        }
    }

    /// The first unfilled blank in this subtree, in reading order — what a
    /// freshly-inserted template (e.g. a fraction) selects automatically so
    /// the user can start typing the numerator right away.
    func firstBlank() -> MathNode? {
        switch kind {
        case .blank:
            return self
        case .text:
            return nil
        case .sequence(let children):
            for child in children {
                if let found = child.firstBlank() { return found }
            }
            return nil
        case .fraction(let a, let b), .power(let a, let b), .sub(let a, let b):
            return a.firstBlank() ?? b.firstBlank()
        case .sqrt(let inner):
            return inner.firstBlank()
        }
    }

    /// Serializes this subtree back into the small LaTeX-like syntax
    /// `MathExpressionParser` reads, so the result stays compatible with
    /// the read-only renderer used everywhere an equation block is
    /// displayed (see `MathExpressionView`/`DocumentEquationBlockView`). A
    /// numerator/denominator/base/exponent/radicand is always wrapped in
    /// `{}` even when it's a single character — required so a multi-token
    /// run (e.g. "2x") groups as one unit instead of only the token right
    /// before `^`/`_` binding to it.
    func toSource() -> String {
        switch kind {
        case .blank:
            return "□"
        case .text(let s):
            return s.isEmpty ? "□" : s
        case .sequence(let children):
            return children.map { $0.toSource() }.joined()
        case .fraction(let numerator, let denominator):
            return "\\frac{\(numerator.toSource())}{\(denominator.toSource())}"
        case .power(let base, let exponent):
            return "{\(base.toSource())}^{\(exponent.toSource())}"
        case .sub(let base, let subscriptNode):
            return "{\(base.toSource())}_{\(subscriptNode.toSource())}"
        case .sqrt(let inner):
            return "\\sqrt{\(inner.toSource())}"
        }
    }

    /// Rebuilds an editable tree from a `MathExpression` (what
    /// `MathExpressionParser.parse` produces from a stored `equationSource`
    /// string) — how an equation written before this editor existed, or
    /// saved by it, opens for further editing. A lone "□" text token
    /// (`toSource()`'s own blank marker) round-trips back into `.blank`.
    static func from(_ expression: MathExpression, parent: MathNode? = nil) -> MathNode {
        switch expression {
        case .sequence(let items):
            let node = MathNode(.blank, parent: parent)
            let children = items.map { from($0, parent: node) }
            node.kind = .sequence(children)
            return node
        case .text(let s):
            return MathNode(s == "□" ? .blank : .text(s), parent: parent)
        case .symbol(let glyph):
            // The editor has no separate "upright symbol" concept — a
            // Greek letter typed from the keypad is just another character
            // in a text run. Re-opening an equation that used `\pi` etc.
            // folds it back into plain text the same way.
            return MathNode(.text(glyph), parent: parent)
        case .fraction(let numerator, let denominator):
            let node = MathNode(.blank, parent: parent)
            let n = from(numerator, parent: node)
            let d = from(denominator, parent: node)
            node.kind = .fraction(n, d)
            return node
        case .superscript(let base, let exponent):
            let node = MathNode(.blank, parent: parent)
            let b = from(base, parent: node)
            let e = from(exponent, parent: node)
            node.kind = .power(b, e)
            return node
        case .subscriptExpression(let base, let subscriptExpr):
            let node = MathNode(.blank, parent: parent)
            let b = from(base, parent: node)
            let s = from(subscriptExpr, parent: node)
            node.kind = .sub(b, s)
            return node
        case .sqrt(let inner):
            let node = MathNode(.blank, parent: parent)
            let i = from(inner, parent: node)
            node.kind = .sqrt(i)
            return node
        }
    }

    /// A brand-new, empty equation: one blank waiting to be tapped.
    static func empty() -> MathNode {
        let root = MathNode(.blank)
        let blank = MathNode(.blank, parent: root)
        root.kind = .sequence([blank])
        return root
    }

    /// Parses `source` (empty means a brand-new equation) into an editable
    /// tree, guaranteeing the root is a non-empty `.sequence` so there's
    /// always at least one blank to tap.
    static func editableTree(from source: String) -> MathNode {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty() }
        let root = from(MathExpressionParser.parse(source))
        if case .sequence(let children) = root.kind, children.isEmpty {
            let blank = MathNode(.blank, parent: root)
            root.kind = .sequence([blank])
        }
        return root
    }
}

/// Renders a `MathNode` tree with tappable blanks/runs — the editable
/// counterpart to `MathExpressionView`. Selecting a node (tapping it)
/// highlights it and routes the keypad's next character/backspace to it.
struct MathNodeView: View {
    @ObservedObject var node: MathNode
    @Binding var selectedID: UUID?
    var fontSize: CGFloat = 22

    private var isSelected: Bool { selectedID == node.id }

    var body: some View {
        switch node.kind {
        case .blank:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [3, 2])
                )
                .background(
                    (isSelected ? Color.accentColor.opacity(0.14) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .frame(minWidth: fontSize * 1.1, minHeight: fontSize * 1.3)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = node.id }
        case .text(let s):
            Text(s)
                .font(.system(size: fontSize, design: .serif))
                .padding(.horizontal, 1)
                .background(
                    (isSelected ? Color.accentColor.opacity(0.18) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 3)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedID = node.id }
        case .sequence(let children):
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                ForEach(children) { child in
                    MathNodeView(node: child, selectedID: $selectedID, fontSize: fontSize)
                }
            }
        case .fraction(let numerator, let denominator):
            VStack(spacing: 2) {
                MathNodeView(node: numerator, selectedID: $selectedID, fontSize: fontSize * 0.85)
                Rectangle().frame(height: 1)
                MathNodeView(node: denominator, selectedID: $selectedID, fontSize: fontSize * 0.85)
            }
            .fixedSize()
        case .power(let base, let exponent):
            HStack(alignment: .top, spacing: 0) {
                MathNodeView(node: base, selectedID: $selectedID, fontSize: fontSize)
                MathNodeView(node: exponent, selectedID: $selectedID, fontSize: fontSize * 0.65)
                    .offset(y: -fontSize * 0.3)
            }
        case .sub(let base, let subscriptNode):
            HStack(alignment: .bottom, spacing: 0) {
                MathNodeView(node: base, selectedID: $selectedID, fontSize: fontSize)
                MathNodeView(node: subscriptNode, selectedID: $selectedID, fontSize: fontSize * 0.65)
                    .offset(y: fontSize * 0.25)
            }
        case .sqrt(let inner):
            HStack(alignment: .top, spacing: 2) {
                Text("√").font(.system(size: fontSize, design: .serif))
                MathNodeView(node: inner, selectedID: $selectedID, fontSize: fontSize)
                    .padding(.top, 2)
                    .overlay(alignment: .top) { Rectangle().frame(height: 1) }
            }
        }
    }
}
