# RAG staging整備・実binding検証

2026-10-09。対象は `.worktrees/rag-wip`。ユーザーの依頼により、①staging整備、②実環境の検索から回答、③Gemini安定性と回答品質を順に検証する。

本書は修正前の不合格記録。後続の修正と実binding再検証27/27成功は [RAG_STAGING_FIX_REPORT.md](RAG_STAGING_FIX_REPORT.md) に記録する。過去の失敗は保持する。

## ① 環境整備

- 適用前の未適用migrationは0007のみ。D1 Time Travelの復旧地点を権限を限定した一時領域へ記録。
- `studiquo-admin-staging`へ`0007_rag_context.sql`を適用。8 commands成功。migration履歴と7追加列を確認。登録前のrag_sourcesは0件。
- `studiquo-rag-v1-staging`を1024 dimensions・cosineで作成。
- 初回upsert前にmetadata indexの`accountKey:string`、`sourceId:string`、`folderId:string`、`pageNumber:number`を作成し、全4件が一覧へ反映されたことを確認。
- staging dry-run成功。KV・D1・Vectorizeが専用リソースを指し、AI bindingも含まれることを確認。
- 既存staging Worker、本番Workerはデプロイせず、両方のRAG_ENABLED=falseを保持。wrangler.jsoncへの追加変更は不要だった。

migrationは追加列のみ。問題時はRAGをfalseのまま停止し、列を削除しない。DB全体のTime Travel復旧は他のstaging作業も巻き戻すため、安易に実行しない。

## 検証方法・安全確認

独立の計画・セキュリティレビューを実施。dirtyなWorker全体には未レビューの別変更もあるため公開しない。localhost限定の私有Workerで、本番RAGモジュールとstagingの実D1・Vectorize・Workers AIを利用する。セッションKVはローカルで、mintSessionとrealSessionを通す合成ユーザーだけを使用する。Geminiは既存キーを内部で読み込む。個人PDFを送信せず、原文・質問・回答・Embedding・キーをリポジトリや公開ログへ保存しない。

これは実bindingとhandlerの統合検証であり、配備済みstaging入口のログイン・app.jsの同意/承認ゲート・iPad全体の検証ではない。検証用のRAG=trueは私有ランタイムのみ。

正常系は出典だけで合格にせず、Vectorizeの一致とReranker成功を確認する。GeminiはHTTP 200だけでなくSSE完了・エラー・本文・出典を確認。合成データ削除失敗は検証失敗として扱う。

## ②・③ 結果

### ② 実bindingの統合確認：未完了・不合格

合成2ユーザー・ノート2ページで2回実行。両回とも無効Bearerの拒否、実D1への登録、1024次元Embedding、同一資料再送のEmbedding追加0を確認した。request bodyのaccountId/accountKeyを偽装しても、本番handlerは実セッションのaccountKeyを使った。

初回は実VectorizeでaccountKey filter付き検索が1件ヒットし、実Rerankerも成功。しかし「ルミナ草」への質問で、別の「ソラナ草」の2ページ目も出典候補に入った。保存chunkとページ番号は正しいが、不要な出典という検索品質の不合格である。字句一致の共有部分「草の葉は」などが候補採用を許すことをローカルでも再現した。単純な全体閾値引上げはOCR・言い換え検索を悪化させ得るため、今回その場で変更していない。

2回目は新しい合成ユーザーで再実行。最大8回・5秒間隔（API呼出時間を含む）の反映待ちでも、accountKey filter付きVectorize検索が0件だった。最後の試行のEmbeddingとRerankerは成功しているため、BM25だけの結果を実Hybrid検索の合格とはしていない。非同期反映、接続経路、入力、filterを含む原因切分けは未完了。Cloudflare側の恒久障害と断定しない。

両回とも途中停止したため、folder/notebook/current pageの実検索、差分更新、実binding経由のGemini回答3ケースは未実施。先に準備したこれらのチェックを合格には数えない。①のリソース整備完了と、②の統合検証不合格は区別する。

削除は本番deleteAccountRAGを使い、作成した合成ユーザーだけを対象とした。初回は本文行0でもVector2件が最初の約60秒の待機内に残り、追加確認で両ユーザーとも本文行・Vector0件を確認した。2回目も追加確認で両ユーザーとも本文行・Vector0件を確認した。最後に実D1のchunk・FTS・page・source件数を全0、Vectorizeの全Vector件数も0と確認した。localhost Workerを停止し、検証用秘密ファイルとローカル合成セッション状態も消去した。削除済み合成accountKeyのtombstoneは本番仕様どおり残るため、「全テーブルが空」とは主張しない。

### ③ Geminiの限定再調査：未解決

②が不合格のため、③の改善・完了までは進めていない。独立して実施可能な既知問題の再測定として、検索障害から通常チャットへ切り替える合成数学問題を3回、実Geminiで確認した。

- 通常モデル `gemini-3.5-flash` の9呼出は503が7回、429が2回で全失敗。
- 既存の代替 `gemini-3.5-flash-lite` は3回ともHTTP 200・STOPで完了。
- 180度の必要事実は3/3に含まれるが、2回目の錯角の定義は不正確。前回の用語誤り・回答省略の失敗を再測定の成功で消していない。
- 合成検索を含む通常チャット回答完了は中央値5.682秒、範囲4.304〜5.930秒。既存の通常モデル3回再試行と600/1200ms待機が時間を追加している。
- 成功応答の入力873、出力251、合計1,124 tokens。失敗呼出のusageと確定請求額は未取得。

通常モデルのquota・混雑の具体的な根本原因は未確定。API成功、必要語の出現、意味的な正確さを区別する。今回prompt・モデル・再試行方針は変更していない。

本作業で製品コード変更はなく、直前のWorker全779テスト成功を今回の実環境検証の成功率と混ぜない。私有harnessの構文検査と実行チェックを行い、両回の不合格終了コードを保持する。

結果: [RAG_STAGING_BINDING_RESULTS.json](RAG_STAGING_BINDING_RESULTS.json)、[RAG_STAGING_GEMINI_RESULTS.json](RAG_STAGING_GEMINI_RESULTS.json)。

## 公開前に残る事項

実iPad、実紙スキャン、100ページの実binding負荷、独立した未使用資料による品質評価、配備済みAPIの認証・同意・rate limit確認、確定請求額は今回の小規模疎通とは別に必要。

独立レビューで、資料DELETEに専用rate limitがない点が運用費用のLowリスクとして指摘された。ユーザー分離は維持されているが、公開前の削除エンドポイントの費用対策として別途検討する。

Projectの資料の更新が必要: 設計用 `HYBRID_RAG.md` の複製差し替え、リリース用 `00_残タスク表.md` の外部サービス整備状況と検証課題。複製の置き場は変更しない。
