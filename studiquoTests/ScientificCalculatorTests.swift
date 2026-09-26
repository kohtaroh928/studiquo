import XCTest
@testable import studiquo

final class ScientificCalculatorTests: XCTestCase {

    // MARK: - label(for:shiftActive:)

    func testLabelReturnsTheNormalIDWhenNotShifted() {
        let key = CalculatorKey("sin", shift: "sin⁻¹")
        XCTAssertEqual(ScientificCalculator.label(for: key, shiftActive: false), "sin")
    }

    func testLabelReturnsTheShiftLabelWhenShifted() {
        let key = CalculatorKey("sin", shift: "sin⁻¹")
        XCTAssertEqual(ScientificCalculator.label(for: key, shiftActive: true), "sin⁻¹")
    }

    func testLabelFallsBackToTheNormalIDWhenShiftedButTheKeyHasNoShiftFunction() {
        let key = CalculatorKey("Ans")
        XCTAssertEqual(ScientificCalculator.label(for: key, shiftActive: true), "Ans")
    }

    func testEveryFunctionKeyIDIsUnique() {
        let ids = ScientificCalculator.functionKeys.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "a duplicate key id would make two buttons share state/behavior")
    }

    func testEveryDigitKeyIDIsUnique() {
        let ids = ScientificCalculator.digitKeys.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - inserted(pressing:shiftActive:into:...) — trig and inverse trig

    func testInsertedSinNormalInsertsThePrefixFunctionCall() {
        let result = ScientificCalculator.inserted(pressing: "sin", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0)
        XCTAssertEqual(result, "sin(")
    }

    func testInsertedSinShiftedInsertsTheInverseFunction() {
        let result = ScientificCalculator.inserted(pressing: "sin", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0)
        XCTAssertEqual(result, "asin(")
    }

    func testInsertedCosAndTanFollowTheSamePattern() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "cos", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "cos(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "cos", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "acos(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "tan", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "tan(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "tan", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "atan(")
    }

    func testInsertedHyperbolicFunctionsAndTheirInverses() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "sinh", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "sinh(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "sinh", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "asinh(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "cosh", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "acosh(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "tanh", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "atanh(")
    }

    // MARK: - inserted — logs, roots, powers

    func testInsertedLnNormalAndShifted() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "ln", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "ln(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "ln", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "exp(")
    }

    func testInsertedLogNormalAndShifted() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "log", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "log(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "log", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "pow10(")
    }

    func testInsertedSqrtNormalInsertsPrefixFunctionAndShiftedAppendsSquare() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "√", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "sqrt(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "√", shiftActive: true, into: "5", lastAnswer: 0, memory: 0, random: 0), "5^2")
    }

    func testInsertedCubeRootNormalAndCubeShifted() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "∛", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "cbrt(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "∛", shiftActive: true, into: "5", lastAnswer: 0, memory: 0, random: 0), "5^3")
    }

    func testInsertedCaretNormalAppendsOperatorAndShiftedInsertsNthRoot() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "^", shiftActive: false, into: "2", lastAnswer: 0, memory: 0, random: 0), "2^")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "^", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "nthroot(")
    }

    func testInsertedReciprocalNormalAndAbsoluteValueShifted() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "1/x", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "recip(")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "1/x", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "abs(")
    }

    // MARK: - inserted — combinatorics and percent

    func testInsertedFactorialNormalAppendsPostfixMarkAndShiftedInsertsNPr() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "n!", shiftActive: false, into: "5", lastAnswer: 0, memory: 0, random: 0), "5!")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "n!", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "nPr(")
    }

    func testInsertedPercentNormalAppendsPostfixMarkAndShiftedInsertsNCr() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "%", shiftActive: false, into: "50", lastAnswer: 0, memory: 0, random: 0), "50%")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "%", shiftActive: true, into: "", lastAnswer: 0, memory: 0, random: 0), "nCr(")
    }

    func testInsertedCommaAppendsLiterally() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: ",", shiftActive: false, into: "nPr(5", lastAnswer: 0, memory: 0, random: 0), "nPr(5,")
    }

    // MARK: - inserted — Ans, memory, EXP, Ran#

    func testInsertedAnsInsertsTheLastAnswerAsALiteral() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "Ans", shiftActive: false, into: "", lastAnswer: 42, memory: 0, random: 0), "42")
    }

    func testInsertedAnsWrapsANegativeLastAnswerInParentheses() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "Ans", shiftActive: false, into: "", lastAnswer: -3, memory: 0, random: 0), "(-3)")
    }

    func testInsertedMPlusNormalDoesNotTouchTheExpression() {
        // The non-shifted press evaluates-and-adds-to-memory instead, which
        // needs mutable memory state this pure function doesn't have — the
        // caller (the View) handles it. This just documents the contract.
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "M+", shiftActive: false, into: "1+2", lastAnswer: 0, memory: 0, random: 0), "1+2")
    }

    func testInsertedMPlusShiftedInsertsTheMemoryValueAsMR() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "M+", shiftActive: true, into: "", lastAnswer: 0, memory: 7.5, random: 0), "7.5")
    }

    func testInsertedEXPAppendsTheScientificNotationMarker() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "EXP", shiftActive: false, into: "1.5", lastAnswer: 0, memory: 0, random: 0), "1.5e")
    }

    func testInsertedRanHashNormalInsertsTheInjectedRandomValue() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "Ran#", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0.42), "0.42")
    }

    func testInsertedRanHashShiftedDoesNotTouchTheExpression() {
        // Shifted Ran# toggles the fraction/decimal display mode instead —
        // state the View owns, not the expression.
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "Ran#", shiftActive: true, into: "3+4", lastAnswer: 0, memory: 0, random: 0.42), "3+4")
    }

    // MARK: - inserted — basic operators, digits, implicit multiplication

    func testInsertedOperatorsTranslateToTheirASCIIForm() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "÷", shiftActive: false, into: "1", lastAnswer: 0, memory: 0, random: 0), "1/")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "×", shiftActive: false, into: "1", lastAnswer: 0, memory: 0, random: 0), "1*")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "−", shiftActive: false, into: "1", lastAnswer: 0, memory: 0, random: 0), "1-")
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "+", shiftActive: false, into: "1", lastAnswer: 0, memory: 0, random: 0), "1+")
    }

    func testInsertedDigitAfterAClosingParenInsertsAnImplicitMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "5", shiftActive: false, into: "(2+3)", lastAnswer: 0, memory: 0, random: 0), "(2+3)*5")
    }

    func testInsertedPiAfterADigitInsertsAnImplicitMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "π", shiftActive: false, into: "2", lastAnswer: 0, memory: 0, random: 0), "2*π")
    }

    func testInsertedFunctionCallAfterADigitInsertsAnImplicitMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "sin", shiftActive: false, into: "2", lastAnswer: 0, memory: 0, random: 0), "2*sin(")
    }

    func testInsertedOpenParenAfterADigitInsertsAnImplicitMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "(", shiftActive: false, into: "2", lastAnswer: 0, memory: 0, random: 0), "2*(")
    }

    func testInsertedDigitAfterAnOperatorDoesNotInsertAMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "5", shiftActive: false, into: "2+", lastAnswer: 0, memory: 0, random: 0), "2+5")
    }

    func testInsertedDigitIntoAnEmptyExpressionJustAppends() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: "5", shiftActive: false, into: "", lastAnswer: 0, memory: 0, random: 0), "5")
    }

    func testInsertedClosingParenNeverInsertsAnImplicitMultiply() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: ")", shiftActive: false, into: "(2+3", lastAnswer: 0, memory: 0, random: 0), "(2+3)")
    }

    func testInsertedDecimalPointJustAppends() {
        XCTAssertEqual(ScientificCalculator.inserted(pressing: ".", shiftActive: false, into: "3", lastAnswer: 0, memory: 0, random: 0), "3.")
    }

    // MARK: - negated (±)

    func testNegatedWrapsANonEmptyExpressionInALeadingMinus() {
        XCTAssertEqual(ScientificCalculator.negated("5+3"), "-(5+3)")
    }

    func testNegatedTwiceReturnsToTheOriginalExpression() {
        let once = ScientificCalculator.negated("5+3")
        XCTAssertEqual(ScientificCalculator.negated(once), "5+3")
    }

    func testNegatedOnAnEmptyExpressionDoesNothing() {
        XCTAssertEqual(ScientificCalculator.negated(""), "")
    }

    // MARK: - applyingPostfixOperators

    func testPostfixFactorialOnAPlainNumberBecomesAFactPrefixCall() {
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("5!"), "fact(5)")
    }

    func testPostfixPercentOnAPlainNumberBecomesADivisionByOneHundred() {
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("50%"), "(50/100)")
    }

    func testPostfixFactorialOnAParenthesizedGroup() {
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("(2+3)!"), "fact((2+3))")
    }

    func testPostfixOperatorsHandleMultipleOccurrencesInOneExpression() {
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("3!+4!"), "fact(3)+fact(4)")
    }

    func testPostfixPercentChainedOntoAFactorialResolvesBothLevels() {
        // "5!%" = (5!) as a percent = 120% = 1.2 — the factorial must resolve
        // before the percent tries to find its preceding value.
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("5!%"), "(fact(5)/100)")
    }

    func testPostfixOperatorsLeaveAnExpressionWithNoPostfixMarksUnchanged() {
        XCTAssertEqual(ScientificCalculator.applyingPostfixOperators("1+2*3"), "1+2*3")
    }

    // MARK: - evaluate — basic arithmetic and error handling

    func testEvaluateBasicArithmetic() {
        XCTAssertEqual(ScientificCalculator.evaluate("2+3*4", angleMode: .degrees), .success(display: "14", value: 14))
    }

    func testEvaluateOfAnEmptyExpressionFails() {
        XCTAssertEqual(ScientificCalculator.evaluate("", angleMode: .degrees), .failure)
    }

    func testEvaluateOfInvalidSyntaxFails() {
        XCTAssertEqual(ScientificCalculator.evaluate("2+*3", angleMode: .degrees), .failure)
    }

    func testEvaluateOfDivisionByZeroFails() {
        XCTAssertEqual(ScientificCalculator.evaluate("5/0", angleMode: .degrees), .failure)
    }

    func testEvaluateFormatsANonIntegerResultWithoutTrailingZeros() {
        XCTAssertEqual(ScientificCalculator.evaluate("1/4", angleMode: .degrees), .success(display: "0.25", value: 0.25))
    }

    // MARK: - evaluate — angle-mode-aware trig

    func testEvaluateSinInDegrees() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("sin(30)", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 0.5, accuracy: 1e-9)
    }

    func testEvaluateSinInRadians() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("sin(π/2)", angleMode: .radians) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 1, accuracy: 1e-9)
    }

    func testEvaluateSinInGradians() {
        // 100 gradians is a right angle, same as 90 degrees or π/2 radians.
        guard case .success(_, let value) = ScientificCalculator.evaluate("sin(100)", angleMode: .gradians) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 1, accuracy: 1e-9)
    }

    func testEvaluateInverseSinReturnsAnAngleInTheCurrentMode() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("asin(0.5)", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 30, accuracy: 1e-9)
    }

    func testEvaluateSinAndAsinRoundTripInEachAngleMode() {
        // asin's principal range is a quarter turn each way (±90°/±π/2
        // rad/±100 grad), so the round-trip only recovers the original
        // angle when it's within that range — the test value must be a
        // quarter-turn-sized angle *in that mode's own unit*, not the same
        // raw number reused across units (40 radians is ~13 full turns, so
        // asin(sin(40)) in radians mode legitimately doesn't recover 40).
        let angleWithinPrincipalRange: [CalculatorAngleMode: Double] = [.degrees: 40, .radians: 0.4, .gradians: 40]
        for mode in CalculatorAngleMode.allCases {
            let angle = angleWithinPrincipalRange[mode]!
            guard case .success(_, let value) = ScientificCalculator.evaluate("asin(sin(\(angle)))", angleMode: mode) else {
                return XCTFail("expected success for \(mode)")
            }
            XCTAssertEqual(value, angle, accuracy: 1e-6, "round trip should recover the original angle in \(mode)")
        }
    }

    // MARK: - evaluate — hyperbolic functions (unit-independent)

    func testEvaluateHyperbolicFunctionsDoNotDependOnAngleMode() {
        let degrees = ScientificCalculator.evaluate("sinh(1)", angleMode: .degrees)
        let radians = ScientificCalculator.evaluate("sinh(1)", angleMode: .radians)
        XCTAssertEqual(degrees, radians)
        guard case .success(_, let value) = degrees else { return XCTFail("expected success") }
        XCTAssertEqual(value, 1.1752011936, accuracy: 1e-9)
    }

    func testEvaluateInverseHyperbolicRoundTrips() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("asinh(sinh(2))", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 2, accuracy: 1e-9)
    }

    // MARK: - evaluate — logs, exponentials, roots

    func testEvaluateLnAndExpAreInverses() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("exp(ln(5))", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 5, accuracy: 1e-9)
    }

    func testEvaluateLogAndPow10AreInverses() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("pow10(log(1000))", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 1000, accuracy: 1e-6)
    }

    func testEvaluateSqrtAndSquare() {
        XCTAssertEqual(ScientificCalculator.evaluate("sqrt(16)", angleMode: .degrees), .success(display: "4", value: 4))
        XCTAssertEqual(ScientificCalculator.evaluate("4^2", angleMode: .degrees), .success(display: "16", value: 16))
    }

    func testEvaluateCubeRootAndCube() {
        XCTAssertEqual(ScientificCalculator.evaluate("cbrt(27)", angleMode: .degrees), .success(display: "3", value: 3))
        XCTAssertEqual(ScientificCalculator.evaluate("3^3", angleMode: .degrees), .success(display: "27", value: 27))
    }

    func testEvaluateNthRootOfAPositiveBase() {
        XCTAssertEqual(ScientificCalculator.evaluate("nthroot(3,8)", angleMode: .degrees), .success(display: "2", value: 2))
    }

    func testEvaluateNthRootOfANegativeBaseWithAnOddDegree() {
        // The cube root of -8 is -2 — a real result, unlike Math.pow(-8, 1/3)
        // which would return NaN without the odd-degree special case.
        XCTAssertEqual(ScientificCalculator.evaluate("nthroot(3,-8)", angleMode: .degrees), .success(display: "-2", value: -2))
    }

    func testEvaluateReciprocalAndAbsoluteValue() {
        XCTAssertEqual(ScientificCalculator.evaluate("recip(4)", angleMode: .degrees), .success(display: "0.25", value: 0.25))
        XCTAssertEqual(ScientificCalculator.evaluate("abs(-7)", angleMode: .degrees), .success(display: "7", value: 7))
    }

    // MARK: - evaluate — combinatorics and percent

    func testEvaluateFactorialViaThePostfixMark() {
        XCTAssertEqual(ScientificCalculator.evaluate("5!", angleMode: .degrees), .success(display: "120", value: 120))
    }

    func testEvaluateFactorialOfZeroIsOne() {
        XCTAssertEqual(ScientificCalculator.evaluate("0!", angleMode: .degrees), .success(display: "1", value: 1))
    }

    func testEvaluateFactorialOfANegativeOrNonIntegerFails() {
        XCTAssertEqual(ScientificCalculator.evaluate("(-1)!", angleMode: .degrees), .failure)
        XCTAssertEqual(ScientificCalculator.evaluate("2.5!", angleMode: .degrees), .failure)
    }

    func testEvaluatePermutationsAndCombinations() {
        XCTAssertEqual(ScientificCalculator.evaluate("nPr(5,2)", angleMode: .degrees), .success(display: "20", value: 20))
        XCTAssertEqual(ScientificCalculator.evaluate("nCr(5,2)", angleMode: .degrees), .success(display: "10", value: 10))
    }

    func testEvaluatePercentViaThePostfixMark() {
        XCTAssertEqual(ScientificCalculator.evaluate("50%", angleMode: .degrees), .success(display: "0.5", value: 0.5))
    }

    func testEvaluatePercentCombinedWithArithmetic() {
        // Deliberately the simple universal reading (b% = b/100 always),
        // not the context-sensitive "percent of the other operand" some
        // calculators use for "200+10%".
        XCTAssertEqual(ScientificCalculator.evaluate("200+10%", angleMode: .degrees), .success(display: "200.1", value: 200.1))
    }

    // MARK: - evaluate — constants and implicit multiplication in a full expression

    func testEvaluatePi() {
        guard case .success(_, let value) = ScientificCalculator.evaluate("π", angleMode: .degrees) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, Double.pi, accuracy: 1e-9)
    }

    func testEvaluateAnExpressionBuiltUpThroughInsertedWithImplicitMultiplication() {
        // "2" then π (pressed via the button, which triggers the implicit
        // multiply) should evaluate as 2π, not fail as "2π" glued together.
        let expression = ScientificCalculator.inserted(pressing: "π", shiftActive: false, into: "2", lastAnswer: 0, memory: 0, random: 0)
        guard case .success(_, let value) = ScientificCalculator.evaluate(expression, angleMode: .degrees) else {
            return XCTFail("expected success for \(expression)")
        }
        XCTAssertEqual(value, 2 * Double.pi, accuracy: 1e-9)
    }

    // MARK: - format / fraction (S⇔D)

    func testFormatWithoutFractionModeShowsAPlainDecimal() {
        XCTAssertEqual(ScientificCalculator.format(0.5, asFraction: false), "0.5")
    }

    func testFormatWithFractionModeShowsASimpleFraction() {
        XCTAssertEqual(ScientificCalculator.format(0.5, asFraction: true), "1/2")
    }

    func testFormatWithFractionModeShowsAMixedNumberForAnImproperFraction() {
        XCTAssertEqual(ScientificCalculator.format(1.5, asFraction: true), "1 1/2")
    }

    func testFormatWithFractionModeFallsBackToAPlainIntegerWhenThereIsNoFractionalPart() {
        XCTAssertEqual(ScientificCalculator.format(4, asFraction: true), "4")
    }

    func testFractionApproximatesARepeatingDecimal() {
        let approximation = ScientificCalculator.fraction(from: 1.0 / 3.0)
        XCTAssertEqual(approximation?.numerator, 1)
        XCTAssertEqual(approximation?.denominator, 3)
    }

    func testFractionOfANegativeValuePreservesTheSignOnTheNumerator() {
        let approximation = ScientificCalculator.fraction(from: -0.25)
        XCTAssertEqual(approximation?.numerator, -1)
        XCTAssertEqual(approximation?.denominator, 4)
    }

    func testFractionOfAWholeNumberHasDenominatorOne() {
        let approximation = ScientificCalculator.fraction(from: 4)
        XCTAssertEqual(approximation?.denominator, 1)
    }

    // MARK: - CalculatorAngleMode

    func testAngleModeCyclesThroughAllThreeModesAndBackToTheStart() {
        XCTAssertEqual(CalculatorAngleMode.degrees.cycled(), .radians)
        XCTAssertEqual(CalculatorAngleMode.radians.cycled(), .gradians)
        XCTAssertEqual(CalculatorAngleMode.gradians.cycled(), .degrees)
    }
}
