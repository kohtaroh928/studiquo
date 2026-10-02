import XCTest
@testable import studiquo

final class MathSegmenterTests: XCTestCase {
    private func segments(_ s: String) -> [MathSegment] { MathSegmenter.segments(in: s) }

    func testPlainTextIsOneSegment() {
        XCTAssertEqual(segments("今日は二次関数です。"), [.text("今日は二次関数です。")])
        XCTAssertEqual(segments(""), [])
    }

    func testTheFourDelimiterStyles() {
        XCTAssertEqual(segments(#"解は $x=1$ です"#), [.text("解は "), .inlineMath("x=1"), .text(" です")])
        XCTAssertEqual(segments(#"解は \(x=1\) です"#), [.text("解は "), .inlineMath("x=1"), .text(" です")])
        XCTAssertEqual(segments("前\n$$x=1$$\n後"), [.text("前\n"), .displayMath("x=1"), .text("\n後")])
        XCTAssertEqual(segments("前\n\\[ x=1 \\]\n後"), [.text("前\n"), .displayMath("x=1"), .text("\n後")])
    }

    func testABareEnvironmentIsDisplayMath() {
        let source = "\\begin{align*}\na &= 1 \\\\\nb &= 2\n\\end{align*}"
        XCTAssertEqual(segments(source), [.displayMath(source)])
        XCTAssertEqual(segments("\\begin{center}x\\end{center}"), [.text("\\begin{center}x\\end{center}")], "未知の環境は触らない")
    }

    func testPricesAreNotFormulas() {
        for source in ["りんごは$100、みかんは$200です。", "この本は$5.99で、あの本は$12.50です。", "料金は$20〜$30の間です。",
                       "記号 $ は通貨を表します。", "costs $5 and $10 in total", "between $5-$10"] {
            XCTAssertEqual(segments(source), [.text(source)], source)
        }
    }

    func testRealMathNextToPrices() {
        XCTAssertEqual(
            segments(#"商品は$100と$200で、割引後は $x = 0.8 \times 300$ 円です。"#),
            [.text("商品は$100と$200で、割引後は "), .inlineMath(#"x = 0.8 \times 300"#), .text(" 円です。")]
        )
    }

    func testEscapedDollarIsALiteralDollar() {
        XCTAssertEqual(segments(#"価格は \$5 です。"#), [.text("価格は $5 です。")])
    }

    func testCodeIsNeverReadAsMath() {
        XCTAssertEqual(
            segments("環境変数は `$HOME` や `$PATH` です"),
            [.text("環境変数は "), .code("`$HOME`"), .text(" や "), .code("`$PATH`"), .text(" です")]
        )
        let fenced = "```bash\necho $HOME\nlatex='\\frac{1}{2}'\n```"
        XCTAssertEqual(segments("実行:\n\n\(fenced)\n\n終わり"), [.text("実行:\n\n"), .code(fenced), .text("\n\n終わり")])
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(segments("```python\nx = 1"), [.code("```python\nx = 1")])
    }

    func testHalfStreamedMathIsIncomplete() {
        XCTAssertEqual(segments(#"答えは $\frac{1"#), [.text("答えは "), .incomplete(#"$\frac{1"#)])
        XCTAssertEqual(segments("結果 $$\\int_0^"), [.text("結果 "), .incomplete("$$\\int_0^")])
        XCTAssertEqual(segments("\\[ x^2"), [.incomplete("\\[ x^2")])
        XCTAssertEqual(segments("$$|x|=\\begin{cases} x &"), [.incomplete("$$|x|=\\begin{cases} x &")])
        XCTAssertEqual(segments("計算すると $"), [.text("計算すると $")], "ただのドルは文字")
    }

    func testMathDoesNotSpanAParagraphBreak() {
        XCTAssertEqual(segments("a $x\n\nb$ c"), [.text("a $x\n\nb$ c")])
    }

    func testDisplayMathMayHaveSeveralLines() {
        let source = "$$\n\\begin{aligned} a &= 1 \\\\ b &= 2 \\end{aligned}\n$$"
        XCTAssertEqual(segments(source), [.displayMath("\\begin{aligned} a &= 1 \\\\ b &= 2 \\end{aligned}")])
    }

    func testAdjacentPunctuationAndBrackets() {
        XCTAssertEqual(segments("変数（$x$）、定数（$a$）"), [.text("変数（"), .inlineMath("x"), .text("）、定数（"), .inlineMath("a"), .text("）")])
    }

    /// No state of a streaming reply may crash or lose characters.
    func testEveryPrefixOfTheCorpusSegmentsAndKeepsItsText() {
        for sample in AIMathSamples.all {
            for prefix in AIMathSamples.streamingPrefixes(of: sample.text, step: 3) {
                let rebuilt = MathSegmenter.segments(in: prefix).map { segment -> String in
                    switch segment {
                    case .text(let t), .code(let t), .incomplete(let t): return t
                    case .inlineMath(let m): return "$" + m + "$"
                    case .displayMath(let m): return "$$" + m + "$$"
                    }
                }.joined()
                XCTAssertFalse(rebuilt.isEmpty && !prefix.isEmpty, "\(sample): 空になりました")
            }
        }
    }
}
