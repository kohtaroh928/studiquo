import XCTest
@testable import studiquo

final class MathSymbolsTests: XCTestCase {
    // MARK: atom(_:)

    func testAtomClassifiesEachTable() {
        XCTAssertEqual(MathSymbols.atom("alpha")?.text, "α")
        XCTAssertEqual(MathSymbols.atom("alpha")?.kind, .ordinary)
        XCTAssertEqual(MathSymbols.atom("infty")?.text, "∞")
        XCTAssertEqual(MathSymbols.atom("times")?.text, "×")
        XCTAssertEqual(MathSymbols.atom("times")?.kind, .binary)
        XCTAssertEqual(MathSymbols.atom("leq")?.text, "≤")
        XCTAssertEqual(MathSymbols.atom("leq")?.kind, .relation)
        XCTAssertEqual(MathSymbols.atom("sin")?.kind, .function)
        XCTAssertEqual(MathSymbols.atom("langle")?.text, "⟨")
        XCTAssertEqual(MathSymbols.atom("langle")?.kind, .open)
        XCTAssertEqual(MathSymbols.atom("rangle")?.kind, .close)
        XCTAssertEqual(MathSymbols.atom("comma")?.text, ",")
        XCTAssertEqual(MathSymbols.atom("comma")?.kind, .punctuation)
    }

    func testUnknownCommandIsNil() {
        XCTAssertNil(MathSymbols.atom("notACommand"))
        XCTAssertNil(MathSymbols.atom(""))
        XCTAssertNil(MathSymbols.atom("Alpha"))
    }

    func testCommandNamesAreCaseSensitive() {
        XCTAssertEqual(MathSymbols.atom("Gamma")?.text, "Γ")
        XCTAssertEqual(MathSymbols.atom("gamma")?.text, "γ")
    }

    func testAliasesShareOneSymbol() {
        XCTAssertEqual(MathSymbols.atom("leq")?.text, MathSymbols.atom("le")?.text)
        XCTAssertEqual(MathSymbols.atom("geq")?.text, MathSymbols.atom("ge")?.text)
        XCTAssertEqual(MathSymbols.atom("neq")?.text, MathSymbols.atom("ne")?.text)
        XCTAssertEqual(MathSymbols.atom("land")?.text, MathSymbols.atom("wedge")?.text)
        XCTAssertEqual(MathSymbols.atom("lor")?.text, MathSymbols.atom("vee")?.text)
        XCTAssertEqual(MathSymbols.atom("emptyset")?.text, MathSymbols.atom("varnothing")?.text)
    }

    func testLookupOrderPutsOrdinaryBeforeFunctionForReAndIm() {
        // `Re`/`Im` exist in both tables; the symbol form wins.
        XCTAssertEqual(MathSymbols.atom("Re")?.text, "ℜ")
        XCTAssertEqual(MathSymbols.atom("Re")?.kind, .ordinary)
        XCTAssertEqual(MathSymbols.atom("Im")?.text, "ℑ")
    }

    func testMultiWordFunctionNames() {
        XCTAssertEqual(MathSymbols.atom("limsup")?.text, "lim sup")
        XCTAssertEqual(MathSymbols.atom("liminf")?.text, "lim inf")
    }

    func testFunctionsMapToTheirOwnName() {
        for name in ["sin", "cos", "tan", "log", "ln", "exp", "det", "gcd"] {
            XCTAssertEqual(MathSymbols.functions[name], name)
        }
    }

    // MARK: Table integrity

    func testNoTableValueIsEmpty() {
        let tables: [(String, [String: String])] = [
            ("greek", MathSymbols.greek), ("ordinary", MathSymbols.ordinary),
            ("binary", MathSymbols.binary), ("relation", MathSymbols.relation),
            ("functions", MathSymbols.functions), ("bigOperators", MathSymbols.bigOperators),
            ("integrals", MathSymbols.integrals), ("punctuation", MathSymbols.punctuation),
            ("accents", MathSymbols.accents),
        ]
        for (name, table) in tables {
            for (key, value) in table { XCTAssertFalse(value.isEmpty, "\(name)[\(key)] is empty") }
        }
    }

    func testUnderLimitFunctionsAreKnownOrDeclared() {
        for name in MathSymbols.underLimitFunctions where name != "argmax" && name != "argmin" {
            XCTAssertNotNil(MathSymbols.functions[name], "\(name) is under-limit but not a function")
        }
    }

    func testAccentsOnEveryCharacterAreDefinedAccents() {
        for name in MathSymbols.accentsOnEveryCharacter {
            XCTAssertNotNil(MathSymbols.accents[name])
        }
    }

    func testAccentsAreCombiningMarks() {
        for (name, mark) in MathSymbols.accents {
            XCTAssertEqual(mark.unicodeScalars.count, 1, name)
            XCTAssertTrue(mark.unicodeScalars.first!.properties.generalCategory == .nonspacingMark
                          || mark.unicodeScalars.first!.properties.generalCategory == .enclosingMark, name)
        }
    }

    func testWideAccentsMatchTheirNarrowForms() {
        XCTAssertEqual(MathSymbols.accents["widehat"], MathSymbols.accents["hat"])
        XCTAssertEqual(MathSymbols.accents["widetilde"], MathSymbols.accents["tilde"])
        XCTAssertEqual(MathSymbols.accents["overrightarrow"], MathSymbols.accents["vec"])
    }

    func testBigOperatorsAndIntegrals() {
        XCTAssertEqual(MathSymbols.bigOperators["sum"], "Σ")
        XCTAssertEqual(MathSymbols.bigOperators["prod"], "Π")
        XCTAssertEqual(MathSymbols.integrals["int"], "∫")
        XCTAssertEqual(MathSymbols.integrals["oint"], "∮")
    }

    func testBlackboardAndScriptLetters() {
        XCTAssertEqual(MathSymbols.blackboard["R"], "ℝ")
        XCTAssertEqual(MathSymbols.blackboard["N"], "ℕ")
        XCTAssertEqual(MathSymbols.blackboard["1"], "𝟙")
        XCTAssertEqual(MathSymbols.script["L"], "ℒ")
        XCTAssertNil(MathSymbols.blackboard["z"])
    }

    // MARK: delimiterText

    func testDelimiterTextMapping() {
        XCTAssertEqual(MathSymbols.delimiterText("."), "")
        XCTAssertEqual(MathSymbols.delimiterText("\\{"), "{")
        XCTAssertEqual(MathSymbols.delimiterText("lbrace"), "{")
        XCTAssertEqual(MathSymbols.delimiterText("rbrace"), "}")
        XCTAssertEqual(MathSymbols.delimiterText("lfloor"), "⌊")
        XCTAssertEqual(MathSymbols.delimiterText("rceil"), "⌉")
        XCTAssertEqual(MathSymbols.delimiterText("langle"), "⟨")
        XCTAssertEqual(MathSymbols.delimiterText("\\|"), "‖")
        XCTAssertEqual(MathSymbols.delimiterText("Vert"), "‖")
        XCTAssertEqual(MathSymbols.delimiterText("|"), "|")
        XCTAssertEqual(MathSymbols.delimiterText("vert"), "|")
        XCTAssertEqual(MathSymbols.delimiterText("slash"), "/")
        XCTAssertEqual(MathSymbols.delimiterText("backslash"), "\\")
    }

    func testDelimiterTextPassesThroughOrdinaryBrackets() {
        XCTAssertEqual(MathSymbols.delimiterText("("), "(")
        XCTAssertEqual(MathSymbols.delimiterText("]"), "]")
        XCTAssertEqual(MathSymbols.delimiterText("x"), "x")
    }

    // MARK: superscript / subscripted

    func testSuperscriptDigitsLettersAndSigns() {
        XCTAssertEqual(MathSymbols.superscript("2"), "²")
        XCTAssertEqual(MathSymbols.superscript("10"), "¹⁰")
        XCTAssertEqual(MathSymbols.superscript("n+1"), "ⁿ⁺¹")
        XCTAssertEqual(MathSymbols.superscript("-1"), "⁻¹")
        XCTAssertEqual(MathSymbols.superscript("−1"), "⁻¹")
        XCTAssertEqual(MathSymbols.superscript("(a)"), "⁽ᵃ⁾")
        XCTAssertEqual(MathSymbols.superscript("T"), "ᵀ")
    }

    func testSubscriptDigitsLettersAndGreek() {
        XCTAssertEqual(MathSymbols.subscripted("0"), "₀")
        XCTAssertEqual(MathSymbols.subscripted("i+1"), "ᵢ₊₁")
        XCTAssertEqual(MathSymbols.subscripted("n"), "ₙ")
        XCTAssertEqual(MathSymbols.subscripted("β"), "ᵦ")
        XCTAssertEqual(MathSymbols.subscripted("x-y".replacingOccurrences(of: "y", with: "1")), "ₓ₋₁")
    }

    func testWhitespaceIsIgnoredInConversion() {
        XCTAssertEqual(MathSymbols.superscript(" n + 1 "), "ⁿ⁺¹")
        XCTAssertEqual(MathSymbols.subscripted("1 2"), "₁₂")
    }

    func testConversionFailsWhenAnyCharacterHasNoUnicodeForm() {
        XCTAssertNil(MathSymbols.superscript("q"))      // no superscript q
        XCTAssertNil(MathSymbols.superscript("2q"))
        XCTAssertNil(MathSymbols.subscripted("b"))      // no subscript b
        XCTAssertNil(MathSymbols.subscripted("1/2"))
    }

    func testEmptyOrBlankConversionIsNil() {
        XCTAssertNil(MathSymbols.superscript(""))
        XCTAssertNil(MathSymbols.superscript("   "))
        XCTAssertNil(MathSymbols.subscripted(""))
    }
}
