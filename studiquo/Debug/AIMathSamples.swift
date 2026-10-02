#if DEBUG
import Foundation

/// One piece of AI output as a model actually writes it: Japanese prose with
/// LaTeX math and Markdown mixed in. The shared test material for turning that
/// into something readable — the plain-text converter, the block parser and
/// the on-screen renderer are all checked against this corpus.
///
/// Debug builds only. UI tests ask the fake AI for a sample by `id`
/// (`--ui-test-ai-sample=<id>`), so a screen can be checked without a network.
///
/// To add a real reply that rendered badly, paste it as a raw string
/// (`#"..."#`) so backslashes stay as written.
struct AIMathSample: Identifiable, CustomStringConvertible {
    enum Category: String, CaseIterable {
        case algebra, calculus, series, linearAlgebra, logicAndSets, probability
        case trigAndLog, textInMath, environments, delimiters, accents, sizingAndSpacing
        case markdown
        /// Looks like math to a naive scanner but is not (prices, shell variables).
        case falsePositive
        /// LaTeX the renderer may not support; must degrade, never vanish.
        case unsupported
        /// Already readable: converting it again must change nothing.
        case alreadyUnicode
        /// Cut off mid-formula or mid-markup, as a streaming reply is.
        case streamingPrefix
        /// Whole multi-paragraph replies.
        case fullReply
    }

    let id: String
    let category: Category
    let text: String
    var hasInlineMath = false
    var hasDisplayMath = false
    /// Ends in the middle of a formula or markup, like a half-streamed reply.
    var isPartial = false

    var description: String { "\(category.rawValue)/\(id)" }
}

enum AIMathSamples {
    static func sample(id: String) -> AIMathSample? {
        all.first { $0.id == id }
    }

    /// Every prefix a streaming reply passes through, `step` characters apart,
    /// ending with the full text.
    static func streamingPrefixes(of text: String, step: Int = 7) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var prefixes = stride(from: step, to: characters.count, by: step).map { String(characters[..<$0]) }
        prefixes.append(text)
        return prefixes
    }

    private static func s(
        _ id: String, _ category: AIMathSample.Category, _ text: String,
        inline: Bool = false, display: Bool = false, partial: Bool = false
    ) -> AIMathSample {
        AIMathSample(id: id, category: category, text: text,
                     hasInlineMath: inline, hasDisplayMath: display, isPartial: partial)
    }

    static let all: [AIMathSample] =
        algebra + calculus + series + linearAlgebra + logicAndSets + probability
        + trigAndLog + textInMath + environments + delimiters + accents + sizingAndSpacing
        + markdown + falsePositive + unsupported + alreadyUnicode + streamingPrefix + fullReply

    // MARK: Algebra

    static let algebra: [AIMathSample] = [
        s("quadratic-formula", .algebra,
          #"二次方程式 $ax^2+bx+c=0$ の解は、解の公式より $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$ です。判別式 $D=b^2-4ac$ が正なら異なる2つの実数解を持ちます。"#,
          inline: true),
        s("complete-the-square", .algebra,
          "平方完成すると次のようになります。\n\n$$x^2+6x+5=(x+3)^2-4$$\n\nよって頂点は $(-3,\\,-4)$ です。",
          inline: true, display: true),
        s("binomial-squares", .algebra,
          #"$(a+b)^2 = a^2 + 2ab + b^2$ と $(a-b)^2 = a^2 - 2ab + b^2$ は必ず覚えましょう。"#,
          inline: true),
        s("nested-fraction", .algebra,
          #"$\frac{1}{1+\frac{1}{x}}$ を整理すると $\frac{x}{x+1}$ になります。"#,
          inline: true),
        s("exponents", .algebra,
          #"$2^{10}=1024$、$x^{n+1}$、$e^{-x^2}$、漸化式 $a_{n+1}=a_n+d$ のように、指数や添字が複数文字のときは波括弧を使います。"#,
          inline: true),
        s("inequality", .algebra,
          #"$|x-2| < 3 \iff -1 < x < 5$ なので、解は $-1<x<5$ です。"#,
          inline: true),
        s("roots", .algebra,
          #"$\sqrt[3]{27}=3$、$\sqrt{2+\sqrt{3}}$ のような入れ子の根号もあります。"#,
          inline: true),
        s("fractions-styles", .algebra,
          #"$\frac{a}{b}\times\frac{c}{d}=\frac{ac}{bd}$、$\dfrac{1}{2}$、$\tfrac{3}{4}$ はどれも分数です。"#,
          inline: true),
    ]

    // MARK: Calculus

    static let calculus: [AIMathSample] = [
        s("derivative-definition", .calculus,
          #"導関数の定義は $f'(x)=\lim_{h \to 0}\frac{f(x+h)-f(x)}{h}$ です。"#, inline: true),
        s("chain-rule", .calculus,
          #"合成関数の微分: $\frac{d}{dx}\sin(x^2) = 2x\cos(x^2)$。記号 $\frac{dy}{dx}$ や $\frac{\partial f}{\partial x}$ も出てきます。"#,
          inline: true),
        s("definite-integral", .calculus,
          "計算は次のとおりです。\n\n$$\\int_{0}^{1} x^2\\,dx = \\left[\\frac{x^3}{3}\\right]_0^1 = \\frac{1}{3}$$\n\n面積は $\\frac13$ です。",
          inline: true, display: true),
        s("improper-integral", .calculus,
          #"ガウス積分 $\int_{-\infty}^{\infty} e^{-x^2}dx=\sqrt{\pi}$ は有名です。"#, inline: true),
        s("multiple-integrals", .calculus,
          #"重積分 $\iint_D f(x,y)\,dA$ や周回積分 $\oint_C \vec{F}\cdot d\vec{r}$ にも同じ考え方が使えます。"#,
          inline: true),
        s("taylor-series", .calculus,
          "マクローリン展開:\n\n$$e^x = \\sum_{n=0}^{\\infty}\\frac{x^n}{n!}$$",
          display: true),
        s("limit-e", .calculus,
          #"$\lim_{x\to\infty}\left(1+\frac1x\right)^x=e$ が $e$ の定義の一つです。"#, inline: true),
        s("gradient", .calculus,
          #"勾配は $\nabla f = \left(\frac{\partial f}{\partial x}, \frac{\partial f}{\partial y}\right)$ と書きます。"#,
          inline: true),
    ]

    // MARK: Series and products

    static let series: [AIMathSample] = [
        s("sum-of-integers", .series,
          #"自然数の和は $\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$ です。"#, inline: true),
        s("geometric-series", .series,
          "等比数列の和:\n\n$$\\sum_{k=0}^{n-1} ar^k=\\frac{a(1-r^n)}{1-r}\\quad (r\\neq1)$$",
          display: true),
        s("factorial-product", .series,
          #"階乗は $\prod_{i=1}^{n} i = n!$ と書けます。"#, inline: true),
        s("recurrence", .series,
          #"数列 $\{a_n\}$ が $a_1=1,\ a_{n+1}=2a_n+1$ を満たすとき、一般項は $a_n=2^n-1$ です。"#,
          inline: true),
    ]

    // MARK: Linear algebra

    static let linearAlgebra: [AIMathSample] = [
        s("matrix-2x2", .linearAlgebra,
          "行列の積:\n\n$$\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}\\begin{pmatrix} x \\\\ y \\end{pmatrix}=\\begin{pmatrix} x+2y \\\\ 3x+4y \\end{pmatrix}$$",
          display: true),
        s("matrix-3x3", .linearAlgebra,
          "単位行列は\n$$I=\\begin{bmatrix} 1 & 0 & 0 \\\\ 0 & 1 & 0 \\\\ 0 & 0 & 1 \\end{bmatrix}$$ です。",
          display: true),
        s("determinant", .linearAlgebra,
          "$$\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}=ad-bc$$",
          display: true),
        s("vectors", .linearAlgebra,
          #"内積は $\vec{a}\cdot\vec{b}=|\vec{a}||\vec{b}|\cos\theta$、太字のベクトル $\mathbf{v}$ も使います。"#,
          inline: true),
        s("inverse-transpose", .linearAlgebra,
          #"逆行列 $A^{-1}$ と転置 $A^{\mathsf{T}}$、または $A^T$ を区別しましょう。"#, inline: true),
        s("eigenvalues", .linearAlgebra,
          #"固有値は特性方程式 $\det(A-\lambda I)=0$ の解です。"#, inline: true),
    ]

    // MARK: Logic and sets

    static let logicAndSets: [AIMathSample] = [
        s("epsilon-delta", .logicAndSets,
          #"連続の定義: $\forall \varepsilon>0,\ \exists \delta>0,\ |x-a|<\delta \Rightarrow |f(x)-f(a)|<\varepsilon$。"#,
          inline: true),
        s("set-operations", .logicAndSets,
          #"$A \subset B$、$A \cup B$、$A \cap B$、$A \setminus B$、$\emptyset$ は集合の基本記号です。"#,
          inline: true),
        s("number-sets", .logicAndSets,
          #"$\mathbb{N}\subset\mathbb{Z}\subset\mathbb{Q}\subset\mathbb{R}\subset\mathbb{C}$ という包含関係があります。"#,
          inline: true),
        s("logic-connectives", .logicAndSets,
          #"$P \Rightarrow Q$、$P \Leftrightarrow Q$、$\neg P$、$P \land Q$、$P \lor Q$ を真理値表で確かめましょう。"#,
          inline: true),
        s("induction-proof", .logicAndSets,
          "**数学的帰納法**で示します。\n\n1. $n=1$ のとき、左辺 $=1$、右辺 $=\\frac{1\\cdot 2}{2}=1$ で成り立つ。\n2. $n=k$ で成り立つと仮定すると $\\sum_{i=1}^{k} i=\\frac{k(k+1)}{2}$。\n3. $n=k+1$ のとき、$\\frac{k(k+1)}{2}+(k+1)=\\frac{(k+1)(k+2)}{2}$ となり成り立つ。\n\nよって、すべての自然数 $n$ で成り立つ。$\\blacksquare$",
          inline: true),
        s("therefore-because", .logicAndSets,
          #"$\because x>0$ なので $\therefore \sqrt{x^2}=x$ です。"#, inline: true),
    ]

    // MARK: Probability

    static let probability: [AIMathSample] = [
        s("binomial-coefficient", .probability,
          #"組合せの数は $\binom{n}{k}=\frac{n!}{k!(n-k)!}$ です。"#, inline: true),
        s("conditional-probability", .probability,
          #"条件付き確率 $P(A\mid B)=\frac{P(A\cap B)}{P(B)}$ を使います。"#, inline: true),
        s("expectation-variance", .probability,
          #"期待値 $E[X]=\sum_i x_i p_i$、分散 $\mathrm{Var}(X)=E[X^2]-\left(E[X]\right)^2$ です。"#,
          inline: true),
        s("normal-density", .probability,
          "正規分布の密度関数:\n\n$$f(x)=\\frac{1}{\\sqrt{2\\pi\\sigma^2}}e^{-\\frac{(x-\\mu)^2}{2\\sigma^2}}$$",
          display: true),
        s("japanese-combinations", .probability,
          #"日本の教科書の記法では ${}_n\mathrm{C}_r$ や ${}_n\mathrm{P}_r$ と書きます。"#, inline: true),
    ]

    // MARK: Trigonometry and logarithms

    static let trigAndLog: [AIMathSample] = [
        s("pythagorean-identity", .trigAndLog,
          #"$\sin^2\theta+\cos^2\theta=1$ はいつでも成り立ちます。"#, inline: true),
        s("logarithms", .trigAndLog,
          #"$\log_2 8=3$、$\ln e=1$、$\log_{10} 1000 = 3$。"#, inline: true),
        s("addition-theorem", .trigAndLog,
          #"加法定理: $\sin(\alpha+\beta)=\sin\alpha\cos\beta+\cos\alpha\sin\beta$。"#, inline: true),
        s("degrees-radians", .trigAndLog,
          #"$30^\circ=\frac{\pi}{6}$ ラジアン、$\tan\theta=\frac{\sin\theta}{\cos\theta}$ です。"#,
          inline: true),
        s("inverse-trig", .trigAndLog,
          #"$\operatorname{arcsin}\frac12=\frac{\pi}{6}$ のように逆三角関数を使います。"#, inline: true),
    ]

    // MARK: Japanese text inside math

    static let textInMath: [AIMathSample] = [
        s("speed-formula", .textInMath,
          #"$\text{速さ}=\frac{\text{距離}}{\text{時間}}$ なので、時間が2倍になると速さは半分です。"#,
          inline: true),
        s("units", .textInMath,
          #"速度 $60\,\mathrm{km/h}$、加速度 $9.8\,\mathrm{m/s}^2$ のように単位は立体で書きます。"#,
          inline: true),
        s("condition-in-math", .textInMath,
          #"$f(x)=\sqrt{x} \quad \text{ただし } x\geq 0$ という条件が必要です。"#, inline: true),
        s("japanese-labels", .textInMath,
          "$$\\text{利益}=\\text{売上}-\\text{費用}$$",
          display: true),
    ]

    // MARK: Environments

    static let environments: [AIMathSample] = [
        s("piecewise-cases", .environments,
          "絶対値は場合分けで表せます。\n\n$$|x|=\\begin{cases} x & (x\\geq 0) \\\\ -x & (x<0) \\end{cases}$$",
          display: true),
        s("aligned-steps", .environments,
          "$$\\begin{aligned} 2x+3 &= 11 \\\\ 2x &= 8 \\\\ x &= 4 \\end{aligned}$$",
          display: true),
        s("align-star", .environments,
          "\\begin{align*}\n(x+1)^2 &= x^2+2x+1 \\\\\n&= x(x+2)+1\n\\end{align*}",
          display: true),
        s("array-table", .environments,
          "$$\\begin{array}{c|cc} x & 0 & 1 \\\\ \\hline f(x) & 1 & 2 \\end{array}$$",
          display: true),
        s("gather", .environments,
          "\\begin{gather}\na+b=c \\\\\nc-b=a\n\\end{gather}",
          display: true),
    ]

    // MARK: Delimiter styles

    static let delimiters: [AIMathSample] = [
        s("paren-delimiters", .delimiters,
          #"解は \(x=2\) と \(x=-3\) です。"#, inline: true),
        s("bracket-delimiters", .delimiters,
          "答えは次のとおりです。\n\\[ x=\\frac{1}{2} \\]\n以上です。",
          display: true),
        s("double-dollar-inline", .delimiters,
          #"結果は $$x=1$$ になります（文の途中の二重ドル）。"#, display: true),
        s("math-next-to-punctuation", .delimiters,
          #"変数（$x$）、定数（$a$）、そして関数「$f(x)$」を区別します。"#, inline: true),
        s("display-in-list", .delimiters,
          "- 手順1: 両辺に $2$ を足す\n- 手順2:\n  $$x+2=5$$\n- 手順3: $x=3$",
          inline: true, display: true),
        s("math-at-line-start", .delimiters,
          "$x^2 \\geq 0$ はすべての実数 $x$ で成り立ちます。",
          inline: true),
    ]

    // MARK: Accents and geometry

    static let accents: [AIMathSample] = [
        s("accents", .accents,
          #"$\hat{x}$、$\bar{x}$、$\tilde{y}$、$\dot{x}$、$\ddot{x}$、$\overline{AB}$、$\overrightarrow{AB}$ のように記号の上に印を付けます。"#,
          inline: true),
        s("geometry", .accents,
          #"$\angle ABC=90^\circ$、$\triangle ABC \cong \triangle DEF$、$AB \parallel CD$、$AB \perp BC$、$\triangle ABC \sim \triangle DEF$。"#,
          inline: true),
        s("wide-accents", .accents,
          #"$\widehat{ABC}$ と $\widetilde{xyz}$ は幅の広い印です。"#, inline: true),
    ]

    // MARK: Sizing and spacing commands

    static let sizingAndSpacing: [AIMathSample] = [
        s("left-right", .sizingAndSpacing,
          #"$\left( \frac{a}{b} \right)^2$ や $\left\{ x \mid x>0 \right\}$ のように括弧の大きさを合わせます。"#,
          inline: true),
        s("big-delimiters", .sizingAndSpacing,
          #"$\bigl( a+b \bigr)$、$\Big[ \frac{1}{2} \Big]$、$\Bigg\{ x \Bigg\}$。"#, inline: true),
        s("dots-and-spaces", .sizingAndSpacing,
          #"$1+2+\cdots+n$、$a_1, a_2, \ldots, a_n$、$x\;y\,z\!w$、$a \quad b$。"#, inline: true),
    ]

    // MARK: Markdown mixed with math

    static let markdown: [AIMathSample] = [
        s("headings", .markdown,
          "# 二次関数\n\n## 頂点の求め方\n\n### 手順\n\n文章です。"),
        s("bullets-with-math", .markdown,
          "- 判別式 $D=b^2-4ac$ を計算する\n- $D>0$ なら実数解が2つ\n- $D=0$ なら重解\n- $D<0$ なら実数解なし",
          inline: true),
        s("numbered-steps", .markdown,
          "1. 両辺を $2$ で割る\n2. 移項して $x=\\frac{c-b}{a}$ を得る\n3. 検算する",
          inline: true),
        s("bold-italic", .markdown,
          "これは**とても重要**で、*ここも大事*、***両方***です。"),
        s("inline-code", .markdown,
          "Pythonでは `x ** 2` と書き、LaTeXでは `\\frac{a}{b}` と書きます。"),
        s("code-block-with-dollars", .markdown,
          "次のコードを実行します。\n\n```bash\necho $HOME\nprice=$100\nlatex='\\frac{1}{2}'\n```\n\nコード内の記号は変換しません。"),
        s("blockquote", .markdown,
          "> 定理: $a^2+b^2=c^2$\n> （三平方の定理）\n\n続きの文章です。",
          inline: true),
        s("table-with-math", .markdown,
          "| 関数 | 導関数 |\n|---|---|\n| $x^2$ | $2x$ |\n| $\\sin x$ | $\\cos x$ |\n| $e^x$ | $e^x$ |",
          inline: true),
        s("nested-bullets", .markdown,
          "- 場合分け\n  - $x\\geq 0$ のとき $|x|=x$\n  - $x<0$ のとき $|x|=-x$\n- まとめ",
          inline: true),
        s("horizontal-rule", .markdown, "前半です。\n\n---\n\n後半です。"),
    ]

    // MARK: Things that look like math but are not

    static let falsePositive: [AIMathSample] = [
        s("prices-in-prose", .falsePositive, "りんごは$100、みかんは$200です。合計は$300です。"),
        s("decimal-price", .falsePositive, "この本は$5.99で、あの本は$12.50です。"),
        s("price-range", .falsePositive, "料金は$20〜$30の間です。"),
        s("shell-variable", .falsePositive, "環境変数は `$HOME` や `$PATH` で参照します。"),
        s("single-dollar", .falsePositive, "記号 $ は通貨を表します。"),
        s("escaped-dollar", .falsePositive, #"価格は \$5 です。"#),
        s("prices-then-real-math", .falsePositive,
          #"商品は$100と$200で、割引後は $x = 0.8 \times 300$ 円です。"#, inline: true),
    ]

    // MARK: LaTeX the renderer may not support

    static let unsupported: [AIMathSample] = [
        s("chemistry-ce", .unsupported, #"水は $\ce{H2O}$、二酸化炭素は $\ce{CO2}$ です。"#, inline: true),
        s("color", .unsupported, #"ここが重要: $\color{red}{x=1}$"#, inline: true),
        s("boxed", .unsupported, #"答え: $\boxed{x=1}$"#, inline: true),
        s("underbrace", .unsupported, #"$\underbrace{a+b+c}_{3\text{個}}$ と $\overbrace{x+y}^{2}$"#, inline: true),
        s("extensible-arrow", .unsupported, #"$A \xrightarrow{f} B$ と $A \xleftarrow[g]{} B$"#, inline: true),
        s("custom-macro", .unsupported, #"$\newcommand{\R}{\mathbb{R}}\R^n$ と $\mathcal{L}$、$\mathscr{F}$"#, inline: true),
        s("text-formatting", .unsupported, #"$\textbf{太字}$ と $\textit{斜体}$ と $\href{https://example.com}{リンク}$"#, inline: true),
        s("unknown-command", .unsupported, #"$\somethingunknown{x} + \anotherone$"#, inline: true),
    ]

    // MARK: Already readable text

    static let alreadyUnicode: [AIMathSample] = [
        s("unicode-math", .alreadyUnicode, "x² + y² = r²、√2 ≈ 1.414、∫₀¹ x dx = 1/2、α ≤ β"),
        s("unicode-with-latex", .alreadyUnicode, #"x² は $x^2$ と書くこともでき、√2 は $\sqrt{2}$ です。"#, inline: true),
        s("japanese-only", .alreadyUnicode, "今日は二次関数について学びます。グラフは放物線になります。"),
    ]

    // MARK: Cut off mid-stream

    static let streamingPrefix: [AIMathSample] = [
        s("cut-fraction", .streamingPrefix, #"答えは $\frac{1"#, partial: true),
        s("cut-display-integral", .streamingPrefix, "$$\\int_0^", partial: true),
        s("cut-cases", .streamingPrefix, "$$|x|=\\begin{cases} x &", partial: true),
        s("cut-bold", .streamingPrefix, "これは**重", partial: true),
        s("cut-code-fence", .streamingPrefix, "```python\nx = 1", partial: true),
        s("cut-inline-math", .streamingPrefix, "二次方程式 $ax^2+b", partial: true),
        s("cut-command", .streamingPrefix, #"解は $x = \f"#, partial: true),
        s("cut-bracket-display", .streamingPrefix, "\\[ x^2", partial: true),
        s("cut-list-item", .streamingPrefix, "- 手順1: $a", partial: true),
        s("lone-dollar", .streamingPrefix, "計算すると $", partial: true),
    ]

    // MARK: Whole replies

    static let fullReply: [AIMathSample] = [
        s("reply-quadratic-extremum", .fullReply, """
        ## 二次関数の最大・最小

        $y=-2x^2+8x-3$ の最大値を求めます。

        ### 考え方
        平方完成をして頂点を見つけます。

        1. $-2$ でくくる: $y=-2(x^2-4x)-3$
        2. 平方完成する: $y=-2\\{(x-2)^2-4\\}-3$
        3. 展開して整理する:

        $$y=-2(x-2)^2+5$$

        ### 結論
        上に凸の放物線なので、**$x=2$ のとき最大値 $5$** をとります。最小値はありません（$x\\to\\pm\\infty$ で $y\\to-\\infty$）。

        次の一手として、頂点の $x$ 座標を $x=-\\frac{b}{2a}$ で確かめてみましょう。
        """, inline: true, display: true),
        s("reply-marking-report", .fullReply, """
        【7 / 10点】

        概ね正しい証明ですが、一部に飛躍があります。

        ※ この採点はAIによるものです。誤りを含むことがあるため、参考としてご利用ください。

        ■ 採点内訳
        ・論理の正しさ　4/5点
        　　$n=k+1$ の場合に、仮定 $\\sum_{i=1}^{k} i=\\frac{k(k+1)}{2}$ を使う箇所を明示してください。
        ・記述の明確さ　3/5点

        ■ 指摘
        ・[論理の飛躍] したがって $\\frac{k(k+1)}{2}+(k+1)=\\frac{(k+1)(k+2)}{2}$
        　　通分の過程が省略されています。
        　　→ $\\frac{k(k+1)+2(k+1)}{2}$ のように一段階書いてください。
        """, inline: true),
        s("reply-derivative-plan", .fullReply, """
        微分の学習は次の順番がおすすめです。

        - **極限**: $\\lim_{x\\to a}f(x)$ の意味をつかむ
        - **導関数の定義**: $f'(x)=\\lim_{h\\to0}\\frac{f(x+h)-f(x)}{h}$
        - **公式**: $(x^n)'=nx^{n-1}$、$(\\sin x)'=\\cos x$、$(e^x)'=e^x$
        - **積と商の微分**: $(fg)'=f'g+fg'$、$\\left(\\frac{f}{g}\\right)'=\\frac{f'g-fg'}{g^2}$

        まずは $f(x)=x^2$ を定義から微分してみましょう。$\\frac{(x+h)^2-x^2}{h}$ を計算するとどうなりますか？
        """, inline: true),
        s("reply-review-explanation", .fullReply, """
        # 加法定理のまとめ

        ## 要点
        - $\\sin(\\alpha\\pm\\beta)=\\sin\\alpha\\cos\\beta\\pm\\cos\\alpha\\sin\\beta$
        - $\\cos(\\alpha\\pm\\beta)=\\cos\\alpha\\cos\\beta\\mp\\sin\\alpha\\sin\\beta$
        - $\\tan(\\alpha+\\beta)=\\frac{\\tan\\alpha+\\tan\\beta}{1-\\tan\\alpha\\tan\\beta}$

        ## 使いどころ
        $75^\\circ=45^\\circ+30^\\circ$ と分けると、$\\sin75^\\circ=\\frac{\\sqrt6+\\sqrt2}{4}$ が求まります。

        ## 注意
        $\\cos$ の符号は左右で逆になります（$\\pm$ と $\\mp$）。
        """, inline: true),
        s("reply-english-mixed", .fullReply, """
        The **Cauchy–Schwarz inequality** states that for vectors $u, v$,

        $$|\\langle u, v\\rangle| \\leq \\|u\\|\\,\\|v\\|$$

        日本語で言うと「内積の絶対値は、長さの積以下」です。等号は $u$ と $v$ が平行のときに成り立ちます。
        """, inline: true, display: true),
    ]
}
#endif
