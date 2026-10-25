# 英字・数字の空白差への対応（2026-10-09）

## 修正

英字と数字の間の横方向の空白について、空白あり/なしを同じ識別子として検索・lexical判定できるようにした。合成例`ABC12.3`と`ABC 12.3`は同じidentityで、`ABC12.4`、`ABC123`、`ABC012.3`、接尾字の異なるものは別identityとして扱う。数値を丸めたり先頭ゼロを落としたりしない。

検索時のFTS aliasには旧索引で保存されている分離語/連結語の両方を含める。保存用searchText、chunk/heading、Embedding本文・hash、index version 2は変更せず、DB migration・再索引・再Embeddingは不要。元の質問・canonicalQuery・生成用prompt・具体情報の条件を変更していない。

関連性判定では、質問の識別子を完全な1要件として比較する。本文に新たに補うのは完全なidentityだけで、検索用に用意した数字単独/英字prefix単独のaliasをそのまま関連性の根拠にしない。例えば`ABC12`があるだけで`12`や`ABC`だけの新しい一致を発生させない。

## 検証

| ローカル診断 | 修正前 | 修正後 |
|---|---:|---:|
| 前工程の追加8件：必要ページの検索候補入り | 5/6 | 6/6 |
| 同：必要ページのlexical eligible保持 | 5/6 | 6/6 |
| 同：資料外の除外 | 1/1 | 1/1 |
| 同：曖昧質問の確認 | 1/1 | 1/1 |

想定ページ85が空白あり、質問が空白なしという前工程の残件は、ページ85を検索候補・lexical eligibleに含められた。canonical BM25 Top5の想定ページ包含は4/6→5/6であり、この段階だけで6/6とは報告しない。実Reranker後のTop5は今回未評価。

- 前工程の追加22件：必要ページ14/14・資料外/情報不足6/6・曖昧確認2/2を維持。
- 元の自然な質問：必要ページ8/8・資料外2/2を維持。
- 合成100ページ・60質問：候補入り55/55・lexical eligible43/55・資料外5/5を維持。
- この8件は今回の修正に使ったため、以後未使用holdoutではない。分母を混ぜない。
- 全てローカルSQLite BM25/Query Plan/lexical eligibility/detailの診断。実Vectorize、Reranker、Gemini、最終出典選択を含むHybrid RAG全体の精度ではない。

新規回帰6件、対象20/20、Worker全体 **777/777成功**。旧保存FTS、双方向の空白差、数字/小数/接尾字/先頭ゼロの区別、金額/単位/日付、改行非結合、検索文字列の引用、keywordのみでの取得、owner分離、chunk ID/FTS本文の維持と再Embeddingしないidempotencyを検証した。

## 検出の範囲と制約

検出対象はASCII英字prefix 2～12字、横方向の空白0～4字、最大8桁の数字と最大3個の小数点区切り、最大4字の英字接尾字。NFKC・小文字化は検索比較だけに使う。単一英字、任意のUnicode規格名や全ての型番の同一性を判断する仕組みではない。

改行をまたぐ結合、ハイフン/スラッシュの後に数字が続く形の結合は行わない。通貨・一部単位prefix、年/円/秒/温度/日付などを識別子と誤って結合しないよう除外した。記号の有無や別の型番区切りへの対応は別途評価が必要。

既存のvectorScoreによる採用条件、具体情報を本文へ結び付ける判定は変更していない。今回のlexical区別を、実モデルが常に別番号を混同しない保証とみなさない。数字・型番の回答の意味的正確性は実全経路で検証する必要がある。

旧aliasを追加した分、BM25候補や順位が変わり得る。固定セットでの悪化はないが、多分野・未見資料の品質保証ではない。実iPad・文字レイヤーのない実紙スキャンの評価も残っている。

## ファイル・運用

変更: `mcp-server/src/rag/chunking.js`、`mcp-server/src/rag/relevance.js`。

新規: `mcp-server/src/rag/identifiers.js`、`mcp-server/src/rag-identifiers.test.js`、本報告、`RAG_IDENTIFIER_SPACING_FIX_RESULTS.json`。

教材本文・質問・OCR・実行ログはprivate一時領域のみ。外部APIへの資料送信、deploy、migration、DB mutation、flag変更は行っていない。owner/scope条件・Vectorize filter・rate limitは維持。iOS製品コード未変更につき、iOS全テストは今回再実行していない。

ロールバックはquery aliasとidentifierを使ったlexical判定を戻すだけで可能。保存形式不変なのでデータの巻戻しは不要。

Projectの資料の更新: なし（既存構成内の検索不具合修正）。
