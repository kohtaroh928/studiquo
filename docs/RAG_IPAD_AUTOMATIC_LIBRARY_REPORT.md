# iPadホームPDF自動索引のローカル実装報告

日付: 2026-10-11。作業先: .worktrees/rag-wip / codex/rag-wip。未公開。

## 今回の範囲

工程2の本人PDF・単一端末の自動登録とホーム資料探索を実装する。既存AIProvider → WorkerAIProvider → Cloudflare Worker → Geminiを維持。初期RAG_ENABLED / RAG_AUTO_INDEX_ENABLEDはfalseのまま。新しいD1 migration・Cloudflare作成・secret追加は今回なし。0006/0007/0008の基盤に依存する。

## 新規ファイル

- studiquo/Services/RAGControlClient.swift: 新同意、資料資格、世代prepare、batch upload、readinessの認証通信。account IDをbodyに送らない。
- studiquo/Services/RAGLibrarySyncState.swift: account/Worker接続先別の本文なし永続metadata。
- studiquo/Services/RAGLibrarySyncService.swift: 抽出・資格再検査、cursor再開、失効優先処理、検索可能判定、再試行、引用対応。
- studiquo/Views/RAGAutomaticLibraryControls.swift: 新許可UI、現在/将来資料の範囲、除外・再許可、前景同期modifier。
- studiquoTests/RAGLibrarySyncTests.swift: 合成資料とmock transportによる回帰。
- docs/RAG_IPAD_AUTOMATIC_LIBRARY_REPORT.md（本書）。

## 今回変更した既存ファイル

- Notebook.swift: ragDocumentIDのdefault空文字と使用時UUID。従来ragIDローテーションから独立。
- RAGIndexingService.swift: 再利用したテキスト/OCR抽出、各await前後guard、managed失効、引用resolve、scope.sourceIds。
- AIChatStore.swift: 新許可済みの場合のみlibrary探索、owner/endpoint切替後応答を破棄、最新資料で引用照合。
- RAGControlsView.swift: 自動許可UI、旧manual方式は未managedのみ。
- ContentView.swift: 独立同期modifier、lock/trash/deleteの同期資格停止。
- RAGCitationNavigationTests.swift: 設定の新許可と将来資料既定OFFを確認。
- mcp-server/src/rag/index.js: consent availability、owner限定資料state GET。
- mcp-server/src/rag/query.js: scope.sourceIdsを既存owner/scopeの追加AND条件としてFTS/hydrate/neighborへ適用。
- mcp-server/src/rag-safety.test.js: state GETのowner隔離とsource allowlist。
- docs/ARCHITECTURE.md / HYBRID_RAG.md / DATA_AND_MIGRATIONS.md / SECURITY_AND_PRIVACY.md: 未公開設計と制約の追記。

既存の未コミットRAG実装・他の機能の変更は保持した。上記は本工程の変更責務であり、worktreeの全差分一覧ではない。

## 100ページ検証

合成100ページPDFモデルを5ページ×20batchで送信。3batch成功後に通信失敗を挿入し、別service instanceでmetadataから再開。成功したページ一覧は1〜100で重複なし、prepare requestIdは同一。各requestは512,000bytes以下でcontrol付き。完了時のmappingはサーバー発行sourceId、本文変更後は旧出典を開けない。実PDF/OCR品質・実Cloudflare性能・費用の測定ではない。

## 安全確認とレビュー

Planner、Code Reviewer、Security Reviewerの独立確認を実施。lock/trashの別端末自動復活、通知による同期自己キャンセル、upload成功と検索反映完了の混同、反映待ち資料の誤失効、429再試行、未許可accountの前景復帰による旧方式の誤失効を検証対象とした。本文はUserDefaults queueに保存しない。検索はcurrent-home source allowlistとサーバーaccountKeyの両方で限定する。資料本文・promptはログに出さない。

初回新許可で旧手動索引を失効させる。許可撤回を永続化して先にこの端末を止め、通信後にサーバー失効と削除を再試行。OCR/upsert処理中も別control taskが資格停止を送る。既送信本文は回収できず、オフライン別端末での操作の即時反映は保証しない。

## 本番前の残件・停止手順

1. stagingの0008/Worker更新、新同意UIから実Cloudflareの一連動作を検証する（未実施）。
2. 実紙PDF、日本語/OCR/表/数式、複数資料・100ページ・編集/移動/改題の実環境評価。
3. 実iPadの同意、背景移行、中断再開、通信断、出典タップ、旧ストア移行、CloudKit Production schema確認。
4. 未確定Vectorize writer journalの監視と安全な解消手順、非同期upsert/delete順序の実環境確認。
5. 公開プライバシーポリシーとストア申告の更新、送信量・初回登録予算・性能上限の判断。
6. 多端末同期・共有ACLは対象外。1000資料超のmanifest制限、Vectorize候補をD1で絞るrecall低下を別評価。

停止は両feature flagをfalseとし、同意失効・削除・cleanupを維持する。0008削除や管理導入前Workerへの切戻しをしない。登録未反映/失敗は通常チャットへfallbackする。未確認を本番完成と扱わない。

remote migration/deploy、実資料送信、課金AI呼出、push/merge/commitは行っていない。Project資料複製も未変更。

## テスト結果

テスト専用のin-memory SwiftData storeでCloudKit automaticが有効になり、テスト終了時のstore解放が同期待ちになった。process samplingで原因を確認し、新テストはcloudKitDatabase: .noneを明示して外部同期を切り離した。再実行で解消。アプリのCloudKit構成は変更しない。

- Worker全体: 1,120/1,120成功、fail/skip 0。
- iOS全ユニット: 1,613/1,613成功、fail 0（新21件を含む）。
- 最終partition経路補強後のRAG対象再検証: 58/58成功。
- 最終UI独立実行: 許可画面/将来PDF既定OFF・状態表示・出典page3遷移の3/3成功。
- git diff --check: 成功。XcodeGen再生成後、Apple Sign In/iCloud Capabilitiesとentitlementsを確認・維持した。project.yml変更なし。

修正途中に引用callbackのSwift self明示漏れを修正。CloudKit teardown待ちを修正して再実行した。unit/UI一括実行は各case成功後のrunner終了待ちで中断し、上記の独立実行で両方の完了を確認した。UI suite全体・実機・旧永続ストアのmigration・CloudKit Production同期・実Cloudflareは未実施。

最終ログはローカル/tmp/rag-worker-all-tests.log、rag-ipad-final-unit-tests.log、rag-ipad-final-target-tests.log、rag-ipad-final-ui-tests.log。XcodeのxcresultもDerivedData/Logs/Testに保存されている。
