import XCTest
@testable import studiquo

final class RichTextParserTests: XCTestCase {
    // MARK: Helpers

    private func t(_ s: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, link: String? = nil) -> RichSpan {
        RichSpan(.text(s), bold: bold, italic: italic, strike: strike, link: link)
    }
    private func m(_ s: String, bold: Bool = false) -> RichSpan { RichSpan(.math(s), bold: bold) }
    private func c(_ s: String) -> RichSpan { RichSpan(.code(s)) }
    private func p(_ spans: RichSpan...) -> RichBlock { .paragraph(spans) }
    private func parse(_ s: String) -> [RichBlock] { RichTextParser.parse(s) }

    // MARK: Paragraphs

    func testEmptyAndBlankInput() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("  \n\n \n"), [])
    }

    func testAParagraphWithInlineMath() {
        XCTAssertEqual(parse("解は $x=1$ です"), [p(t("解は "), m("x=1"), t(" です"))])
    }

    func testSingleLineBreaksAreKept() {
        XCTAssertEqual(parse("1行目\n2行目\n\n次の段落"), [p(t("1行目\n2行目")), p(t("次の段落"))])
    }

    // MARK: Headings and rules

    func testHeadings() {
        XCTAssertEqual(
            parse("# 二次関数\n\n## 頂点の求め方\n\n### 手順\n\n文章です。"),
            [.heading(level: 1, spans: [t("二次関数")]), .heading(level: 2, spans: [t("頂点の求め方")]),
             .heading(level: 3, spans: [t("手順")]), p(t("文章です。"))]
        )
        XCTAssertEqual(parse("## 見出し ##"), [.heading(level: 2, spans: [t("見出し")])])
        XCTAssertEqual(parse("#見出しではない"), [p(t("#見出しではない"))])
        XCTAssertEqual(parse("## 式 $x^2$ の話"), [.heading(level: 2, spans: [t("式 "), m("x^2"), t(" の話")])])
    }

    func testHorizontalRule() {
        XCTAssertEqual(parse("前半です。\n\n---\n\n後半です。"), [p(t("前半です。")), .rule, p(t("後半です。"))])
        XCTAssertEqual(parse("***"), [.rule])
    }

    // MARK: Emphasis, links, escapes

    func testEmphasis() {
        XCTAssertEqual(
            parse("これは**とても重要**で、*ここも大事*、***両方***です。"),
            [p(t("これは"), t("とても重要", bold: true), t("で、"), t("ここも大事", italic: true), t("、"),
               t("両方", bold: true, italic: true), t("です。"))]
        )
        XCTAssertEqual(parse("~~消す~~"), [p(t("消す", strike: true))])
    }

    func testBoldAroundMathKeepsTheMathBold() {
        XCTAssertEqual(
            parse("**$x=2$ のとき最大値 $5$** をとります"),
            [p(m("x=2", bold: true), t(" のとき最大値 ", bold: true), m("5", bold: true), t(" をとります"))]
        )
    }

    func testNestedEmphasis() {
        XCTAssertEqual(
            parse("**太字と*斜体*の混在**"),
            [p(t("太字と", bold: true), t("斜体", bold: true, italic: true), t("の混在", bold: true))]
        )
    }

    func testLinksAndImages() {
        XCTAssertEqual(
            parse("[リンク](https://example.com) と ![図](a.png)"),
            [p(t("リンク", link: "https://example.com"), t(" と 図"))]
        )
    }

    func testEscapesAndIntrawordUnderscores() {
        XCTAssertEqual(parse(#"\*星\* と snake_case_name"#), [p(t("*星* と snake_case_name"))])
        XCTAssertEqual(parse("_斜体_ です"), [p(t("斜体", italic: true), t(" です"))])
        XCTAssertEqual(parse("2 * 3 = 6"), [p(t("2 * 3 = 6"))])
    }

    func testInlineCode() {
        XCTAssertEqual(
            parse("Pythonでは `x ** 2` と書き、`\\frac{a}{b}` と書く"),
            [p(t("Pythonでは "), c("x ** 2"), t(" と書き、"), c("\\frac{a}{b}"), t(" と書く"))]
        )
    }

    // MARK: Lists

    func testBulletsWithMath() {
        XCTAssertEqual(
            parse("- 判別式 $D=b^2-4ac$ を計算する\n- $D>0$ なら実数解が2つ"),
            [.list(ordered: false, start: 1, items: [
                [p(t("判別式 "), m("D=b^2-4ac"), t(" を計算する"))],
                [p(m("D>0"), t(" なら実数解が2つ"))],
            ])]
        )
        XCTAssertEqual(parse("* a\n+ b"), [.list(ordered: false, start: 1, items: [[p(t("a"))], [p(t("b"))]])])
    }

    func testNumberedLists() {
        XCTAssertEqual(
            parse("1. 両辺を割る\n2. 移項する\n3. 検算する"),
            [.list(ordered: true, start: 1, items: [[p(t("両辺を割る"))], [p(t("移項する"))], [p(t("検算する"))]])]
        )
        XCTAssertEqual(parse("3. 三\n4. 四"), [.list(ordered: true, start: 3, items: [[p(t("三"))], [p(t("四"))]])])
    }

    func testNestedLists() {
        XCTAssertEqual(
            parse("- 場合分け\n  - $x\\geq 0$ のとき\n  - $x<0$ のとき\n- まとめ"),
            [.list(ordered: false, start: 1, items: [
                [p(t("場合分け")), .list(ordered: false, start: 1, items: [
                    [p(m("x\\geq 0"), t(" のとき"))], [p(m("x<0"), t(" のとき"))],
                ])],
                [p(t("まとめ"))],
            ])]
        )
    }

    func testADisplayFormulaInsideAListItem() {
        XCTAssertEqual(
            parse("- 手順1: 両辺に $2$ を足す\n- 手順2:\n  $$x+2=5$$\n- 手順3: $x=3$"),
            [.list(ordered: false, start: 1, items: [
                [p(t("手順1: 両辺に "), m("2"), t(" を足す"))],
                [p(t("手順2:")), .displayMath("x+2=5")],
                [p(t("手順3: "), m("x=3"))],
            ])]
        )
    }

    func testBlankLinesBetweenItemsKeepOneList() {
        XCTAssertEqual(
            parse("- a\n\n- b\n\n- c"),
            [.list(ordered: false, start: 1, items: [[p(t("a"))], [p(t("b"))], [p(t("c"))]])]
        )
        XCTAssertEqual(
            parse("- a\n\n段落\n\n- b"),
            [.list(ordered: false, start: 1, items: [[p(t("a"))]]), p(t("段落")), .list(ordered: false, start: 1, items: [[p(t("b"))]])]
        )
    }

    func testAListMayFollowAParagraphWithoutABlankLine() {
        XCTAssertEqual(
            parse("手順:\n1. a\n2. b"),
            [p(t("手順:")), .list(ordered: true, start: 1, items: [[p(t("a"))], [p(t("b"))]])]
        )
    }

    func testAMarkedBulletLineThatIsNotAListStaysText() {
        XCTAssertEqual(parse("-1 は負の数"), [p(t("-1 は負の数"))])
        XCTAssertEqual(parse("・論理 4/5点\n・明確さ 3/5点"), [p(t("・論理 4/5点\n・明確さ 3/5点"))])
    }

    // MARK: Quotes, tables, code, display math

    func testBlockQuote() {
        XCTAssertEqual(
            parse("> 定理: $a^2+b^2=c^2$\n> （三平方の定理）\n\n続きです。"),
            [.quote([p(t("定理: "), m("a^2+b^2=c^2"), t("\n（三平方の定理）"))]), p(t("続きです。"))]
        )
    }

    func testTableWithMathCells() {
        XCTAssertEqual(
            parse("| 関数 | 導関数 |\n|---|---|\n| $x^2$ | $2x$ |\n| $|x|$ | `abs` |"),
            [.table(header: [[t("関数")], [t("導関数")]], rows: [
                [[m("x^2")], [m("2x")]],
                [[m("|x|")], [c("abs")]],
            ])]
        )
    }

    func testATableWithoutItsSeparatorYetIsAParagraph() {
        XCTAssertEqual(parse("| 関数 | 導関数 |"), [p(t("| 関数 | 導関数 |"))])
        XCTAssertEqual(parse("| 関数 | 導関数 |\n|---|---|"), [.table(header: [[t("関数")], [t("導関数")]], rows: [])])
    }

    func testCodeBlocks() {
        XCTAssertEqual(
            parse("実行:\n\n```bash\necho $HOME\nlatex='\\frac{1}{2}'\n```\n\n終わり"),
            [p(t("実行:")), .codeBlock(language: "bash", code: "echo $HOME\nlatex='\\frac{1}{2}'", isClosed: true), p(t("終わり"))]
        )
        XCTAssertEqual(parse("```python\nx = 1"), [.codeBlock(language: "python", code: "x = 1", isClosed: false)])
        XCTAssertEqual(parse("```\nplain\n```"), [.codeBlock(language: nil, code: "plain", isClosed: true)])
    }

    func testDisplayMathBecomesItsOwnBlock() {
        XCTAssertEqual(
            parse("計算は次のとおり。\n\n$$\\int_0^1 x^2\\,dx$$\n\n以上です。"),
            [p(t("計算は次のとおり。")), .displayMath("\\int_0^1 x^2\\,dx"), p(t("以上です。"))]
        )
        XCTAssertEqual(
            parse("結果は $$x=1$$ になります"),
            [p(t("結果は")), .displayMath("x=1"), p(t("になります"))]
        )
        XCTAssertEqual(
            parse("\\begin{align*}\na &= 1 \\\\\nb &= 2\n\\end{align*}"),
            [.displayMath("\\begin{align*}\na &= 1 \\\\\nb &= 2\n\\end{align*}")]
        )
    }

    // MARK: Unfinished input

    func testUnclosedMarkersStayLiteral() {
        XCTAssertEqual(parse("これは**重"), [p(t("これは**重"))])
        XCTAssertEqual(parse("*a"), [p(t("*a"))])
        XCTAssertEqual(parse("`code"), [p(t("`code"))])
        XCTAssertEqual(parse("[リンク](https://exa"), [p(t("[リンク](https://exa"))])
    }

    func testUnclosedMathIsKeptAsWritten() {
        XCTAssertEqual(parse(#"答えは $\frac{1"#), [p(t(#"答えは $\frac{1"#))])
        XCTAssertEqual(parse("計算は\n\n$$\\int_0^"), [p(t("計算は")), .incompleteMath("$$\\int_0^")])
        XCTAssertEqual(parse("\\[ x^2"), [.incompleteMath("\\[ x^2")])
        XCTAssertEqual(parse("$$|x|=\\begin{cases} x &"), [.incompleteMath("$$|x|=\\begin{cases} x &")])
    }

    // MARK: The corpus

    private func textOf(_ spans: [RichSpan]) -> String {
        spans.compactMap { if case .text(let s) = $0.content { return s } else { return nil } }.joined()
    }

    private func allText(_ blocks: [RichBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let spans), .paragraph(let spans): return textOf(spans)
            case .list(_, _, let items): return items.map(allText).joined(separator: "\n")
            case .quote(let inner): return allText(inner)
            case .table(let header, let rows): return (header + rows.flatMap { $0 }).map(textOf).joined(separator: "\n")
            case .displayMath, .incompleteMath, .codeBlock, .rule: return ""
            }
        }.joined(separator: "\n")
    }

    private func japanese(_ s: String) -> String { String(s.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.map(Character.init)) }

    /// No sample may lose or reorder its Japanese prose in the parse.
    func testTheCorpusKeepsItsProse() {
        for sample in AIMathSamples.all where !sample.isPartial {
            let proseInSource = MathSegmenter.segments(in: sample.text).compactMap { segment -> String? in
                if case .text(let t) = segment { return t } else { return nil }
            }.joined()
            let blocks = RichTextParser.parse(sample.text)
            XCTAssertEqual(japanese(allText(blocks)), japanese(proseInSource), "\(sample): 文章が変わりました")
        }
    }

    /// Complete replies leave no Markdown or LaTeX marker behind in plain text.
    func testNoMarkersLeftInTheText() {
        let markers = ["**", "$", "\\frac", "\\sqrt", "\\begin", "\\text"]
        for sample in AIMathSamples.all
        where !sample.isPartial && ![.falsePositive, .unsupported].contains(sample.category) && !["inline-code", "code-block-with-dollars"].contains(sample.id) {
            let text = allText(RichTextParser.parse(sample.text))
            for marker in markers {
                XCTAssertFalse(text.contains(marker), "\(sample): 「\(marker)」が文章に残っています: \(text.prefix(80))")
            }
        }
    }

    func testEveryStreamingStateParses() {
        for sample in AIMathSamples.all {
            for prefix in AIMathSamples.streamingPrefixes(of: sample.text, step: 2) {
                _ = RichTextParser.parse(prefix)
            }
        }
    }

    func testTheReplyShapes() {
        let reply = RichTextParser.parse(AIMathSamples.sample(id: "reply-quadratic-extremum")!.text)
        guard case .heading(let level, _) = reply.first else { return XCTFail("見出しで始まるはず") }
        XCTAssertEqual(level, 2)
        XCTAssertTrue(reply.contains(.displayMath("y=-2(x-2)^2+5")), "手順3の独立した式が、そのブロックとして取れていること")
        XCTAssertEqual(reply.filter { if case .heading = $0 { return true } else { return false } }.count, 3)

        let marking = RichTextParser.parse(AIMathSamples.sample(id: "reply-marking-report")!.text)
        XCTAssertFalse(marking.isEmpty)
        XCTAssertTrue(marking.allSatisfy { if case .paragraph = $0 { return true } else { return false } }, "採点レポートは段落の並び")
    }

    func testParsingIsFast() {
        let reply = AIMathSamples.all.filter { $0.category == .fullReply }.map(\.text).joined(separator: "\n\n")
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { _ = RichTextParser.parse(reply) }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 100
        print("PERF parse of \(reply.count) characters: \(String(format: "%.2f", ms)) ms each")
        XCTAssertLessThan(ms, 20)
    }
}
