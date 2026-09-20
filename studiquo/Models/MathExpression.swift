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
