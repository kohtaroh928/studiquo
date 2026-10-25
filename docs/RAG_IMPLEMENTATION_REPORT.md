# Hybrid RAG 実装・検証報告

Productionの有効化前にレビューするための変更です。`RAG_ENABLED=false`を維持し、当初の実装検証ではremote操作を行っていません。2026-10-08に追加依頼によりstagingへ0006を適用しました。production migration、resource作成、deploy、pushは実施していません。作業開始時の未コミット変更は保持しています。

## ファイル

今回の実装・既存テスト検証で変更した既存ファイル（開始時からのユーザー差分は保持）:

- `mcp-server/src/ai.js`: 独立Retrieval呼出しと構造化citation SSE。
- `mcp-server/src/app.js`: canonical session下のRAGルート、専用同意の確認。
- `mcp-server/src/account-deletion.js`: aliasを含むRAG消去、削除完了時刻。
- `mcp-server/src/account-deletion.test.js`: 完了時刻を含む状態の検証。
- `mcp-server/src/privacy-retention.test.js`: 実SQLiteテストbindingにD1 batch transactionを追加。既存の未コミットテスト追加は保持。
- `mcp-server/src/legal.js`: RAGの保存・外部AI処理・消去を公開ポリシーへ追加。
- `mcp-server/wrangler.jsonc`: production/stagingのAI/Vectorize/rate limit/feature flag。
- `studiquo/Localizable.xcstrings`: RAGのscope・出典・送信許可・状態表示の英訳を追加。既存のユーザー翻訳は保持。
- `studiquo/Models/Notebook.swift`, `Folder.swift`: 永続source/folder識別子とNotebookのsource世代。
- `studiquo/Models/CalendarEvent.swift`: AIメッセージに出典を保存。
- `studiquo/Services/AIProvider.swift`: 後方互換のRAG overload、citationイベント読取。
- `studiquo/Services/AIChatStore.swift`: scope/出典の最小受渡し。
- `studiquo/Services/HandwritingRecognitionService.swift`: 既存Vision認識の画像入口を再利用。
- `studiquo/Views/AIChatView.swift`: RAG設定と出典表示。
- `studiquo/Views/ContentView.swift`: 出典によるNotebook選択、lock/delete cleanup、プライバシー説明。全UI検証で見つかったSettingsのAI説明を閉じられない問題も修正。
- `studiquo/Views/NoteEditorView.swift`: 対象paneのページ遷移、構造変更時の古い出典拒否。
- `studiquo/Services/AuthenticationStore.swift`, `UsageEventService.swift`, `ErrorReportService.swift`: 全テスト検証で露呈したテスト専用sessionの注入口を追加。通常は既存shared sessionを使用。
- `studiquoTests/AuthenticationStoreTests.swift`, `UsageEventServiceTests.swift`, `ErrorReportServiceTests.swift`: 専用ephemeral sessionへ既存stubを設定。staging接続先を引き継いでproduction限定stubが効かなかった根因に対し、接続先をテスト内で固定し終了時に元の設定を復元。既存assertionと送信host検証を維持し実通信を防止。
- `studiquoUITests/SettingsFormSharedTests.swift`: sheet内の実toggleに操作を限定し、背景の同名toggleへの誤操作を防止。
- `studiquoUITests/LibraryDropInteractionTests.swift`: split pickerの実際の行を選択し、画面向き・外観のテスト間漏れとスクリーンショット座標を修正。columnの短距離dragはcontext menuが成立する前のgestureで開始。既存のdrop・表示検証を維持。
- `studiquoUITests/HomeMultiSelectUITests.swift`: iPadのoverflow menuにある選択操作を実際のUIから解決。既存の選択件数・操作結果のassertionは維持。
- `studiquo/StudiquoApp.swift`: DEBUG専用の出典タップUIテストfixture、送信成功用チャットfixtureの条件修正。

新規ファイル:

- `mcp-server/src/rag/index.js`: 索引/status/削除API、再登録境界。
- `mcp-server/src/rag/storage.js`: hashes、batch index、外部mutation、lease/削除。
- `mcp-server/src/rag/chunking.js`: structure-aware child chunk、日本語FTS検索用正規化。
- `mcp-server/src/rag/query.js`: 条件付きrewrite/multi query、scope、RRF。
- `mcp-server/src/rag/retrieval.js`: Hybrid Top20+20 → RRF15 → Rerank5、context/citation、deadline。
- `mcp-server/migrations/0006_rag.sql`: 追加型migration。
- `mcp-server/src/rag.test.js`, `rag-integration.test.js`: SQLite FTS5/AI/vector mockと実chat接続の回帰。
- `studiquo/Services/RAGIndexingService.swift`: RAGSearchScope/RAGCitation、索引、同意、account別削除queue、出典navigation。
- `studiquo/Views/RAGControlsView.swift`: 明示的な索引更新、4種類のscope、出典リンク。
- `studiquoTests/RAGClientTests.swift`: 100ページPDF、batch、hash、lock、disabled、出典、消去。
- `studiquoUITests/RAGCitationNavigationTests.swift`: 実出典ボタンからページ遷移。
- `docs/HYBRID_RAG.md`: 設計、作成コマンド、rollout/rollback。
- この報告。

`PDFImportService`自体の既存page.string抽出は変更せず再利用します。`project.yml`は変更していません。XcodeGenで新規Swiftファイルを生成済みプロジェクトへ反映します。

## D1・Cloudflare設定

`0006_rag.sql`は`rag_sources`/`rag_chunks`/`rag_chunks_fts`と、ページhashを管理する`rag_pages`、削除境界の`rag_accounts`を作成します。FTS5のinsert/update/delete triggerを含みます。既存migrationは変更していません。

Vectorize・metadata indexの実行コマンド一式は[HYBRID_RAG.md](HYBRID_RAG.md)にあります。EmbeddingはBGE-M3、1024 dimensions、cosine。accountKey/sourceId/folderId/pageNumberのmetadata indexをupsert前に作成します。

追加bindingは`AI`、`RAG_VECTORIZE`、`RATE_LIMIT_RAG_INDEX`（30/min）、`RATE_LIMIT_RAG_SEARCH`（20/min）。D1は既存`ADMIN_DB`を使用。stagingは別Vectorize indexとrate namespaceを使用します。

環境変数は`RAG_ENABLED`（初期false）。既存`AI_PROVIDER_APPROVED`による提供条件確認gateと`GEMINI_API_KEY`は維持します。Workers AIはbindingを使うため新規secretは不要です。

## 検証

- 変更前のWorker既存605件: 全成功。
- Worker全体631件: 全成功（約70.8秒）。その後、並行する既存作業のテスト追加とGemini限定境界の回帰を含む最新working treeで651件を再実行し、全成功（約45.0秒）。RAG追加27件を含む。
- RAG・chat integration27件: 全成功。最終RAG・integration27件は独立reviewでも全成功。重大・高優先度の未解決指摘なし。不正scopeがlibraryへ広がらない境界を含む。独立reviewでは直前の25件を再実行し、遅延削除の元の再現ケースも修正を確認。
- iOS署名あり全unit1483件: 全成功（約23.6秒）。その後、既存作業の追加も含む全1502件を最終再実行し、全成功（約22.4秒）。RAG12件とCloudKit schema5件を含む。
- 出典・RAG保存データ管理の最終UI2件: 全成功。出典ボタンから対象Notebookの3ページを開く。
- 公開ポリシー・chat integration最終16件: 全成功。再保存防止用の最小削除マーカーの保持説明を含む。
- production/staging Wrangler最終dry-run: 両方成功、deployなし。
- RAG telemetryは使用有無・出典件数・所要時間のみ。質問・本文・account識別子を含めません。
- Apple Sign In/CloudKit entitlementsと生成済みprojectのSystemCapabilitiesは保持を確認。project.yml変更なし。
- 最新Cloudflare Workers型（5.20261007.1）でBGE入力/出力、reranker、Vectorize bindingを確認。
- 最初の署名なしiOS検証はKeychain entitlementエラーで失敗。署名あり再実行で解消。その後staging設定によりproduction限定network stubが効かなかった既存テストも、設定のテスト内隔離と専用sessionで解消。テスト期待値を弱める変更は行っていません。
- UI全108件を署名ありで実行（既存106件・新規2件）。初回93成功/15失敗。原因修正後、失敗した全ケースを対象に再実行して成功を確認。11-inchでAllFour/hover/HomeMove、document/slide split、StudyTime設定共有も成功。単一の最終全108件再実行ではなく、全体実行と修正箇所の対象再実行で検証。
- SettingsFormSharedTests共通helperを使用する全8件も最終再実行し、全成功。

100ページは、Workerの実SQLite FTS5+mock Workers AI/Vectorizeで10ページ×10batchとpage78の出典を検証します。iOSは生成した実100ページPDFをPDFImportServiceで取り込み、5ページ×20requestとページ本文/番号を検証します。実Cloudflare inference・本物の学習資料による品質/費用測定は別工程です。

## 指定された回帰項目の対応

| 項目 | 検証 |
| --- | --- |
| 100ページPDF / source hash idempotency | Worker実SQLiteで100ページ・再送・置換、iOS実PDFImportServiceで100ページ・20送信 |
| overlap / page boundary | structure-aware chunkの重複本文と推定500token以下、別ページ混入なし |
| user isolation / folder・notebook scope | 他userのvector IDを故意に返すmock、D1 hydration・neighbor・消去の分離 |
| Hybrid / RRF順位 / rerank fallback | Top20+20・Top15・Top5、重複順位、例外とtimeout |
| Rewrite / Multi Query | 曖昧な質問だけ履歴拡張、比較・複合だけ最大3query |
| Locked Notebook | Worker拒否、iOS保護PDFをローカルunlock後も除外 |
| prompt injection | retrieved textをJSONの非信頼参照に封じ、出典をserver結果から作成 |
| source・account deletion | D1/FTS/vector消去、他user保持、障害retry・削除中の索引競合 |
| citation page / tap | page78のWorker出典、iOS保存・検証、実UI出典からpage3へ遷移 |
| disabled互換 | Gemini requestとSSEが従来と一致、RAG binding呼出しなし、iOS送信なし |

## セキュリティ・プライバシー

- canonical identityはBearerからrealSessionで取得。bodyのaccountId/accountKeyを使用しません。
- VectorizeのaccountKey metadata filterに加え、D1でowner/scope/公開状態を再確認します。parent/neighborも同条件です。
- Notebook lockとパスワード保護PDF（lockedPDFData保持）を索引・scope・出典の対象から除外します。
- 削除・lockはremote cleanupを予約し、pending cleanupがある間のRAGは通常chatへ戻します。
- source/account削除をfeature flag無効時にも実行。D1 chunk IDを外部削除の再試行に残し、外部削除成功後に本文・FTS・vector・ページ情報を消去。source削除ではページ数・資料種別・leaseも消去し、opaque sourceIdと削除フラグのmarkerのみ残します。account削除ではsource markerも削除し、`rag_accounts`のhash accountKey/削除フラグのみ再保存防止用に残します。保持条件を公開ポリシーに明記し、本番前の契約・プライバシーレビュー対象とします。
- leaseで複数writerを制限し、期限切れ処理による上書きをSQL条件とvector世代で防止します。
- retrieved textはuntrusted資料としてGeminiへ渡します。既存の他モデル選択ではRAG retrievalを実行せず通常chatを維持します。LLMからsource IDを生成しません。prompt injectionへの絶対的な保証を意味しません。
- 本文・質問・prompt・Embedding入力をログへ出さず、実byte制限とrate limitを適用します。
- 一般AI送信許可に加え、rag-v1の明示許可を必要とします。選択資料の本文/OCR/タイトル/ページ情報とEmbeddingをCloudflareに保存し、Workers AIで処理、検索質問（曖昧な場合は直前の質問も使用）をCloudflareへ送信し、取得抜粋をGoogleへ送る説明を追加しました。
- 許可撤回は新規RAG送信を停止します。既存保存資料は専用削除操作または退会時に消去します。

## 本番有効化前

- stagingの0006適用は2026-10-08に完了。別Vectorizeとmetadata indexesの作成は未実施。
- 実Workers AIの出力・latency・費用、日本語FTS recall、OCRと代表100ページPDFの品質を測る。
- Vectorize非同期mutation/可視性、障害時retryと消去完了を実bindingで確認する。
- 実iPadでsplit表示・出典タップ・CloudKit移行/同期を確認する。
- Cloudflare/Googleの契約・年齢適合性・保持条件、公開プライバシーとApp Store privacy申告を確認する。
- 編集・folder移動後は明示的な索引更新を行う。構造が変わった過去出典は誤ったページを開かず拒否する。
- 外部mutation完了後の削除は非同期。オフラインlock/deleteでは通信回復までremote cleanupが保留される。
- 認証の秒単位時刻境界では、削除完了と同じ秒のtokenによる索引再開は拒否する。次の秒以降に再認証する。
- token数はBGEの正確なtokenizerではなく多言語の推定値。短いページ末尾chunkは目安より小さくなる。実tokenizerとの品質評価はstagingで行う。
- 問題時は`RAG_ENABLED=false`へ戻す。消去コードとschema/bindingは維持する。

## staging migration適用記録（2026-10-08）

明示的な追加依頼により`studiquo-admin-staging`（`697ba80f-9a11-4b0b-b204-687737c8c245`）へ`0006_rag.sql`のみ適用しました。未適用一覧が0006のみであることを確認し、11 commandsが成功。5テーブル（FTS含む）、2 indexes、3 triggers、migration履歴とFTS読取（0件）を確認しました。最初のAPIアクセスは7403で拒否されましたが、所有アカウントとDB IDを確認後の再試行は成功しました。productionには操作していません。`RAG_ENABLED=false`を維持します。

## Workers AI実環境検証（2026-10-08）

追加依頼により合成入力で実REST APIを22回呼び出し、全成功。1024次元と15候補→Top5の形式・関連順位を確認。query Embedding中央値233 ms、16 child Embedding中央値418 ms、15 child Rerank中央値483 ms。使用量34.70 Neurons、無料枠適用前の料金換算約$0.0003817。詳細と測定範囲は[RAG_CLOUDFLARE_AI_VALIDATION.md](RAG_CLOUDFLARE_AI_VALIDATION.md)、数値記録は[RAG_CLOUDFLARE_AI_VALIDATION.json](RAG_CLOUDFLARE_AI_VALIDATION.json)。Worker bindingを含む全体計測と請求確定額は未確認。

## 日本語検索・OCRの品質評価（2026-10-08）

合成100ページPDF（文字80/画像OCR20）と主評価60問・対照10問を評価。OCR文字誤り率0.160%。言い換えTop5正解17/20、OCR質問18/20、比較で両ページ5/10、自然な曖昧質問1/5。Rerank前より精度が下がる例と資料外質問への参照混入を確認し、本番有効化を推奨しません。詳細・実環境とローカル代替の境界・再現記録は[RAG_SEARCH_QUALITY_EVALUATION.md](RAG_SEARCH_QUALITY_EVALUATION.md)。許可された実教材での代表性評価は残っています。

## 検索品質修正の追加実装（2026-10-08）

承認済み③②①④⑤⑥を実装。Worker671、iOS全unit1521、関連UI3成功。適用済み0006は保持し追加0007を用意（remote未適用）。元55肯定問の全goldenページ取得は41→52問へ改善。同話題negativeの回答可能性判定は課題。詳細は[RAG_QUALITY_IMPLEMENTATION_REPORT.md](RAG_QUALITY_IMPLEMENTATION_REPORT.md)。RAG_ENABLED=false維持。
