import XCTest
@testable import studiquo

final class MathTextFormatterTests: XCTestCase {
    private func check(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (latex, expected) in cases {
            XCTAssertEqual(MathTextFormatter.readableMath(from: latex), expected, "LaTeX: \(latex)", file: file, line: line)
        }
    }

    // MARK: Algebra

    func testPowersAndSubscripts() {
        check([
            (#"x^2+y^2=r^2"#, "x² + y² = r²"),
            (#"2^{10}"#, "2¹⁰"),
            (#"x^{n+1}"#, "xⁿ⁺¹"),
            (#"a_{n+1}=a_n+d"#, "aₙ₊₁ = aₙ + d"),
            (#"x_{ij}"#, "xᵢⱼ"),
            (#"a_{n}^{2}"#, "aₙ²"),
            (#"x_b"#, "x_b"),
            (#"e^{-x^2}"#, "e^(−x²)"),
            (#"e^{-x}"#, "e⁻ˣ"),
            (#"A^{-1}"#, "A⁻¹"),
            (#"A^{\mathsf{T}}"#, "Aᵀ"),
            (#"30^\circ"#, "30°"),
            (#"\mathbb{R}^n"#, "ℝⁿ"),
            (#"(-1)^n"#, "(−1)ⁿ"),
            (#"f'(x)"#, "f′(x)"),
            (#"x^{\frac{1}{2}}"#, "x^(1/2)"),
        ])
    }

    func testFractions() {
        check([
            (#"\frac{a}{b}"#, "a/b"),
            (#"\frac{a+b}{2}"#, "(a + b)/2"),
            (#"\frac{x}{x+1}"#, "x/(x + 1)"),
            (#"\frac12"#, "1/2"),
            (#"\frac{1}{1+\frac{1}{x}}"#, "1/(1 + 1/x)"),
            (#"\dfrac{1}{2}"#, "1/2"),
            (#"\frac{n(n+1)}{2}"#, "n(n + 1)/2"),
            (#"\frac{(k+1)(k+2)}{2}"#, "(k + 1)(k + 2)/2"),
            (#"\frac{1}{2a}"#, "1/(2a)"),
            (#"\frac{dy}{dx}"#, "dy/dx"),
            (#"\frac{\partial f}{\partial x}"#, "∂f/∂x"),
            (#"\frac{x^n}{n!}"#, "xⁿ/n!"),
            (#"\frac{-b}{2a}"#, "(−b)/(2a)"),
        ])
    }

    func testRoots() {
        check([
            (#"\sqrt{2}"#, "√2"),
            (#"\sqrt{x^2+1}"#, "√(x² + 1)"),
            (#"\sqrt[3]{27}"#, "³√27"),
            (#"\sqrt{2+\sqrt{3}}"#, "√(2 + √3)"),
            (#"\sqrt{ab}"#, "√(ab)"),
            (#"\sqrt{x^2}"#, "√(x²)"),
            (#"\sqrt{\pi}"#, "√π"),
            (#"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#, "x = (−b ± √(b² − 4ac))/(2a)"),
        ])
    }

    func testOperatorsAndRelations() {
        check([
            (#"a \times b"#, "a × b"),
            (#"a \div b"#, "a ÷ b"),
            (#"a \pm b"#, "a ± b"),
            (#"-x"#, "−x"),
            (#"x \neq 0"#, "x ≠ 0"),
            (#"\alpha \leq \beta"#, "α ≤ β"),
            (#"|x-2| < 3 \iff -1 < x < 5"#, "|x − 2| < 3 ⟺ −1 < x < 5"),
            (#"1+2+\cdots+n"#, "1 + 2 + ⋯ + n"),
            (#"a_1, a_2, \ldots, a_n"#, "a₁, a₂, …, aₙ"),
            (#"\vec{a}\cdot\vec{b}"#, "a⃗·b⃗"),
            (#"x \not\in A"#, "x ∉ A"),
            (#"E=mc^2"#, "E = mc²"),
            (#"\pi r^2"#, "πr²"),
            (#"\Delta x"#, "Δx"),
        ])
    }

    // MARK: Big operators

    func testSumsProductsIntegralsLimits() {
        check([
            (#"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}"#, "Σ(k = 1〜n) k = n(n + 1)/2"),
            (#"\prod_{i=1}^{n} i = n!"#, "Π(i = 1〜n) i = n!"),
            (#"e^x = \sum_{n=0}^{\infty}\frac{x^n}{n!}"#, "eˣ = Σ(n = 0〜∞) xⁿ/n!"),
            (#"\int_{0}^{1} x^2\,dx"#, "∫₀¹ x² dx"),
            (#"\int_{-\infty}^{\infty} e^{-x^2}dx=\sqrt{\pi}"#, "∫(−∞〜∞) e^(−x²)dx = √π"),
            (#"\int_0^1 x^2\,dx = \left[\frac{x^3}{3}\right]_0^1 = \frac{1}{3}"#, "∫₀¹ x² dx = [x³/3]₀¹ = 1/3"),
            (#"\lim_{x\to\infty}\left(1+\frac1x\right)^x=e"#, "lim(x → ∞) (1 + 1/x)ˣ = e"),
            (#"f'(x)=\lim_{h \to 0}\frac{f(x+h)-f(x)}{h}"#, "f′(x) = lim(h → 0) (f(x + h) − f(x))/h"),
            (#"\iint_D f(x,y)\,dA"#, "∬(D) f(x, y) dA"),
            (#"\log_2 8=3"#, "log₂ 8 = 3"),
            (#"\sin^2\theta+\cos^2\theta=1"#, "sin²θ + cos²θ = 1"),
            (#"\sin(\alpha+\beta)=\sin\alpha\cos\beta+\cos\alpha\sin\beta"#, "sin(α + β) = sin α cos β + cos α sin β"),
            (#"\operatorname{arcsin}\frac12"#, "arcsin 1/2"),
            (#"\frac{d}{dx}\sin(x^2) = 2x\cos(x^2)"#, "d/dx sin(x²) = 2x cos(x²)"),
        ])
    }

    // MARK: Brackets

    func testBracketsAndDelimiters() {
        check([
            (#"\left( \frac{a}{b} \right)^2"#, "(a/b)²"),
            (#"\left\{ x \mid x>0 \right\}"#, "{x | x > 0}"),
            (#"\left\| v \right\|"#, "‖v‖"),
            (#"\left. \frac{x^2}{2} \right|_0^1"#, "x²/2|₀¹"),
            (#"\bigl( a+b \bigr)"#, "(a + b)"),
            (#"\Big[ \frac{1}{2} \Big]"#, "[1/2]"),
            (#"\langle u, v \rangle"#, "⟨u, v⟩"),
            (#"\lfloor x \rfloor"#, "⌊x⌋"),
            (#"1{,}000"#, "1,000"),
        ])
    }

    // MARK: Logic, sets, letters

    func testLogicSetsAndLetterStyles() {
        check([
            (#"\forall \varepsilon>0,\ \exists \delta>0"#, "∀ε > 0, ∃δ > 0"),
            (#"A \subset B"#, "A ⊂ B"),
            (#"A \cup B"#, "A ∪ B"),
            (#"x \in \mathbb{R}"#, "x ∈ ℝ"),
            (#"\mathbb{N}\subset\mathbb{Z}\subset\mathbb{Q}"#, "ℕ ⊂ ℤ ⊂ ℚ"),
            (#"P \Rightarrow Q"#, "P ⇒ Q"),
            (#"\neg P \land Q"#, "¬P ∧ Q"),
            (#"\because x>0 \therefore y"#, "∵ x > 0 ∴ y"),
            (#"\mathcal{L}"#, "ℒ"),
            (#"\mathscr{F}"#, "ℱ"),
            (#"\mathrm{Var}(X)=E[X^2]-\left(E[X]\right)^2"#, "Var(X) = E[X²] − (E[X])²"),
            (#"\mathbf{v}"#, "v"),
        ])
    }

    func testProbability() {
        check([
            (#"\binom{n}{k}"#, "ₙCₖ"),
            (#"\binom{n+1}{k}"#, "ₙ₊₁Cₖ"),
            (#"{}_n\mathrm{C}_r"#, "ₙCᵣ"),
            (#"P(A\mid B)=\frac{P(A\cap B)}{P(B)}"#, "P(A | B) = P(A ∩ B)/P(B)"),
        ])
    }

    // MARK: Accents

    func testAccents() {
        check([
            (#"\hat{x}"#, "x\u{0302}"),
            (#"\bar{x}"#, "x\u{0304}"),
            (#"\vec{v}"#, "v\u{20D7}"),
            (#"\overline{AB}"#, "A\u{0305}B\u{0305}"),
            (#"\overrightarrow{AB}"#, "AB\u{20D7}"),
            (#"\dot{x}"#, "x\u{0307}"),
        ])
    }

    // MARK: Text and spacing

    func testTextInsideMath() {
        check([
            (#"\text{速さ}=\frac{\text{距離}}{\text{時間}}"#, "速さ = 距離/時間"),
            (#"f(x)=\sqrt{x} \quad \text{ただし } x\geq 0"#, "f(x) = √x ただし x ≥ 0"),
            (#"60\,\mathrm{km/h}"#, "60 km/h"),
            (#"\text{利益}=\text{売上}-\text{費用}"#, "利益 = 売上 − 費用"),
        ])
    }

    func testSpacingCommands() {
        check([
            (#"x\;y\,z\!w"#, "x y zw"),
            (#"a \quad b"#, "a b"),
            (#"x~y"#, "x y"),
        ])
    }

    // MARK: Environments

    func testMatrices() {
        check([
            (#"\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}"#, "(1, 2; 3, 4)"),
            (#"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"#, "[1, 0; 0, 1]"),
            (#"\begin{vmatrix} a & b \\ c & d \end{vmatrix}"#, "|a, b; c, d|"),
            (#"\begin{pmatrix} x \\ y \end{pmatrix}"#, "(x; y)"),
        ])
    }

    func testCasesAndAlignedEnvironments() {
        check([
            (#"|x|=\begin{cases} x & (x\geq 0) \\ -x & (x<0) \end{cases}"#, "|x| = { x (x ≥ 0); −x (x < 0) }"),
            (#"\begin{aligned} 2x+3 &= 11 \\ 2x &= 8 \\ x &= 4 \end{aligned}"#, "2x + 3 = 11\n2x = 8\nx = 4"),
            ("\\begin{align*}\n(x+1)^2 &= x^2+2x+1 \\\\\n&= x(x+2)+1\n\\end{align*}", "(x + 1)² = x² + 2x + 1\n= x(x + 2) + 1"),
            (#"\begin{array}{c|cc} x & 0 & 1 \\ \hline f(x) & 1 & 2 \end{array}"#, "x | 0 | 1\nf(x) | 1 | 2"),
        ])
    }

    // MARK: Things that are not supported by the typesetter

    func testUnsupportedCommandsStillRead() {
        check([
            (#"\boxed{x=1}"#, "[x = 1]"),
            (#"\ce{H2O}"#, "H₂O"),
            (#"\ce{CO2}"#, "CO₂"),
            (#"\underbrace{a+b+c}_{3\text{個}}"#, "a + b + c (3個)"),
            (#"A \xrightarrow{f} B"#, "A ─f→ B"),
            (#"A \xleftarrow[g]{} B"#, "A ←g─ B"),
            (#"\color{red}{x=1}"#, "x = 1"),
            (#"\textbf{太字}"#, "太字"),
            (#"\href{https://example.com}{リンク}"#, "リンク (https://example.com)"),
            (#"\newcommand{\R}{\mathbb{R}}\R^n"#, "ℝⁿ"),
            (#"\somethingunknown{x} + \anotherone"#, "\\somethingunknown(x) + \\anotherone"),
        ])
    }

    // MARK: Robustness

    func testMalformedInputNeverCrashes() {
        let inputs = ["", "{", "}", "^", "_", "\\", "\\frac", "\\frac{1", "\\left(", "\\right)", "\\begin{pmatrix}",
                      "\\end{x}", "x^", "x_{", "\\sqrt[", "{{{{{{{{", "\\\\\\\\", "&&&&", "\\newcommand", "$$", "\\text{",
                      "\\begin{cases} x &", String(repeating: "{", count: 500), String(repeating: "\\frac{", count: 200)]
        for input in inputs { _ = MathTextFormatter.readableMath(from: input) }
    }

    // MARK: Whole replies

    func testReadableTextConvertsMathAndLeavesTheRestAlone() {
        XCTAssertEqual(
            MathTextFormatter.readableText(from: #"解は $x = \frac{-b}{2a}$ です。"#),
            "解は x = (−b)/(2a) です。"
        )
        XCTAssertEqual(
            MathTextFormatter.readableText(from: "計算は次のとおり。\n\n$$\\int_0^1 x^2\\,dx = \\frac13$$\n\n以上です。"),
            "計算は次のとおり。\n\n∫₀¹ x² dx = 1/3\n\n以上です。"
        )
    }

    func testADisplayFormulaGetsALineOfItsOwnWithoutStrayWhitespace() {
        XCTAssertEqual(
            MathTextFormatter.readableText(from: "結果は $$x=1$$ になります。"),
            "結果は\nx = 1\nになります。"
        )
        XCTAssertEqual(
            MathTextFormatter.readableText(from: "- 手順2:\n  $$x+2=5$$\n- 手順3"),
            "- 手順2:\nx + 2 = 5\n- 手順3"
        )
    }

    func testCodeIsLeftExactlyAsWritten() {
        let source = "実行:\n\n```bash\necho $HOME\nlatex='\\frac{1}{2}'\n```\n\n`\\frac{a}{b}` と書く。"
        XCTAssertEqual(MathTextFormatter.readableText(from: source), source)
    }

    func testPlainTextRemovesMarkdownMarkers() {
        let source = "## 結論\n\n**重要**: $x=2$ のとき *最大* です。\n\n- 手順1\n- 手順2\n\n> 引用\n\n[リンク](https://example.com)"
        XCTAssertEqual(
            MathTextFormatter.plainText(from: source),
            "結論\n\n重要: x = 2 のとき 最大 です。\n\n・手順1\n・手順2\n\n引用\n\nリンク (https://example.com)"
        )
    }

    func testPlainTextKeepsCodeContentWithoutFences() {
        XCTAssertEqual(
            MathTextFormatter.plainText(from: "例:\n\n```python\nx = 2 * 3\n```\n\nと `a*b` です。"),
            "例:\n\nx = 2 * 3\n\nと a*b です。"
        )
    }

    func testPlainTextTable() {
        XCTAssertEqual(
            MathTextFormatter.plainText(from: "| 関数 | 導関数 |\n|---|---|\n| $x^2$ | $2x$ |"),
            "関数 | 導関数\nx² | 2x"
        )
    }

    // MARK: The corpus

    private func isCodeSample(_ s: AIMathSample) -> Bool { ["inline-code", "code-block-with-dollars"].contains(s.id) }

    /// Nothing the typesetter could draw is left as LaTeX in the plain text.
    func testNoLaTeXIsLeftInTheConvertedCorpus() throws {
        let leftover = try NSRegularExpression(pattern: #"\\[A-Za-z]+"#)
        for sample in AIMathSamples.all
        where ![.falsePositive, .streamingPrefix, .unsupported].contains(sample.category) && !isCodeSample(sample) {
            let converted = MathTextFormatter.readableText(from: sample.text)
            let range = NSRange(converted.startIndex..., in: converted)
            XCTAssertNil(leftover.firstMatch(in: converted, range: range), "\(sample): LaTeXが残っています: \(converted)")
            if sample.hasInlineMath || sample.hasDisplayMath {
                XCTAssertFalse(converted.contains("$"), "\(sample): $ が残っています: \(converted)")
            }
        }
    }

    func testPricesAndShellVariablesAreUntouched() {
        for id in ["prices-in-prose", "decimal-price", "price-range", "shell-variable", "single-dollar"] {
            let sample = AIMathSamples.sample(id: id)!
            XCTAssertEqual(MathTextFormatter.readableText(from: sample.text), sample.text, id)
        }
        XCTAssertEqual(MathTextFormatter.readableText(from: AIMathSamples.sample(id: "escaped-dollar")!.text), "価格は $5 です。")
        XCTAssertEqual(
            MathTextFormatter.readableText(from: AIMathSamples.sample(id: "prices-then-real-math")!.text),
            "商品は$100と$200で、割引後は x = 0.8 × 300 円です。"
        )
    }

    func testAlreadyReadableTextDoesNotChange() {
        for id in ["unicode-math", "japanese-only"] {
            let sample = AIMathSamples.sample(id: id)!
            XCTAssertEqual(MathTextFormatter.readableText(from: sample.text), sample.text, id)
        }
    }

    func testConversionIsIdempotent() {
        for sample in AIMathSamples.all where !sample.isPartial && ![.falsePositive, .unsupported].contains(sample.category) && !isCodeSample(sample) {
            let once = MathTextFormatter.readableText(from: sample.text)
            XCTAssertEqual(MathTextFormatter.readableText(from: once), once, "\(sample)")
        }
    }

    func testEveryStreamingStateConverts() {
        for sample in AIMathSamples.all {
            for prefix in AIMathSamples.streamingPrefixes(of: sample.text, step: 4) {
                _ = MathTextFormatter.readableText(from: prefix)
                _ = MathTextFormatter.plainText(from: prefix)
            }
        }
    }

    func testPlainTextOfTheWholeCorpusHasNoMarkdownMarkersOrLaTeX() throws {
        let leftover = try NSRegularExpression(pattern: #"\\[A-Za-z]+|\*\*|^#{1,6} |\$"#, options: [.anchorsMatchLines])
        for sample in AIMathSamples.all
        where sample.category == .fullReply || sample.category == .markdown {
            guard !isCodeSample(sample) else { continue }
            let plain = MathTextFormatter.plainText(from: sample.text)
            XCTAssertNil(leftover.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)), "\(sample): \(plain)")
        }
    }

    /// A streaming reply is converted again on every chunk, so it must be cheap.
    func testConvertingALongReplyIsFast() {
        let reply = AIMathSamples.all.filter { $0.category == .fullReply }.map(\.text).joined(separator: "\n\n")
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { _ = MathTextFormatter.plainText(from: reply) }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 100
        print("PERF plainText of \(reply.count) characters: \(String(format: "%.2f", milliseconds)) ms each")
        XCTAssertLessThan(milliseconds, 20, "1回の変換が遅すぎます")
    }
}

