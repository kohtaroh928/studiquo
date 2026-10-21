# 検索の再評価（合成100ページ・60問とvalidation 20問）

2026-10-21。対象は `claude/rag-ts`（960f83d）の検索コード。2026-10-08の修正前記録と同じ固定fixtureを、同じ実行手順で測り直した。コード・fixture・期待値は変更していない。生の結果は[RAG_REEVALUATION_20261021_RESULTS.json](RAG_REEVALUATION_20261021_RESULTS.json)。

## 結論

- 主評価の正解あり55問で、必要な正解ページがTop5にすべてそろったのは **55/55**（修正前の記録は52/55、最初の評価は41/55）。
- 修正前に取りこぼした3件（def-2、def-12、ocr-17）は、すべて解消していた。リランクで正解が落ちる現象は、この実行では起きなかった。
- validationの難しい否定10問（同じ話題で本文に答えがない）は、**不要な出典が5件→0件**になった。
- validationの正解あり10問は10/10のまま変化なし。

**これは調整済みの問題での確認で、汎化の証拠ではない。** 下の「限界」を必ず併読すること。

## 評価の範囲と条件

- 固定した100ページの合成日本語PDF（文字層80ページ、画像のみ20ページ）。OCRはmacOS Vision。今回のOCRは文字誤り率0.16%、重要文の一致18/20、中央値210ms/ページで、10/8と同等。
- 検索は実装のindexSource／retrieveをそのまま使用。Workers AIのEmbedding（bge-m3）とRerank（bge-reranker-base）は実REST API。D1相当はローカルSQLite FTS5、Vectorize相当はローカルの厳密cosine。実Vectorizeの近似検索、実D1／Worker binding、実iPad、Gemini／OpenAIの最終回答は含まない。
- Recall@5は「正解ページのうちTop5に入った割合」の質問ごとの平均、MRR@5は最初の正解ページの逆順位の平均。「そろった」は、必要な正解ページがすべてTop5に入った質問。
- 使用量：主評価は235 API呼び出し（Embedding 180、Rerank 55）、約51.6 Neurons。validationは145呼び出し、約39.1 Neurons。すべてHTTP 200。

## 主評価（正解あり55問）の比較

比較対象は `RAG_SEARCH_QUALITY_V2_RESULTS.json`（10/8、取りこぼし修正の前）。表はRerank後（最終Top5）。

| 質問群 | 問数 | 修正前 Recall@5 | 今回 Recall@5 | 修正前 そろった | 今回 そろった | 修正前 MRR | 今回 MRR |
|---|---:|---:|---:|---:|---:|---:|---:|
| 言い換え | 20 | 90.0% | 100.0% | 18/20 | 20/20 | 0.760 | 0.910 |
| OCRページ | 20 | 95.0% | 100.0% | 19/20 | 20/20 | 0.900 | 0.950 |
| 比較 | 10 | 100.0% | 100.0% | 10/10 | 10/10 | 1.000 | 1.000 |
| 認識済みの曖昧質問（rewrite） | 5 | 100.0% | 100.0% | 5/5 | 5/5 | 0.900 | 1.000 |
| **合計** | **55** | **94.5%** | **100.0%** | **52/55** | **55/55** | **0.867** | **0.949** |

- RRF時点（Rerank前）は、修正前が96.4%・53/55、今回が100%・55/55。Rerank後に落ちる質問は、修正前3件、今回0件。
- 参考：最初の評価（RAG_SEARCH_QUALITY_EVALUATION.md、10/8）は、主評価55問のRecall@5が79.1%、そろった質問が41/55。
- 答えがない5問：5問とも出典なし（検索状態はfallback、通常チャットへ戻る）。修正前の記録も出典0件（insufficient）。
- 検索時間：中央値771ms、最大2,110ms（修正前は730ms、3,264ms）。ローカルDBと実APIの組み合わせの時間で、iPadの体感時間ではない。

## validation（20問）の比較

比較対象は `RAG_SEARCH_QUALITY_V2_VALIDATION.json`（10/8）。

| 項目 | 修正前 | 今回 |
|---|---:|---:|
| 正解あり10問（通常5＋比較5） Recall@5 | 100% | 100% |
| 同上 そろった質問 | 10/10 | 10/10 |
| 同上 MRR@5 | 0.900 | 0.900 |
| 難しい否定10問で、出典が付いた数 | 5 | **0** |
| 難しい否定10問の検索状態 | grounded 5／insufficient 5 | fallback 5／insufficient 5 |
| 検索時間（中央値／最大） | 719ms／2,071ms | 816ms／2,303ms |

修正前に不要な出典が付いたのは、hard-negative-1、2、4、7、10の5問。今回は10問とも出典なし。

## 限界（この数字をどう読むか）

1. **調整済みの問題である。** 主評価の取りこぼし3件は、まさにこの60問の中の問題を直したもの。100%は「直したものが直った」ことの確認で、未見の質問への強さの証拠ではない。
2. **validationの難しい否定10問も、設計に使われている。** 具体情報の根拠チェックの検証対象（RAG_ANSWERABILITY_IMPLEMENTATION_REPORT）と重なる。正解あり10問は数が少なく、悪化がないことの確認にとどまる。holdoutは過去に再利用済みで、今回は測っていない。
3. **自然な曖昧質問は含まれていない。** 最初の評価の「これのしくみを説明して」（正解ページ1/5）に当たるものは、この60問に入っていない。主評価のrewrite 5問は、既存の判定が認識する表現。未測定のまま。
4. **ローカル代替の測定。** 実Vectorize、実D1／Worker binding、実iPad、手書き・紙スキャン・図表・数式は含まない。
5. **実資料の再評価は未実施。** 気象庁の教科書30問の入力（PDF抽出、質問、正解）は `/private/tmp` から消えており、設計上リポジトリにも残していないため再現できない。やるなら、PDFの再取得と質問の作り直しが必要。
6. **最終回答の質は測っていない。** 本書は検索（Top5のページ）だけを対象にする。`claude/rag-followup`の出力フィルタ修正は、この`claude/rag-ts`には含まれない。

## 再現手順

```sh
R=/private/tmp/studiquo-rag-quality-run && mkdir -p $R
python3 mcp-server/scripts/rag-quality/build-fixture.py $R
swift mcp-server/scripts/rag-quality/pdf-ocr.swift $R
python3 mcp-server/scripts/rag-quality/ocr-metrics.py $R
cd mcp-server
STUDIQUO_RAG_QUALITY_REMOTE=true CLOUDFLARE_ACCOUNT_ID=<自分のID> node scripts/rag-quality/evaluate.ts $R
# validation：fixtureを評価ディレクトリへ複製して選択（結果は validation-results-v2.json）
cp scripts/rag-quality/validation-fixture.json $R/
STUDIQUO_RAG_QUALITY_SET=validation STUDIQUO_RAG_QUALITY_REMOTE=true CLOUDFLARE_ACCOUNT_ID=<自分のID> node scripts/rag-quality/evaluate.ts $R
```

評価はWranglerの保存済みOAuthログインを使用した。2つの結果が同じ評価ディレクトリを使うとvalidationの結果は別ファイルに出るが、実行前に主評価の結果を退避しておくと安全。Node 24が必要。

## 次の作業

1. 調整に使っていない新しい資料・新しい質問で測る（実資料の質問の作り直しを含む）。
2. 自然な曖昧質問の評価セットを作り、聞き返しの接続前後を比べる。
3. 実Vectorize／実D1のstaging、実iPadでの再評価。

テスト基準：同日に `claude/rag-ts` のWorkerテスト全体が2358件中2357件成功、失敗0、スキップ1。`node_modules` が切れたリンクだったため `npm ci` で入れ直した（git管理外）。API鍵・本文・質問は記録していない。

Projectの資料の更新: なし（評価の記録のみ。方式・公開状態の変更なし）。
