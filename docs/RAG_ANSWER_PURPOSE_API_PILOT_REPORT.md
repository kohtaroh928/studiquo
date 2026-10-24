# 回答目的v2の実Gemini少数評価とv3修正

日付: 2026-10-12。作業先: .worktrees/rag-wip / codex/rag-wip。未公開。

## 結果

合成3組×2styleを予定して6回送信。5回はHTTP200・STOPで回答完成、最後の予約条件explainはGemini HTTP503（5,422ms）で停止した。Worker側は安全な固定例外を扱いHTTP500となった。内部retry/fallback・追加API呼出は行わない。完了した比較は回路・平均値の2組。予約条件はsource_onlyだけ確認できた。503の詳細原因は未特定。

要求モデルは公開コード既定のgemini-3.5-flash、成功5件の返却modelVersionはgemini-3.6-flash。両方を記録し、要求名から実モデルを同一と推測しない。temperature/思考量を追加指定せずproduction generationConfigを維持した。通常ChatGPTで以前ユーザーが共有した中程度の思考量と同じ設定とは扱わない。

今回はローカルのproduction handleAI、同一indexed snapshotの合成検索、実GeminiのsystemInstructionで評価した。Cloudflare Workerへdeployした動作、実Workers AI/Vectorize/D1、日本語検索・OCR・実PDF・iPadの統合評価ではない。

## 生成回答の評価

Codexと独立AI Code Reviewerで固定資料・質問と照合。教師による評価ではなく、各style1回の小規模probeであり汎用精度や安定性の百分率にしない。

| 問題 | source_only | explain |
| --- | --- | --- |
| 回路 | 式・単位・条件・例外、不明な抵抗値を保持。資料外の意味を補わない | 必要な背景を説明したが、資料外の定義の前に補足表示がない。たとえだけ補足とされ、境界は一部未達 |
| 平均値 | 既知値から8 cmを計算し、たとえを追加しない。過剰な計算拒否なし | 計算、資料の実値、補足の定義・仮定のたとえ・限界を区別できた |
| 予約条件 | 平日と2人以下の二条件、土曜の例外を保持。未記載の理由を推測しない | 503で未生成、採点不可 |

回路explainには、数値計算不能の説明後に不要な代入式を付ける軽微な残件もあった。未知の抵抗値を捏造したものではない。既存W03の簡潔さ・単位付き量/数値の表記とともに継続評価する。

## v3の修正

資料外の用語定義も背景補足であると固定指示へ明記。最初の資料外の説明より前に補足表示を置き、どの段落にかかるか明確にする。たとえだけに表示することや、説明の末尾だけで資料外と断ることを避ける。source_only、根拠不足/確認必要、通常チャット、検索・出典・認証・同意・API形式は変更しない。分野固有の定義や数値はproduction指示へ追加しない。

v3の実回答は未確認。v2の結果をv3の合格と扱わない。v2プロンプト/実結果を保持し、output/rag-answer-purpose-v3へ新6組12プロンプトと手順を作成した。

## 変更ファイル

新規:

- mcp-server/scripts/rag-quality/learning-live.mjs: fixed3組、same snapshot、strict transportと安全なprivate保存。
- mcp-server/src/rag-learning-live.test.js: 7件の境界/互換テスト。
- docs/RAG_ANSWER_PURPOSE_API_PILOT_REPORT.md（本書）とRAG_ANSWER_PURPOSE_API_PILOT_RESULTS.json（本文なしmetadata）。
- output/rag-answer-purpose-v3/（合成再確認用prompt/手順）。

更新:

- mcp-server/src/rag/answer-policy.js: explainの補足表示の範囲。
- mcp-server/src/rag-answer-style.test.js: 新表示方針のproduction経路確認。
- docs/HYBRID_RAG.md: 実評価の現在地。

公開Worker/DB/Vectorize/flag/secret/iOSは変更していない。新migration/binding/製品環境設定なし。評価専用runnerはSTUDIQUO_RAG_LEARNING_REMOTE=trueで明示opt-inし、STUDIQUO_RAG_KEY_FILEで既存ローカルkey設定ファイルを参照する。任意のGEMINI_CHAT_MODELは今回未指定で、公開コード既定を使った。キー自体を引数や環境設定として表示しない。実資料送信、deploy、push/merge/commitなし。

## 安全性・検証

Planner、Security Reviewerの実行前レビュー、Code Reviewerの実行前/実回答/修正後レビューを実施。実Gemini最大6回、本文読取まで60秒/回、外部dispatch予算6分、送受信512KiB。固定HTTPS host/path/model/queryだけ、redirect拒否。初エラー・不完全生成・サイズ超過で完全停止。キーはheader/メモリだけで、成功応答/保存前にキー反射を拒否する。raw upstream errorは読まずcancel、数値HTTP statusだけを記録する。ログにprompt/本文/キーを出さない。

成功・失敗を含む合成回答artifactは/private/tmp/studiquo-learning-live-20261012-01/synthetic-results.json（ディレクトリ0700、ファイル0600）。この原本は上書きしない。リポジトリのRESULTS.jsonとNotionには本文や秘密を入れずmetadata/評価結果だけを記録する。

初回runnerは意味上のpattern未設定でもrequiredFacts/forbiddenClaimsが空配列によってtrueになる既存checkAnswerを利用していた。このtrueを意味上の合格と扱わず、最終runnerはN/A(null)/not_configuredへ修正。manualReviewはpendingを維持し、機械的チェックは通信/完成/出典の確認に限定する。返却call ledgerのcopy、期限の整数/range検証も追加した。

7新規テストと回答方針を含む対象25件成功。最終全Worker1,131件成功（失敗/skip 0）。構文/差分確認成功。新テストは429/500で1dispatch後停止、内部fallback/後続拒否、遅いstream、上限6回/期限、host/query/redirect、request/responseサイズ、不完全SSE、secret反射、同snapshotを確認。実LLMの耐性や説明品質はmock合格で保証しない。

既知の評価runner制約: 6分は外部通信/dispatchの期限でローカル索引・後処理の厳密な全工程deadlineではない。結果保存は最後の1回で、強制終了すれば途中結果は残らない。styleの順序は全組source_only→explain、順序効果は未評価。製品へ組み込まない小規模pilotの制約として保持する。

## 待ち時間・費用

完成5件の所要時間は約5.6〜9.9秒、平均約8.0秒。観測usage合計は入力8,736、回答1,066、思考4,962、総14,764token。失敗503のusageは未取得。無料/有料tier、確定請求額は未確認なので、総費用を計算済みとはしない。

## 次の確認・停止

v3の回路explainで定義を含む補足表示が成立するか、予約explainの未生成分、単位/不要な代入、他の3組（不明指数・料金条件・根拠不足）を少数のAPI比較で確認する。その後、未使用問題・複数回・実Cloudflare検索/実iPadへ広げる。サービス障害をprompt不良や検索品質の低下と混同しない。

評価runner停止はopt-inを付けず実行しない。製品ロールバック不要。v3固定指示だけをv2へ戻せるが、同意/資格/失効/削除基盤へ変更を戻さない。両RAG feature flagはfalseのまま。

Project資料の更新が必要: HYBRID_RAG.md。複製は未変更。

公式APIのrole/stream/usage仕様: https://ai.google.dev/api/generate-content 。今回の品質評価は実artifactに基づく。
