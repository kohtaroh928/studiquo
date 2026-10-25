# 片側仕様の比較表現修正と評価基準の版管理

2026-10-13。既存の作業ブランチで固定policyと評価metadataのみ変更した。本番反映・push・merge・commitなし。

## 変更と検証

partialでは片側仕様を対象名付きの「確認できる情報」として説明し、両側の同じ項目を確認したときだけ差分・共通点を述べる。限定的な比較まで禁止しない。

新rubric `2026-10-13-v2` を導入。資料に明示された式・単位の直接言い換えには補足表示を必須とせず、一般知識の性質・用途・たとえ・選択助言には先に補足表示を求める。旧fixtureは変更せず、今後の結果に旧・新基準と版を記録する。過去結果は再採点しない。基準はLLM入力に混ぜない。

対象40件、全Worker1,221件成功。失敗・skip0。独立レビューと独立対象40件も成功、High/Mediumなし。production経路で両styleへのpolicy到達、旧基準保持、採点条件の入力非混入を確認。iOS未変更・今回再実行なし。今回の追加文だけを戻せるprivateバックアップを保持。

## 実Luna確認

固定合成3問（部分比較・密度・別段落の搬送条件）×両style、計6送信。今回はsource_onlyを先に実行した。6HTTP200/completed、各対でinput/reference/config/citationが一致。意味の自動判定は未設定であり、通信チェックを品質合格扱いしない。

Codexと独立AIが今回の対象項目を確認した。部分比較2回答とも片側の仕様を両者の違いと呼ばず、未知仕様・優劣・選択の捏造なし。explainの一般助言には先に補足表示。密度2回答は2g/cm³と式・単位を保持し、直接言い換えを不必要に拒否しない。搬送2回答は15m・全記号単位・同向一定条件・変速例外を保持。

密度の「1cm³あたり2g」は全体比の単位の読み方として扱った。任意の局所領域の均質性・科学的厳密性まで評価したとはしない。教師reviewは未実施。少数の調整用問題を各1回試した結果であり、汎用精度・長期安定性・全品質合格は主張しない。

production handleAIとlocal synthetic retrievalを経由した実OpenAI評価。実Cloudflare検索・実PDF・OCR・iPadを確認したものではない。固定合成probeのみmoderation省略、本番処理は変更なし。入力19,389/出力2,058（思考1,058含む）/合計21,447tokens。上流応答4.243〜4.935秒、平均4.469秒。API課金あり、実請求額は未確認。

生の合成回答はprivate0700/0600、repo/Notionは本文・秘密なしmetadataと所見のみ。検索・認証・課金・同意・DB・feature flag・iOS・公開API形式は今回変更していない。

## ファイルと次の作業

変更: `mcp-server/src/rag/answer-policy.js`、`src/rag-answer-style.test.js`、`scripts/rag-quality/learning-openai-live.mjs`。

新規: `scripts/rag-quality/learning-rubric.mjs`、`src/rag-learning-rubric.test.js`、本報告、`RAG_COMPARISON_LABEL_RESULTS.json`、`RAG_EVALUATION_RUBRIC_V2.md`。

次は[50問の構成案と採点基準](RAG_EVALUATION_RUBRIC_V2.md)に沿って、未使用問題・根拠・正解・採点票を固定する。50質問を両styleで試すなら100回答。現runnerの最大6送信は維持し、50問catalog・全体予算制御・再開/重複防止を準備してから実行する。50問は未作成・未実行。実検索/PDF/iPad・他モデルは別工程として残る。

Projectの資料の更新: なし。
