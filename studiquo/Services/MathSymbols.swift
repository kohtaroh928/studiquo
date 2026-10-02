import Foundation

/// How a piece of a formula behaves when it is laid out as plain text, which
/// decides the spaces around it: `x = y + 1`, `sin x`, `f(x)`, `a, b`.
enum MathAtomKind {
    case ordinary
    case binary
    case relation
    case open
    case close
    case punctuation
    /// A named function (`sin`, `log`): a space follows unless a bracket does.
    case function
    /// Prose from `\text{…}`, whose own spaces are kept.
    case text
    case space
}

/// The tables behind `MathTextFormatter`: what each LaTeX command becomes.
enum MathSymbols {
    static func atom(_ name: String) -> (text: String, kind: MathAtomKind)? {
        if let g = greek[name] { return (g, .ordinary) }
        if let o = ordinary[name] { return (o, .ordinary) }
        if let b = binary[name] { return (b, .binary) }
        if let r = relation[name] { return (r, .relation) }
        if let f = functions[name] { return (f, .function) }
        if let d = delimiters[name] { return (d.text, d.kind) }
        if let p = punctuation[name] { return (p, .punctuation) }
        return nil
    }

    // MARK: Letters

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let ordinary: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬", "angle": "∠",
        "triangle": "△", "square": "□", "Box": "□", "blacksquare": "■",
        "checkmark": "✓", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "aleph": "ℵ", "prime": "′", "degree": "°", "circ": "∘", "bullet": "•", "star": "⋆",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "dotsc": "…",
        "wp": "℘", "imath": "ı", "jmath": "ȷ", "top": "⊤", "bot": "⊥", "sharp": "♯",
        "flat": "♭", "natural": "♮", "surd": "√", "cdot": "·", "vert": "|", "lvert": "|", "rvert": "|",
        "Vert": "‖", "lVert": "‖", "rVert": "‖", "|": "‖", "backslash": "\\", "dagger": "†",
        "ddagger": "‡", "S": "§", "P": "¶", "copyright": "©", "pounds": "£", "euro": "€",
        "textbackslash": "\\", "textasciitilde": "~", "textbar": "|",
        "%": "%", "$": "$", "#": "#", "&": "&", "_": "_", "{": "{", "}": "}",
        "lbrace": "{", "rbrace": "}",
    ]

    // MARK: Operators

    static let binary: [String: String] = [
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "oplus": "⊕", "ominus": "⊖",
        "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨",
        "cup": "∪", "cap": "∩", "setminus": "∖", "smallsetminus": "∖", "uplus": "⊎", "sqcup": "⊔",
        "sqcap": "⊓", "bigtriangleup": "△", "diamond": "⋄", "amalg": "⨿", "wr": "≀",
    ]

    static let relation: [String: String] = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
        "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆",
        "supseteq": "⊇", "nsubseteq": "⊈", "subsetneq": "⊊", "supsetneq": "⊋",
        "parallel": "∥", "perp": "⊥", "nparallel": "∦", "mid": "|", "divides": "|",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "gets": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⟺", "implies": "⟹",
        "impliedby": "⟸", "mapsto": "↦", "longmapsto": "⟼", "longrightarrow": "⟶",
        "longleftarrow": "⟵", "Longrightarrow": "⟹", "Longleftarrow": "⟸", "Longleftrightarrow": "⟺",
        "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕", "nearrow": "↗", "searrow": "↘",
        "hookrightarrow": "↪", "rightleftharpoons": "⇌", "leadsto": "⇝", "prec": "≺", "succ": "≻",
        "preceq": "⪯", "succeq": "⪰", "asymp": "≍", "doteq": "≐", "models": "⊨", "vdash": "⊢",
        "dashv": "⊣", "triangleq": "≜", "coloneqq": "≔", "colon": ":", "because": "∵", "therefore": "∴",
    ]

    static let functions: [String: String] = [
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
        "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan", "sinh": "sinh", "cosh": "cosh",
        "tanh": "tanh", "coth": "coth", "log": "log", "ln": "ln", "lg": "lg", "exp": "exp",
        "lim": "lim", "limsup": "lim sup", "liminf": "lim inf", "max": "max", "min": "min",
        "sup": "sup", "inf": "inf", "det": "det", "gcd": "gcd", "lcm": "lcm", "deg": "deg",
        "dim": "dim", "ker": "ker", "arg": "arg", "Pr": "Pr", "hom": "hom", "mod": "mod",
        "bmod": "mod", "pmod": "mod", "rank": "rank", "tr": "tr", "Im": "Im", "Re": "Re",
    ]

    /// Functions whose subscript is the thing they range over: `\lim_{x\to0}`.
    static let underLimitFunctions: Set<String> = [
        "lim", "limsup", "liminf", "max", "min", "sup", "inf", "gcd", "argmax", "argmin", "det", "Pr",
    ]

    /// `\sum_{i=1}^{n}` and friends: shown as `Σ(i=1〜n)`.
    static let bigOperators: [String: String] = [
        "sum": "Σ", "prod": "Π", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁",
        "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀", "bigsqcup": "⨆",
    ]

    static let integrals: [String: String] = [
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "oiint": "∯", "idotsint": "∫⋯∫",
    ]

    // MARK: Brackets and punctuation

    static let delimiters: [String: (text: String, kind: MathAtomKind)] = [
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lceil": ("⌈", .open), "rceil": ("⌉", .close),
        "lfloor": ("⌊", .open), "rfloor": ("⌋", .close), "lbrack": ("[", .open), "rbrack": ("]", .close),
        "lparen": ("(", .open), "rparen": (")", .close),
    ]

    static let punctuation: [String: String] = [
        "comma": ",", "ldotp": ".", "cdotp": "·",
    ]

    /// What `\left` / `\right` / `\big…` may be followed by.
    static func delimiterText(_ name: String) -> String {
        switch name {
        case ".": return ""
        case "{", "\\{", "lbrace": return "{"
        case "}", "\\}", "rbrace": return "}"
        case "lbrack": return "["
        case "rbrack": return "]"
        case "langle": return "⟨"
        case "rangle": return "⟩"
        case "lceil": return "⌈"
        case "rceil": return "⌉"
        case "lfloor": return "⌊"
        case "rfloor": return "⌋"
        case "\\|", "Vert", "lVert", "rVert": return "‖"
        case "|", "vert", "lvert", "rvert": return "|"
        case "uparrow": return "↑"
        case "downarrow": return "↓"
        case "slash", "/", "\\/": return "/"
        case "backslash": return "\\"
        default: return name
        }
    }

    // MARK: Blackboard, script letters

    static let blackboard: [Character: String] = [
        "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "H": "ℍ", "E": "𝔼",
        "A": "𝔸", "B": "𝔹", "D": "𝔻", "F": "𝔽", "G": "𝔾", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃",
        "M": "𝕄", "O": "𝕆", "S": "𝕊", "T": "𝕋", "U": "𝕌", "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐",
        "1": "𝟙",
    ]

    static let script: [Character: String] = [
        "L": "ℒ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "R": "ℛ", "B": "ℬ", "E": "ℰ", "M": "ℳ",
        "A": "𝒜", "C": "𝒞", "D": "𝒟", "G": "𝒢", "J": "𝒥", "K": "𝒦", "N": "𝒩", "O": "𝒪",
        "P": "𝒫", "Q": "𝒬", "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳",
        "Y": "𝒴", "Z": "𝒵",
    ]

    // MARK: Accents (combining marks)

    static let accents: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0305}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}", "vec": "\u{20D7}", "overrightarrow": "\u{20D7}",
        "overleftarrow": "\u{20D6}", "dot": "\u{0307}", "ddot": "\u{0308}", "dddot": "\u{20DB}",
        "acute": "\u{0301}", "grave": "\u{0300}", "breve": "\u{0306}", "check": "\u{030C}",
        "underline": "\u{0332}", "mathring": "\u{030A}",
    ]

    /// Accents that go on every character (`\overline{AB}`), not just the last.
    static let accentsOnEveryCharacter: Set<String> = ["overline", "underline"]

    // MARK: Unicode superscripts and subscripts

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "−": "⁻", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ",
        "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
        "*": "*", "′": "′", "°": "°",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "−": "₋", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
    ]

    static func superscript(_ s: String) -> String? { convert(s, with: superscripts) }
    static func subscripted(_ s: String) -> String? { convert(s, with: subscripts) }

    private static func convert(_ s: String, with table: [Character: Character]) -> String? {
        let compact = s.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        var out = ""
        for c in compact {
            guard let mapped = table[c] else { return nil }
            out.append(mapped)
        }
        return out
    }
}
