import XCTest
@testable import studiquo

final class MathSymbolsAndEscapedDollarTests: XCTestCase {
    // MARK: - 1. Multiple escaped dollars + inline/display math + code in the same paragraph

    func testMultipleEscapedDollarsInSameParagraphNeverSwallowProseIntoMath() {
        let source = #"参加費は \$100 から \$250 で、合計式は $x + y = 350$ かつ \(z = 2\) です。"#
        XCTAssertEqual(
            MathSegmenter.segments(in: source),
            [
                .text("参加費は $100 から $250 で、合計式は "),
                .inlineMath("x + y = 350"),
                .text(" かつ "),
                .inlineMath("z = 2"),
                .text(" です。"),
            ]
        )
    }

    func testEscapedDollarsCodeSpansAndDisplayMathCoexistCleanly() {
        let source = "価格は \\$100、環境変数は `$HOME`、極限は\n\\[ \\lim_{n\\to\\infty} \\frac{1}{n} = 0 \\]\nまた別解は $$a^2 + b^2 = c^2$$ です。"
        XCTAssertEqual(
            MathSegmenter.segments(in: source),
            [
                .text("価格は $100、環境変数は "),
                .code("`$HOME`"),
                .text("、極限は\n"),
                .displayMath("\\lim_{n\\to\\infty} \\frac{1}{n} = 0"),
                .text("\nまた別解は "),
                .displayMath("a^2 + b^2 = c^2"),
                .text(" です。"),
            ]
        )
    }

    // MARK: - 2. MathSymbols atom classification and delimiter tables

    func testMathSymbolsAtomClassificationCoversAllCategoriesAndRejectsUnknownCommands() {
        // Greek
        let alpha = MathSymbols.atom("alpha")
        XCTAssertEqual(alpha?.text, "α")
        XCTAssertEqual(alpha?.kind, .ordinary)

        let omegaUpper = MathSymbols.atom("Omega")
        XCTAssertEqual(omegaUpper?.text, "Ω")
        XCTAssertEqual(omegaUpper?.kind, .ordinary)

        // Ordinary
        let infty = MathSymbols.atom("infty")
        XCTAssertEqual(infty?.text, "∞")
        XCTAssertEqual(infty?.kind, .ordinary)

        // Binary
        let times = MathSymbols.atom("times")
        XCTAssertEqual(times?.text, "×")
        XCTAssertEqual(times?.kind, .binary)

        // Relation
        let iff = MathSymbols.atom("iff")
        XCTAssertEqual(iff?.text, "⟺")
        XCTAssertEqual(iff?.kind, .relation)

        let therefore = MathSymbols.atom("therefore")
        XCTAssertEqual(therefore?.text, "∴")
        XCTAssertEqual(therefore?.kind, .relation)

        // Function
        let limsup = MathSymbols.atom("limsup")
        XCTAssertEqual(limsup?.text, "lim sup")
        XCTAssertEqual(limsup?.kind, .function)

        // Delimiters (open / close)
        let langle = MathSymbols.atom("langle")
        XCTAssertEqual(langle?.text, "⟨")
        XCTAssertEqual(langle?.kind, .open)

        let rceil = MathSymbols.atom("rceil")
        XCTAssertEqual(rceil?.text, "⌉")
        XCTAssertEqual(rceil?.kind, .close)

        // Punctuation
        let comma = MathSymbols.atom("comma")
        XCTAssertEqual(comma?.text, ",")
        XCTAssertEqual(comma?.kind, .punctuation)

        // Unknown command
        XCTAssertNil(MathSymbols.atom("nonexistentcommand"))
    }

    func testMathSymbolsDelimiterTextMapsAllBracketVariantsAndPassesThroughFallback() {
        XCTAssertEqual(MathSymbols.delimiterText("."), "")
        XCTAssertEqual(MathSymbols.delimiterText("lbrace"), "{")
        XCTAssertEqual(MathSymbols.delimiterText("\\{"), "{")
        XCTAssertEqual(MathSymbols.delimiterText("rbrace"), "}")
        XCTAssertEqual(MathSymbols.delimiterText("lbrack"), "[")
        XCTAssertEqual(MathSymbols.delimiterText("rbrack"), "]")
        XCTAssertEqual(MathSymbols.delimiterText("langle"), "⟨")
        XCTAssertEqual(MathSymbols.delimiterText("rangle"), "⟩")
        XCTAssertEqual(MathSymbols.delimiterText("lceil"), "⌈")
        XCTAssertEqual(MathSymbols.delimiterText("rceil"), "⌉")
        XCTAssertEqual(MathSymbols.delimiterText("lfloor"), "⌊")
        XCTAssertEqual(MathSymbols.delimiterText("rfloor"), "⌋")
        XCTAssertEqual(MathSymbols.delimiterText("Vert"), "‖")
        XCTAssertEqual(MathSymbols.delimiterText("\\|"), "‖")
        XCTAssertEqual(MathSymbols.delimiterText("vert"), "|")
        XCTAssertEqual(MathSymbols.delimiterText("uparrow"), "↑")
        XCTAssertEqual(MathSymbols.delimiterText("downarrow"), "↓")
        XCTAssertEqual(MathSymbols.delimiterText("slash"), "/")
        XCTAssertEqual(MathSymbols.delimiterText("backslash"), "\\")
        XCTAssertEqual(MathSymbols.delimiterText("("), "(")
    }

    func testMathSymbolsSuperscriptSubscriptAndSpecialTables() {
        XCTAssertEqual(MathSymbols.superscript("2 n + 1"), "²ⁿ⁺¹")
        XCTAssertEqual(MathSymbols.superscript("(k - 1)"), "⁽ᵏ⁻¹⁾")
        XCTAssertNil(MathSymbols.superscript("   "), "Whitespace-only input must return nil")
        XCTAssertNil(MathSymbols.superscript("q"), "'q' has no Unicode superscript glyph and must return nil")

        XCTAssertEqual(MathSymbols.subscripted("i j + 1"), "ᵢⱼ₊₁")
        XCTAssertEqual(MathSymbols.subscripted("β γ"), "ᵦᵧ")
        XCTAssertNil(MathSymbols.subscripted(""), "Empty input must return nil")
        XCTAssertNil(MathSymbols.subscripted("z"), "'z' has no Unicode subscript glyph and must return nil")

        XCTAssertEqual(MathSymbols.blackboard["R"], "ℝ")
        XCTAssertEqual(MathSymbols.blackboard["1"], "𝟙")
        XCTAssertEqual(MathSymbols.script["F"], "ℱ")
        XCTAssertTrue(MathSymbols.underLimitFunctions.contains("lim"))
        XCTAssertTrue(MathSymbols.underLimitFunctions.contains("argmax"))
        XCTAssertEqual(MathSymbols.accentsOnEveryCharacter, ["overline", "underline"])
    }
}
