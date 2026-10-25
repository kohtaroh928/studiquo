# RAG検索品質改善の実装計画

承認済みの順序③→②→①→④→⑤→⑥で進める。目的は必要な根拠の脱落と資料不足時の誤表示を減らすこと。指定AIモデル、Vector20/BM2520/RRF15/final5、既存AI経路、accountKey境界、locked除外、ページ境界を維持する。

## 受け入れ条件と順序

1. ③ queryPlanのcanonicalQueryを意味検索・FTS・rerankerで共用。原質問は会話用に保持。
2. ② boundedな指示語検出と前の質問による主題補完。明確な主題は書換えない。履歴が不足する指示語質問はclarification状態。
3. ① 全候補をrerankし、RRF順位とrerank順位を融合。応答欠損・重複・不正・timeoutはRRF fallback。重みは合成調整用/未使用holdoutで評価し未校正事項を明記。
4. ④ 比較の主題ごとに根拠候補をRRF15とfinal5へ予約。同一ページを重複選択しない。意味だけの無関連候補をcoverage枠へ強制しない。
5. ⑤ owner確認済み候補のsemantic score、重要語の一致、ranking支持を使用する根拠判定。grounded/partial/insufficient/clarification/fallbackの追加SSEを後方互換で返す。insufficient/fallbackは通常AI応答と明示。Geminiの根拠制約も追加。
6. ⑥ 日本語bigramを維持し、質問の汎用語を整理。server導出の資料タイトル/見出しをEmbedding/FTS/rerankへ追加。index format v2とEmbedding入力hashによる安全な再索引。0006はstaging適用済みなので変更せず追加migration0007を作る。

## 安全・互換性

- body identityやvector metadataは信頼せず、既存D1 owner/scope/公開状態の再確認を維持。根拠判定・coverageもhydration済み結果のみ使用。
- 本文・質問・Embedding入力・履歴はログへ出さない。LLMによる追加Rewriteや判定呼出しは追加しない。
- SSE statusはRAG有効+専用同意のGemini requestだけ。旧iOSは未知eventを無視し、新iOSはstatusなしserverを許容。disabledは以前と同一request/SSE。
- 新schemaは追加型、旧formatの既存chunkは読取可。index v2はlease/source/page/hash全境界で区別し、タイトル変更でも必要な再Embeddingを行う。
- 失敗中のvector pending IDと消去retry、古いwriterの世代保護を維持。
- 0007はローカルで検証。remote migration/deploy/RAG有効化は今回行わない。
- rollbackはRAG_ENABLED=false。schemaは維持し、データ消去ルートを残す。

## 検証

各段階の決定的回帰、ユーザー分離・scope・削除・idempotency・旧format upgrade・disabled SSE・status互換を追加。Worker全test、iOS関連unit/UIとbuild、独立レビューを実施。既存100ページ合成fixtureと調整に使わないholdoutで実Workers AI評価を再実行し、過去結果は上書きしない。実教材/Vectorize/実iPadの限界は区別する。
