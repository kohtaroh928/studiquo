# 調整用30問のproduction経路照合

2026-10-14。rag-wipのローカル検証。追加API送信0、追加API費用0。bankと元の採点結果は変更していない。

## 実施内容

`rag-answer-style.test.js`で調整用30問×source_only/explainの60通りを、実際の `handleAI` に通した。合成資料をSQLiteのRAGテーブルへ索引し、同一snapshotから検索する。質問だけでなく元の会話履歴も送る。Workers AI、Vectorize、OpenAI応答、rate counter等はモックである。実ネットワーク・実LLM回答の意味・実認証・実iPadは検証していない。

確認したのは、style間の検索後status・構造化出典・質問/履歴の一致、statusに対応した最終回答方針、本来のStudiquo基本prompt、出典の本人DB行との対応、根拠不足/指示語確認時に出典を返さないこと。style差だけで検索結果を変えない。既存のRAG無効/同意なし/障害/ヒットなしの通常チャット互換テストも通した。

最小base promptで全問題をgroundedとして実OpenAIへ送った過去評価とは異なる経路である。今回のテスト成功を回答正確性の合格率として扱わない。

## 観測と新しい残件

30問のstatusはgrounded 19、partial 2、insufficient 8、clarification 1。両styleで一致した。根拠不足8件すべてが不具合という意味ではない。

次の3件は既知の根拠を使えない候補として優先調査する。

| 問題ID | 観測 | 切り分け |
| --- | --- | --- |
| e50-versions-01 | 料金と適用日があるのにinsufficient | detailRequirementsが日付・参加費まで対象名へ含める。元ページ全文のassessReferenceもprice不足 |
| e50-pages_tables-02 | 北行き時刻・料金の表があるのにinsufficient | 対象へ出発まで含め、timeラベル/表の対応も調査が必要。元ページ全文でもtime不足 |
| e50-partial-03 | 一方の価格がなくても時間比較と既知価格は答えられるがinsufficient | 省略されたFの対象名復元、複数属性とprice要件、部分回答の扱いを調査。comparisonSubjectsを渡さない単独診断でも対象に属性が混入 |

全文による単独診断は要求解析/根拠判定を疑う材料であり、retrieval内部と完全同一の入力ではない。実CloudflareのEmbedding/Reranking品質を原因と確定しない。安全性のために対象照合を単純に緩める変更は行っていない。

指示語問題e50-context_time-01はclarification・出典なし、既知履歴を使うe50-context_time-02はgroundedだった。曖昧な締切問題e50-versions-03は根拠をLLMへ渡す経路だが、人間による意味判定待ちを維持する。

## 検証結果

対象テスト62件成功、Worker全体1,274件成功（失敗・skip 0）。差分の空白検査も成功。ログはprivate一時領域に保存した。新規30件は経路の整合性を確認するテストであり、上記3件の根拠不足判定を正しい動作として固定する期待値は追加していない。実LLM品質は未採点。

## 次の作業

1. 上記3件の要求解析・表の属性対応・複合質問の部分回答を切り分け、別対象の値を混用する負例とともに回帰テストを追加する。
2. 修正後、production全promptと最終検索後statusを使う少数の実OpenAI評価を行う。既存runnerの送信上限・予約・journalを維持し、過去grounded固定結果と分けて報告する。
3. 未使用20問、実検索、代表PDF/OCR/iPadの確認へ進む。人間の正解確認は残る。

今回の変更はテスト・採点運用・報告のみ。productionコード、設定、DB、secret、公開状態は変更なし。Projectの資料の更新: なし。

## 後続修正（2026-10-14）

上記3件の判定をローカルで修正した。料金/時刻表はgrounded、時間＋価格の不完全比較はpartialへ到達する。元の観測結果は保持する。修正の範囲、負例、独立レビューと残る実API確認は [修正報告](RAG_STRUCTURED_GATE_FIX_REPORT.md) を参照。
