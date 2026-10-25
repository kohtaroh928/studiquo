# RAG登録状況・反映待ちへの対応

2026-10-09 / `codex/rag-wip`。作業先は `.worktrees/rag-wip`。

## 目的と受け入れ条件

本文の登録完了とVectorize検索への反映完了を区別する。Vectorizeの非同期upsertと取得・検索APIは[Cloudflare公式資料](https://developers.cloudflare.com/vectorize/reference/client-api/)を確認した。送信中は登録中、送信後は反映待ち、検索結果を確認した場合だけ検索可能と表示する。通信失敗は利用者へ表示し、再確認で本文を再送信しない。旧サーバーや不明な応答から検索可能を推測しない。他ユーザーの資料、削除済み資料、変更途中の資料を検索可能と判定しない。

外部公開APIへの追加に相当するため、Highとして詳細工程、独立Planner、安全確認、独立セキュリティ・コードレビューを実施した。公開・デプロイ・migration適用・本番有効化は行っていない。

## 実装

- 新規 `mcp-server/src/rag/readiness.js`: 所有者に限定した読み取り専用の確認。
- `mcp-server/src/rag/index.js`: `GET /api/rag/sources/:sourceId/readiness` を追加。
- `studiquo/Services/RAGIndexingService.swift`: 登録状態、ページ送信進捗、送信結果のsource ID/hash、上限付き確認処理。
- `studiquo/Views/RAGControlsView.swift`: 登録中／反映待ち／検索可能／失敗の表示、手動再確認、確認停止、選択変更や画面離脱による取消。
- `studiquo/Localizable.xcstrings`: 日本語・英語の追加表示。
- 新規 `mcp-server/src/rag-readiness.test.js`、既存 `studiquoTests/RAGClientTests.swift`、`studiquoUITests/RAGCitationNavigationTests.swift`: 回帰検証。
- `docs/HYBRID_RAG.md`: APIと運用上の制限を追記。

`AIProvider`、`AIChatStore`、`AIChatView`、検索順位・チャット生成処理、既存index/delete契約には今回変更を加えていない。

## 確認方法と安全境界

Bearer認証の既存 `realSession()` 経路から渡されるcanonical userに基づきWorkerがaccountKeyを計算する。bodyのアカウント情報や任意chunk IDを利用しない。D1は全読取をaccountKey/sourceIdで限定し、削除されたaccount/sourceを除外する。

登録完了・lease・現在のchunkを確認し、最大1,000chunkについて20件ずつVectorizeから取得する。ID、所有者、資料、フォルダ、ページ、1024次元の有限値を照合する。その後、既存Embeddingを使いaccountKey/sourceId/folderIdでfilterした検索を1回行う。現在のchunk集合の結果が返り、前後のD1スナップショットが一致した場合だけreadyとなる。古い世代のchunkや削除との競合は確認成功にならない。同じEmbeddingのchunkが複数あっても、特定のseed IDだけに依存しない。

**readyの意味**は全chunkのID取得と資料単位の検索成功である。全chunkがそれぞれANN検索に返ることや、すべての質問で正しい回答になることまでは保証しない。

応答は状態／理由／sourceHashだけで、本文・ベクトル・accountKey・chunk一覧を返さない。不存在と他人の資料は同じmissing応答。既存JSONのno-storeを使用し、例外詳細を返さない。追加の本文ログ・AI呼出・資格情報保存はない。

既存 `RATE_LIMIT_RAG_INDEX`（30回/分）を登録処理と共有する。1確認は最大50回のID取得と1回の検索で、1,000chunk超は確認上限として終了する。分割確認の拡張は未実装であり、大規模資料について「検索可能」を推測しない。

## UI・互換性

確認は10秒間隔、最大18回。各HTTP確認のtimeoutは20秒。回数上限後も反映待ちとして残り、手動再確認が可能。確認停止でも本文の再送信やEmbeddingの再生成はしない。429/503は回数内で待機、ネットワーク失敗は失敗表示。旧サーバーの404、未知／不正な応答、異なるsourceHash、hashのないreadyは検索可能としない。

通信の前後にアカウント、同意、取消、対象sourceの適格性を確認する。画面の操作IDで遅延応答による別資料の表示上書きを抑止する。保護／削除・source ID変更を検出したら確認を停止する。OCR・数式の要確認通知は検索状態と分けて保持する。

初期状態は未確認であり、端末再起動後などに古いreadyを永続化して表示しない。再確認ボタンを利用する。未登録／本文なし／RAG無効／確認上限もそれぞれ説明する。反映待ち中は取得できた一部の資料や通常AI回答になる可能性があり、既存のチャット側のretrieval status／出典表示で確認する。

## 検証

- Worker対象テスト14件成功。100ページ相当を5ページずつ登録し、ID取得未反映→検索未反映→ready、所有者分離、metadata不一致、登録未完了、削除／account削除／編集／移動との競合、rate limit、無効化、空本文、確認上限、例外の秘匿を確認。
- Worker全テスト799件成功、失敗・skip 0。
- iPadシミュレーターでアプリ・テストをビルド。最終RAGClientTests **27/27成功**、関連OCR抽出 **10/10成功**、管理画面UI **1/1成功**。合計38件（対象ごとの最終成功結果）。100ページ送信進捗・通信中取消の追加後、client対象を再実行して成功した。
- 100ページPDFはテスト内で生成したPDFを既存PDFImportServiceで抽出し、20回の送信とページ番号・sourceHash・進捗を確認。実Cloudflareへの100ページ負荷試験ではない。
- 独立レビューの取消後の表示残存指摘を修正し、再レビューは指摘なし。実際の通信中取消を画面操作するUI試験・実iPadは未実施。クライアント通信中の取消／遅延応答はユニットテストで検証する。
- ソース構文・文字列カタログJSON・差分空白を確認。XcodeGenで作成したignoredのローカルプロジェクトはCapabilitiesを補修・確認し、正本のproject.ymlとentitlementsは変更しない。

## 未実施・残る作業

iOS全ユニット／全UI suiteは今回再実行せず、変更に関連する対象を検証した。

新APIをデプロイしたstagingでの実測、代表的100ページ資料での待ち時間／利用量、全chunkの検索可視性、1,000chunk超の分割確認、通信中の実画面操作、実iPadは未検証。今回外部AIへユーザー資料を送信していない。以前測定した約87秒の遅延が今回のコードで短縮したという主張はしない。

新APIの公開はWorkerを先に更新する順序が推奨。新アプリ＋旧Workerでも待ち表示に留まり、通常チャットは維持する。migration／binding／secret追加は不要で、既存0007とRAGのbindingが前提。RAG_ENABLEDはstaging・productionともfalseのまま。ロールバックは新GETとUI確認処理のコードを戻すだけで、保存データの変更・削除を伴わない。

プライバシーの送信先・保持対象・本文登録同意に変更はない。確認でCloudflareのD1/Vectorizeを読むため利用量は増えるが、追加Embedding/Reranking/Gemini処理は発生しない。

Projectの資料の更新が必要: [設計] `HYBRID_RAG.md`（複製を差し替え）。置き場のファイル・Projectへのアップロードは行っていない。

## stagingでの追加検証（2026-10-09）

上記は初回のローカル実装記録。後続のユーザー承認によりstagingへデプロイし、合成100ページ資料で実環境を検証した。Vectorize getByIdsの実環境の上限は20 IDであり、100 IDの取得は40007エラーになった。共通の取得処理を20件ずつへ修正し、登録確認・hash再利用・folder移動に適用した。所有者に限定したIDの取得条件は維持した。対象15件、Worker全800件が成功し、独立再レビューで指摘なし。実測と残る制約は [100ページstaging検証](RAG_100_PAGE_STAGING_REPORT.md)を参照。最大1,000chunkの確認には50回のID取得に加えてD1や検索も必要となるため、Workerのsubrequest上限・契約プラン・応答時間を別途評価する。

後続のローカル修正（まだstaging未配信）: [出典選択・検索障害分離・代表ページprobe](RAG_CITATION_STABILITY_FIX_REPORT.md)。従来の実測値はこの報告の時点のコードに対する結果として保持する。
