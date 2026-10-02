# AIの出力の数式を読みやすく表示する

## 問題
AIは数式をLaTeX(`$\frac{a}{b}$`、`x^{2}`)で、書式をMarkdown(`**太字**`、`## 見出し`)で返す。
アプリはそれを加工せずに表示するため、記号がそのまま画面に出て読みづらい。

原因は3つ:
1. サーバーの指示文(`mcp-server/src/ai.js` の `CHAT_SYSTEM` など)に、数式・書式の指定がない。
2. 返答を `Text(message.text)` でそのまま表示している(`Views/AIChatView.swift` の `AIChatBubble`)。
3. 既存の `MathExpression` は小さな部分集合(分数・累乗・添字・根号・ギリシャ文字)で、AIの出力には足りない。
   未対応のコマンドは名前がそのまま出る(`\left` → 「left」)。

## 方針(A・B・C をすべて実装する)
- **A** AIへの指示: 数式を `$…$`(行内)と `$$…$$`(独立した行)で書かせる。
- **B** 読みやすいテキストへの変換: LaTeXを `x²`、`(a+b)/2`、`Σ` などの文字にする。
  コピー、「ページに貼り付け」、VoiceOver、通知、描画に失敗したときの代替表示に使う。
- **C** 本格的な組版: SwiftMath(MIT)で数式を描画する。Markdownは自前で段落に分けて組み立てる。

保存データは変えない。変換と描画は表示時にだけ行う(過去の会話にも効く)。

## 適用先(AIの文章が使われる場所)
| 場所 | ファイル |
|---|---|
| チャットの返答 | `Views/AIChatView.swift`(`AIChatBubble`) |
| 採点レポート(返答として表示) | `Services/AIChatStore.swift`(`AIChatFormatting.markingReport`) |
| 復習の解説とクイズ | `Views/AIReviewDetailView.swift` |
| 復習の通知の本文 | `Views/ContentView.swift`(`item.explanationMarkdown`) |
| 復習用ドキュメントの生成 | `Services/AIReviewService.swift`(`DocumentBody.attributedString(fromMarkup:)`) |
| ページへの貼り付け | `Views/NoteEditorView.swift`(`insertAIResponseOnPage`) |
| AIへの指示(サーバー) | `mcp-server/src/ai.js`(`CHAT_SYSTEM` `RUBRIC_SYSTEM` `GRADE_SYSTEM` `REVIEW_SYSTEM`) |
| AIへの指示(アプリ内の直接Claude経路) | `Services/ClaudeChatService.swift`(`systemPrompt`) |

## ステップ
| # | 内容 | 担当 |
|---|---|---|
| 0 | 準備とサンプル集 | 共通 |
| 1 | 試作(SwiftMath、日本語まじりの式)。**続行の判断の地点** | C |
| 2 | LaTeX → 読みやすいテキストの変換(純粋な関数) | B |
| 3 | 文章の構造の分解(Markdownと数式。生成の途中状態に耐える) | B/C |
| 4 | 数式の描画部品と `RichMessageView` | C |
| 5 | チャットへの適用(コピー・貼り付け・VoiceOverはBのテキスト) | C/B |
| 6 | ほかの出力への適用(採点・復習・通知・貼り付け) | B/C |
| 7 | AIへの指示の更新とサーバーのテスト | A |
| 8 | 仕上げ(英訳・全体のテスト・性能・アクセシビリティ) | 共通 |

デプロイの順序: **アプリの更新を先に出し、その後でサーバーの指示文を更新する**
(古いアプリに新しい書き方の式が届くと、読みづらいまま出るため)。サーバーのデプロイは手作業。

## サンプル集
`studiquo/Debug/AIMathSamples.swift`(DEBUGビルド専用、約100件)。
日本語まじりの式、各分野の式、環境(`cases` `aligned` 行列)、区切りの種類、Markdown混在、
誤検出の例(`$100`、シェルの `$HOME`)、未対応のLaTeX、すでに読める文字、生成の途中で切れた形、返答全体。
`AIMathSamplesTests` が、ラベルとテキストの整合性を確認する。

実際に読みづらかった返答は、生の文字列(`#"..."#`)で貼り付けて追加する。

UIテストでは、テスト用のAIに `sample:<id>` と送ると、そのサンプルが少しずつ返る
(`--ui-test-fake-ai`)。例: `sample:reply-quadratic-extremum`。

## 現状の見た目(基準)
返答に `## 二次関数の最大・最小`、`$y=-2x^2+8x-3$`、`**$x=2$ のとき最大値 $5$**`、
`$x=-\frac{b}{2a}$` がそのまま出る。
