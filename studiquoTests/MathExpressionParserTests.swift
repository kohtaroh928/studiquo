import XCTest
@testable import studiquo

/// Coverage for `MathExpressionParser`, the small LaTeX-like subset an
/// equation block's source is written in. Parser bugs here are easy to miss
/// by eye — the render still "looks like an equation" even when a
/// superscript attached to the wrong token — so these check the actual tree
/// shape, not just that parsing doesn't crash.
final class MathExpressionParserTests: XCTestCase {
    func testPlainNumberAndVariable() {
        XCTAssertEqual(MathExpressionParser.parse("5"), .sequence([.text("5")]))
        XCTAssertEqual(MathExpressionParser.parse("x"), .sequence([.text("x")]))
    }

    func testMultiDigitNumberStaysOneToken() {
        XCTAssertEqual(MathExpressionParser.parse("123"), .sequence([.text("123")]))
    }

    func testDecimalNumber() {
        XCTAssertEqual(MathExpressionParser.parse("3.14"), .sequence([.text("3.14")]))
    }

    /// The behavior `parseAtom`'s single-letter rule exists for: `xy` reads
    /// as two adjacent variables (implicit multiplication), matching normal
    /// math notation, not one two-letter identifier.
    func testAdjacentLettersAreSeparateVariables() {
        XCTAssertEqual(MathExpressionParser.parse("xy"), .sequence([.text("x"), .text("y")]))
    }

    func testOperatorsAreLiteralTokens() {
        XCTAssertEqual(
            MathExpressionParser.parse("x+y"),
            .sequence([.text("x"), .text("+"), .text("y")])
        )
    }

    // MARK: superscript/subscript

    func testBareSuperscriptAttachesToOnlyThePrecedingToken() {
        // The regression this specifically guards: a greedy "run of
        // letters" atom would attach `^2` to the whole `x+y`, not just `y`.
        XCTAssertEqual(
            MathExpressionParser.parse("x+y^2"),
            .sequence([.text("x"), .text("+"), .superscript(.text("y"), .text("2"))])
        )
    }

    func testBracedSuperscriptGroupsMultipleTokens() {
        XCTAssertEqual(
            MathExpressionParser.parse("x^{2+1}"),
            .sequence([.superscript(.text("x"), .sequence([.text("2"), .text("+"), .text("1")]))])
        )
    }

    func testSubscript() {
        XCTAssertEqual(
            MathExpressionParser.parse("a_i"),
            .sequence([.subscriptExpression(.text("a"), .text("i"))])
        )
    }

    func testSuperscriptThenSubscriptChainOnTheSameBase() {
        // The regression this guards: `parseGroup` used to fall back to a
        // full `parseFactor` call for a bare (unbraced) argument, and
        // `parseFactor` has its own "consume trailing ^/_ " loop — so the
        // `_i` here was getting swallowed as part of `^2`'s *exponent*
        // (`x^(2_i)`) instead of applying to the whole `x^2` (`(x^2)_i`,
        // what `x^2_i` is actually supposed to mean).
        XCTAssertEqual(
            MathExpressionParser.parse("x^2_i"),
            .sequence([
                .subscriptExpression(.superscript(.text("x"), .text("2")), .text("i")),
            ])
        )
    }

    // MARK: \frac and \sqrt

    func testFraction() {
        XCTAssertEqual(
            MathExpressionParser.parse("\\frac{1}{2}"),
            .sequence([.fraction(.sequence([.text("1")]), .sequence([.text("2")]))])
        )
    }

    func testFractionWithBareSingleTokenArguments() {
        // \frac doesn't require braces when each argument is one token.
        XCTAssertEqual(
            MathExpressionParser.parse("\\frac12"),
            .sequence([.fraction(.text("1"), .text("2"))])
        )
    }

    func testNestedFraction() {
        XCTAssertEqual(
            MathExpressionParser.parse("\\frac{1}{\\frac{2}{3}}"),
            .sequence([
                .fraction(
                    .sequence([.text("1")]),
                    .sequence([.fraction(.sequence([.text("2")]), .sequence([.text("3")]))])
                ),
            ])
        )
    }

    func testSqrt() {
        XCTAssertEqual(
            MathExpressionParser.parse("\\sqrt{x}"),
            .sequence([.sqrt(.sequence([.text("x")]))])
        )
    }

    // MARK: symbols

    func testKnownGreekLetterResolvesToItsGlyph() {
        XCTAssertEqual(MathExpressionParser.parse("\\pi"), .sequence([.symbol("π")]))
    }

    func testUnknownCommandFallsBackToItsNameRatherThanCrashing() {
        XCTAssertEqual(MathExpressionParser.parse("\\notarealcommand"), .sequence([.symbol("notarealcommand")]))
    }

    // MARK: realistic composite expressions

    func testQuadraticFormula() {
        let result = MathExpressionParser.parse("x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
        // Not asserting the full tree (too brittle to be a useful test) —
        // just that it parses into exactly one top-level `=` with a
        // fraction on the right, which is what actually matters visually.
        guard case .sequence(let terms) = result else {
            return XCTFail("expected a top-level sequence")
        }
        XCTAssertEqual(terms.count, 3)
        XCTAssertEqual(terms[0], .text("x"))
        XCTAssertEqual(terms[1], .text("="))
        guard case .fraction = terms[2] else {
            return XCTFail("expected the right-hand side to be a fraction, got \(terms[2])")
        }
    }

    // MARK: robustness

    func testEmptyStringDoesNotCrash() {
        XCTAssertEqual(MathExpressionParser.parse(""), .sequence([]))
    }

    func testUnclosedBraceDoesNotCrash() {
        XCTAssertNoThrow(MathExpressionParser.parse("x^{2"))
    }

    func testTrailingBackslashDoesNotCrash() {
        XCTAssertNoThrow(MathExpressionParser.parse("x\\"))
    }

    func testDanglingCaretDoesNotCrash() {
        XCTAssertNoThrow(MathExpressionParser.parse("x^"))
    }
}
