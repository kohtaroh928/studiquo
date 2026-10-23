# 英字・日本語混在検索語の修正（2026-10-09）

## 修正結果

英字から日本語へ続く文字列を日本語bigramとして扱い、英字の略語を失っていたsearchTokensを修正した。合成例`ABCの概要`は、関連性判定では`abc / の概 / 概要`となる。

保存済みFTSとの互換性は検索時のaliasで維持する。matchQueryは修正後の検索語と旧形式のbigramの両方を、引用・重複除去・64語制限の下で検索する。searchTextの保存形式は旧形式をそのまま維持した。chunk分割、heading context、Embedding本文、hash、index format v2は変えない。DB migration、再索引、再Embeddingはこの変更のためには不要。

資料本文・質問はSQLへ直接連結せず、既存のbind検索を維持する。accountKey・scope条件、関連性しきい値、Vectorize filterは変更していない。

## 検証結果

| 診断 | 修正前 | 修正後 |
|---|---:|---:|
| 指定114ページ教材の自然な質問：canonical BM25 Top5に必要ページを含む | 7/8 | 8/8 |
| 同：Query Plan候補全体に必要ページを含む | 8/8 | 8/8 |
| 同：lexical eligible条件で必要ページを保持 | 7/8 | 8/8 |
| 同：資料外質問のlexical候補を除外 | 2/2 | 2/2 |
| 合成100ページ・60質問：canonical BM25 Top5の必要ページ包含 | 46/55 | 46/55 |
| 同：Query Plan候補全体の必要ページ包含 | 55/55 | 55/55 |
| 同：lexical eligible条件の必要ページ保持 | 43/55 | 43/55 |
| 同：資料外質問のlexical候補を除外 | 5/5 | 5/5 |

この診断は製品のcontextualChildren/searchText/BM25 SQL/queryPlan/eligible述語をローカルSQLiteで使ったもの。実Vectorize・Reranker・Gemini・最終出典選択を含むHybrid RAG全体の正答率ではない。vectorScoreがないlexical-only条件なので、43/55を従来の実Hybrid評価55/55の悪化と解釈しない。自然な8質問は発見に使った同じセットであり、独立holdoutではない。

- 新規回帰テスト6/6成功。
- RAG対象テスト48/48成功。
- Worker全体767/767成功。
- 最初の全体実行は移動先worktreeの依存パッケージ不足により21 test filesを読み込めなかった。固定lockfileどおりnpm ci（install scripts無効）を実施し、全体再実行で解消した。package.json/package-lock.jsonは変更していない。
- iOS製品コード未変更。iOSテストは今回再実行していない。

回帰テストはNFKC、混在英数字、日本語、Cyrillic、Greek、旧形式FTSと単独英字FTSの検索、保存語のbyte一致、queryの引用・重複除去・上限、誤った略語の除外、旧形式の既存資料のidempotency・chunk ID維持・再Embeddingなし・keywordのみでの取得・他ownerの除外を確認する。

## 制約

保存済みFTSの混在runには、依然として英字のwhole wordが保存されていない。日本語を含む質問では旧bigram aliasで互換検索するが、単独の英字だけを質問した際に旧混在runの資料へ到達しにくい従来の制約は残る。今回、その挙動を新たに広げるLatin bigram検索は加えていない。FTS保存形式を将来改善する場合は、別途索引互換性・更新・品質を評価する必要がある。

旧aliasによる候補の増加でBM25順位が変わる可能性がある。今回の固定自然質問と合成60質問では悪化なしだが、多分野・未見質問での保証ではない。実iPad、文字レイヤーのない実紙スキャン、実Cloudflareでの全経路は引き続き未評価。

## 変更と安全性

変更: `mcp-server/src/rag/chunking.js`。

新規: `mcp-server/src/rag-mixed-script.test.js`、本報告、`RAG_MIXED_SCRIPT_FIX_RESULTS.json`。

診断報告へ後続修正のリンクを追記。前段の未コミット変更は維持した。資料本文・質問・認識結果はprivate一時領域のみ。外部への資料送信、deploy、DB mutation、migration適用、flag変更は行っていない。

ロールバックはsearchTokens/matchQueryの今回の処理を旧処理へ戻すだけで可能。保存形式不変なのでデータの巻戻しは不要。

現行の[Cloudflare Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/)と[D1 SQLドキュメント](https://developers.cloudflare.com/d1/sql-api/sql-statements/)を参照し、既存bindingとbind SQLを維持する範囲で修正した。新たなAPI・binding・環境変数はない。

Projectの資料の更新: なし（既存構成内の検索不具合修正）。
