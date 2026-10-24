# Studiquo Data and Migrations

最終更新: 2026-10-05  
対象: iPadアプリ、CloudKit、Cloudflare Workerの保存データと移行

## 1. この文書の使い方

「データ移行」とは、アプリを更新して保存形式が変わっても、以前の資料・設定を使えるように変換することである。新しいデータベースを作れることと、既存ユーザーのデータを安全に更新できることは別に検証する。

この文書はデータ変更時の設計・レビュー・運用の基準である。「現行」はリポジトリの実装を指し、本番適用済みを意味しない。「必須」は今後の変更で守る要件であり、既存処理のすべてが達成済みという意味ではない。

今回は文書の整備だけを行う。本番migration、データ削除、バックアップ復元、CloudKitスキーマの公開は、この文書を作成する依頼には含まれない。

- システム全体: [ARCHITECTURE.md](ARCHITECTURE.md)
- 個人情報・保持・削除の正本: [SECURITY_AND_PRIVACY.md](SECURITY_AND_PRIVACY.md)
- 現在の公開前条件: [PRIVACY_RELEASE_CHECKLIST.md](PRIVACY_RELEASE_CHECKLIST.md)
- 実装・レビューの手順: [DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md)

## 2. 保存先と正本

「正本」は、他のコピーと食い違ったときに基準にするデータを意味する。通知・キャッシュ・検索用の集計を正本にしてはならない。

| 保存先 | 現在の内容・役割 | 変更の正本 |
| --- | --- | --- |
| SwiftData | ノート、カード、文書、予定、学習記録、AI会話・復習、Folder、MCP取り込み記録 | `studiquo/StudiquoApp.swift`の`studiquoSchema`と各モデル |
| CloudKit | 同期を有効にした端末のSwiftDataをApple IDの端末間で同期 | モデル、entitlements、`project.yml` |
| Keychain | 認証情報、Worker token、ノート暗号鍵、旧direct AIキー | 各認証・暗号化サービス |
| UserDefaults | 言語、端末設定、同意バージョン、移行マーカー、未送信診断など | 各設定・サービスのキー定義 |
| 端末ファイル | 自動ノートbackup、importしたコピー、export、一時ファイル、共有Inbox | `NotebookBackupService`、`SharedInbox`、入出力サービス |
| Worker KV | セッション、identity対応、OAuth補助情報、MCP snapshot、チャットprofile、画像、削除ジョブ | 各機能ハンドラーのキー・JSON定義 |
| `ADMIN_DB` D1 | 購読状態、購入・利用イベント、問題報告、診断集約、お知らせ | `mcp-server/migrations/*.sql` |
| Durable Objects | チャット・共同編集のルーム状態、ユーザー調整、MCP inbox、利用量counter | 各DOクラスとWranglerのmigration tags |
| 外部サービス | Appleの購読、RevenueCatの顧客・entitlementなど | 外部サービス側。D1の購読状態はWebhookから作る運営用の写し |

学習資料は端末側ライブラリが基本となる。WorkerのMCP snapshotは明示的に同期したコピーであり、CloudKitや最新の端末DBを直接読んでいるわけではない。APNs通知・Slack通知は保存データの復元元ではない。

現行アプリは端末ごとの単一ライブラリであり、Studiquoログインアカウントごとの別ストアではない。Apple IDのCloudKitとStudiquoのログインidentityも別である。ログアウト・別アカウントへの切替を、データ移行やCloudKit所有者変更と同一視しない。

## 3. SwiftDataモデルと所有関係

`studiquoSchema`は現在20モデルを列挙する。スライド関連の6モデルは、リリース前に取り除いた（保管場所は[SLIDES.md](archive/SLIDES.md)）。

| データのまとまり | モデル | 変更時の重点確認 |
| --- | --- | --- |
| ノート | `Notebook`、`NotePage`、`PageElement` | ページ順、描画・画像・OCR、親子関係、暗号化、cascade削除 |
| カード | `FlashcardDeck`、`Flashcard` | 問答、復習状態、順序、Deck削除 |
| フォルダ | `Folder` | 親子階層、循環防止、アイテムとの関係、移動・ゴミ箱 |
| 予定・学習履歴 | `CalendarEvent`、`StudyActivity` | 日時、時間帯、予定の取得元 |
| AI会話・復習 | `AIChatThread`、`AIChatMessage`、`AIReviewItem` | メッセージ順、添付、生成した文書とのinverse |
| 文書 | `TextDocument`、`DocumentBlock`、`DocumentTableRow`、`DocumentTableCell`、`DocumentHeaderFooter`、`DocumentComment`、`DocumentChangeRecord`、`DocumentFootnote` | 旧本文の保持、ブロック・表・脚注・コメントの参照 |
| MCP取り込み | `MCPImportReceipt` | 受信IDと取り込み済み判定。再試行で二重作成しない |

モデル内の関係・削除規則を正本とする。画面から消えただけでは子データ・バイナリ・CloudKitの削除まで確認したことにならない。

### 3.1 ストアの開き方

- アプリは`ModelConfiguration`の標準保存先を使う。環境で変わるため、特定端末の絶対パスをコードへ固定しない。
- 新規インストールはiCloud同期OFF。設定が未保存の既存ストアには同期ONを初期選択し、その選択を保存する。
- 同期設定の変更は再起動後に反映する。同期をOFFにする操作は、iCloudデータを削除する操作ではない。
- 同期ONでCloudKit構成を開けなかった場合は、処理が失敗して戻ってからローカル構成を試す。両方失敗したらエラーと再試行を表示する。
- 永続ストアを開けないときに、空のインメモリストアを成功として表示しない。ストア削除・再インストールを自動復旧策にしない。

### 3.2 スキーマ変更の基準

現行は`Schema([...])`を使い、明示的な`VersionedSchema`／`SchemaMigrationPlan`は導入していない。したがって、すべての過去版から移行できることが保証されているわけではない。

モデル・属性・relationshipの変更はHighリスクとして扱い、次を必須とする。

1. 既存データの意味を保つ。追加属性は旧データに適用する初期値・任意値を決める。
2. renameを単純な「旧属性削除＋新属性追加」で済ませない。旧値を引き継ぐ方法を設計する。
3. 必須化、型変更、relationship変更、cascade範囲変更は、既存ストアfixtureで確認する。
4. CloudKit対応モデルでは初期値・optional・inverse・一意性制約などの互換条件を確認し、既存のCloudKit互換性テストを更新する。
5. 大きなバイナリは`externalStorage`の利用箇所を確認する。SQLite本体だけのコピーを完全backupとみなさない。
6. 必要なら旧スキーマを固定したバージョン付き移行計画を導入する。導入自体も移行テストの対象にする。

端末内の互換性テストと実機CloudKitの端末間同期は別の検証である。[CloudKit確認記録](cloudkit-verification.md)があっても、新しいモデル変更の実機確認を省略しない。

## 4. 現行の端末内データ変換

ストア形式の移行とは別に、起動後・画面表示時に旧データを変換する処理がある。

| 処理 | 旧形式→新形式 | 判定・参照 |
| --- | --- | --- |
| Folder移行 | `folderName`のパスと端末設定→Folder階層・relationship | `FolderMigrationService.swift`、`didMigrateFoldersToHierarchy` |
| 文書ブロック化 | `TextDocument.bodyData`→段落等の`DocumentBlock` | `StudyDocument.swift`の`DocumentBlockMigration`、`isMigratedToBlocks` |
| ノート一覧metadata再構築 | ノート内容→一覧表示用metadata | `ContentView.swift`、モデルの`libraryMetadataVersion` |

Folder移行は祖先パスを補完し、200件ごとに保存・実行権の譲渡を行う。旧`folderName`は保持する。文書移行は既存ブロックを上書きせず、旧`bodyData`を残す。

### 4.1 今後の移行処理に必要な性質

- **再実行可能**: 途中停止や再起動でも、同じデータが重複しない。
- **保存成功後に完了判定**: 成功していない処理のマーカーを付けない。
- **小分け処理**: 大きいライブラリでUIを長時間止めない。処理位置・失敗数を把握する。
- **元データの保持**: 新形式の検証が済むまで旧形式を消さない。ただし保持期限・機密性も考慮する。
- **ストアに対応した判定**: UserDefaultsの端末単位マーカーだけで、復元・別ストア・同期後の移行完了を決めない。

### 4.2 確認した既存の課題

Folder移行と一覧metadata再構築には`try? context.save()`があり、保存失敗後も完了マーカーを進める場合がある。Folder移行は途中保存後の再実行で既存Folderをパスごとに再利用する仕組みがなく、重複生成のリスクもある。旧フィールドを保持していることだけでは、完全な復旧・冪等性を保証しない。

これらは現状を記録した課題であり、この文書作成で修正したものではない。次に対象移行を変更するときは、保存失敗・中断・再実行・複数端末を先にテストへ追加する。

## 5. D1スキーマとmigration台帳

対象はWranglerの`ADMIN_DB` bindingで、設定上のdatabase名は`studiquo-admin`。番号順に追加されるSQLファイルを正本とする。

| 番号 | ファイル | 主な変更 |
| --- | --- | --- |
| 0001 | `0001_admin_dashboard.sql` | `revenuecat_events`、`subscribers`、`usage_events`、`users_first_seen` |
| 0002 | `0002_issue_reports_and_app_errors.sql` | `issue_reports`、`app_errors`、`app_error_users` |
| 0003 | `0003_announcements.sql` | `announcements`、`announcement_translations` |
| 0004 | `0004_announcement_push.sql` | お知らせのpush状態・cursor・集計・日時の列追加 |
| 0005 | `0005_privacy_retention.sql` | 報告の`account_key`、診断関連の`last_seen_at`、削除済み顧客hashテーブルとindex |
| 0006 | `0020_rag.sql` | RAGのaccount/source/page/chunk、FTS5と同期trigger |
| 0007 | `0021_rag_context.sql` | 構造・見出しcontext、Embedding hashと索引version |
| 0008 | `0022_rag_control.sql` | 永続同意epoch、安定document資格・generation、削除job・未確定vector書込journal。2026-10-11ローカル検証のみ、remote未適用 |

D1の主要な日時列はUnix epochの**ミリ秒**。一方、Worker tokenの発行時刻は秒、Swiftの標準Codable `Date`は別の基準である。境界で明示的に変換し、数字だけを無条件にコピーしない。

主な識別子は報告・イベントID、RevenueCatの`app_user_id`、用途別のaccount hash、診断fingerprintである。hashも個人との関連付けに使えるため匿名情報とはみなさない。旧問題報告の`reporter_key`はtoken由来で、現在の`account_key`とは意味が異なる。

### 5.1 新しいmigrationの作り方

1. 適用済みの0001〜0005を編集せず、次の番号のファイルを追加する。
2. 新旧列の意味、NULL・初期値、index、既存行の変換方法を明記する。
3. 大量のデータ変換はスキーマ追加と分ける。件数・cursor・進捗・再実行方法を持つ。
4. 移行追跡を通して適用する。同じ`ALTER TABLE ADD COLUMN`を手動で繰り返す方式にしない。
5. 旧Workerでも読める追加型変更を先行し、新Workerへ切替え、必要なbackfillを行う。旧列削除は互換期間後の別変更とする。
6. 本番適用前に差分レビュー、backup、復元方法、対象database・環境・適用済み番号を確認し、明示的な承認を得る。

### 5.2 0005の特別な注意

新Workerは追加列・テーブルを要求するため、**0005適用→Worker更新→アプリ更新**の順にする。migrationファイルが存在しても、本番へ適用済みとは限らない。

- 旧`app_error_users`の`last_seen_at`は0になる。時刻を復元できないため、保持処理の初回実行で削除対象となる。
- 旧報告の`account_key`はNULL。過去sessionから所有者を復元できないものまで本人削除できるとは説明しない。
- schema追加だけではTTLによる削除は始まらない。`PRIVACY_RETENTION_ENABLED`の有効化と監視が別途必要。
- 削除済み顧客のhash、KVの削除グループ・ジョブは再生成を防ぐための状態でもある。単なる古いデータとして一括削除しない。再登録・保持期限の方針は未確定。

## 6. KVとDurable Objectsの移行

### 6.1 KV

KVにはD1のSQL migrationは適用されない。各キーのJSON形式・用途・期限が契約になる。

例: `session:`、`identity-canonical:`、`snapshot:`、`mcp:access:`、`mcp:refresh:`、`issue-report:`、`issue-report-screenshot:`、`privacy-account-delete:`、`privacy-rc-delete:`、`privacy-deletion-group:`。

- keyを変更するときは読取互換と旧keyの掃除を設計する。prefixの変更だけで古いデータは消えない。
- JSONの新しいfieldは旧recordで存在しない前提で扱う。大きな変更には明示的なformat versionを検討する。
- snapshotは再同期できるが、削除ジョブ・OAuth状態・失効情報を同じ意味のキャッシュとして扱わない。
- sessionは90日、MCP accessは1時間、refreshは90日、問題報告のKV本文・画像は90日TTL。すべてのKV keyにTTLがあるわけではない。
- 全件走査はページングと再開位置を持つ。複数keyの更新を一つのトランザクションとみなさず、失敗・競合・読み取り遅延を考慮する。

### 6.2 Durable Objects

Wranglerには`v1-chat`〜`v5-mcp-inbox`のclass登録履歴がある。これはDOクラスの登録・変更履歴であり、D1の0001〜0005とは別物である。

- `ChatRoom`はparticipants、messages、attachments、blocks、room_state、read_positionsを保持する。旧ルームにはconstructor内で列を追加し、duplicate-columnだけを許容する。
- `DocumentRoom`はparticipants、blocks、changesを保持する。
- `MCPInbox`はitemsとconsumed_tokensを保持する。端末側receiptと合わせて重複処理を防ぐ。
- `UserRegistry`はidentity調整のDO内状態と、KV上のユーザー情報を組み合わせる。
- `RateCounter`は期限付きcounter状態を保持する。

class名・namespace・ルーム名の生成方法を変えると既存オブジェクトを参照できなくなる可能性がある。登録tagの変更と、オブジェクト内のSQL／JSON変換を区別する。変更テストでは新しい空のルームだけでなく、旧表・旧行を持つルームを起動し、再起動・再実行まで確認する。

## 7. バックアップと復元

### 7.1 現行のノートbackup

`NotebookBackupService`はノートのJSON exportと自動backupを提供する。自動backupはApplication Supportの`studiquo/AutoBackups`にノートごと最大5件を保持する。保護中ノートの平文自動backupは作成せず、保護設定時に既存backupを削除する。

このbackupはノートの描画・画像・本文等を復元するもので、全アカウントのカード、文書、認証・購読・チャットを丸ごと復元するものではない。Archiveには明示的なformat versionがないため、必須field追加・型変更時には旧JSON fixtureで読取互換を確認する。

### 7.2 運用上の必須確認

- 「同期されている」と「過去の時点へ復元できるbackupがある」を分ける。削除や不正な更新も同期され得る。
- ストアbackupは書き込み停止・整合性を確保し、SQLite補助ファイルとexternalStorageを含む範囲を決める。開いたストアの本体だけをコピーしない。
- D1、KV、DOをまとめて自動backup・復元する仕組みは、この文書で確認済みとはしない。保存先ごとに利用可能な方法・権限・復元可能期間を運用時に確認する。
- backupにも個人情報・旧認証状態がある。アクセス制限、保持期限、暗号化、削除要求の扱いを定める。
- 本番へ直接restoreせず、隔離した検証先で件数・関係・添付・閲覧権限を確認する。
- 復元後に失効tokenや削除済みアカウントを復活させない。削除履歴・ジョブと照合する。
- RPO（失ってよい直近データの時間）とRTO（復旧に使える時間）は未設定。公開前に担当者と許容値を決め、実測する。

## 8. 検証・公開・ロールバック

### 8.1 移行ごとの受け入れ条件

- 空の新規環境と、サポート対象の各旧版からの更新が成功する。
- 件数だけでなく、タイトル・本文・描画・画像・順序・親子関係・権限が維持される。
- 中断後の再開、二度目の実行、保存失敗、容量不足でも重複やデータ喪失を起こさない。
- 旧アプリ＋新Worker、新アプリ＋旧Worker、同期端末の新旧混在を確認する。
- 復元、ゴミ箱、保護ノート、CloudKit同期OFF、削除中アカウントを含める。
- 検証fixtureに実際の個人情報を使わず、検証ログへ本文・token・secretを出さない。

既存の関連テスト: `AppSchemaCloudKitCompatibilityTests`、`FolderMigrationServiceTests`、`DocumentBlockMigrationTests`、`ICloudSyncTests`、`StartupStoreLoaderTests`、`NotebookBackupServiceRoundTripTests`、`NotebookBackupServiceLockTests`、`AccountDeletionIOSTests`、Workerの`privacy-retention.test.js`・`account-deletion.test.js`・各DO関連テスト。

既存テストが通ることだけで、本番旧ストアの更新・実機同期・backup復元が成功したとはみなさない。

### 8.2 本番適用前後

1. 変更の目的、対象・対象外、旧版、migration番号、件数見積り、成功条件を記録する。
2. backupと復元検証を済ませ、停止・切戻し条件を決める。
3. 開発・検証・本番のbindingを照合する。現在KVの`preview_id`は本番namespaceと共通なので、開発名だけを根拠に安全と判断しない。
4. 検証環境で既存データ移行と新旧組合せを試し、結果を独立レビューへ渡す。
5. 承認後、依存するschema変更を先行して適用し、コード・backfill・機能有効化を計画順に行う。
6. 適用後はエラー、起動・API成功率、対象件数、未処理件数、削除ジョブ滞留を確認する。失敗を放置して次工程へ進まない。

コードを旧版へ戻すことと、データを元に戻すことは別である。追加列は通常残したまま旧コードとの互換性を確認する。古いmigrationを編集したり、表・列を削除して帳尻を合わせたりしない。

削除・上書き済みデータはコードの切戻しでは戻らない。データ復元には別の承認と、削除要求を復活させない手順が必要。旧データを保持していても、新形式で編集した内容が旧形式へ戻せるとは限らない。

## 9. 変更記録テンプレート

データを変更するPR・作業記録には次を埋める。未確認項目は「なし」ではなく「未確認」と書く。

```markdown
目的／利用者への影響:
担当者・レビュー担当:
対象保存先・モデル・テーブル・key:
対応する旧版／新旧組合せ:
migration番号・schema／format version:
旧データの件数・変換規則・保持期限:
初期値・NULL・index・権限・削除規則:
途中失敗・再実行・競合への対応:
backup場所・復元試験・RPO／RTO:
検証fixture・実行結果・未実施項目:
適用順序・承認者・適用日時:
停止条件・ロールバック／前進修正:
公開後の監視・旧形式を廃止する条件:
```

## 10. 未整備事項

1. SwiftDataの明示的なschema versionと、サポート対象旧版ごとのストアfixture。
2. Folder等の保存成功と完了判定の整合、途中移行の再実行・重複防止。
3. JSON backup・KV payloadのformat version台帳。
4. D1／KV／DOの環境分離、backup・復元手順と定期復元訓練、RPO／RTO。
5. 共同編集、期限切れsession由来の旧報告、退会後の再登録世代、削除履歴の保持期限。
6. CloudKit Productionスキーマ変更の運用記録と、新旧実機の同期確認。

未整備事項を、実装済み・公開済みとして扱わない。対応時は関連テストとこの文書を同じ変更で更新する。

## RAG自動索引の安全基盤（2026-10-11）

0008は0006/0007の後に追加する。既存migrationの書き換えは行わない。適用前の旧資料は旧経路で扱えるが、管理APIは503で閉じる。一部管理tableだけ欠ける場合は未管理へ降格せず閉じる。remote適用、Worker更新、iPad更新は別工程。

`rag_controls`の存在するaccountは永続的にmanagedとなり、旧manual uploadへ戻らない。epoch/generationの期待値を条件に更新し、世代ごとにWorkerがsource IDを発行する。物理source IDと端末の安定document IDは異なる。iPad側は対応表を保持して出典を開く必要がある。hashは同一性、generationは更新順序を表す。

削除は資格失効→Vectorize削除受付→chunks/FTS/pagesの順。外部upsert前にIDとwriter leaseをjournalへ記録する。強制終了で`settled=0`が残ればjournalを自動破棄せず、削除再試行とaccount削除待ちを継続する。運用解消・監視と実Vectorize mutation順序の確認は有効化前の必須残件。

rollbackでは0008を残し、資格guardを持つWorkerへ戻す。管理導入前の任意の旧Workerやtable削除へのrollbackは禁止。`RAG_AUTO_INDEX_ENABLED=false`は新しい同意付与・登録受付を止めるが、資格失効・削除・定期cleanupを止めない。

## iPad自動索引の保存形式（未公開）

Notebookにdefault空文字のragDocumentIDを追加し、既存資料は使用前にUUIDを割り当てModelContext.saveする。従来ragIDの削除時ローテーションから独立する。CloudKit Production schema更新と旧永続storeの実機移行は未検証で、有効化前に必要。

UserDefaultsのragManaged-<account hash + Worker endpoint hash>に同意epoch、許可範囲、資料ID、fingerprint/hash、sourceId/generation、登録cursor、資格失効待ち、検索反映待ちと再試行deadlineを保存する。本文、OCR、画像、タイトル、tokenは保存しない。OCR結果は再開時に再抽出し同一hashだけ続きを送信する。初回managed同意は従来手動indexを失効させるため取り消しで旧方式へ戻らない。端末ストアに別account由来資料がある可能性は選択同意UIで開示する。

この工程で新しいD1 migrationは追加しない。既存0006/0007/0008を前提とする。失効pendingは再許可前に反映し、サーバーlocked/trashed/excludedを解除するには利用者の個別再許可を必要とする。rollbackはflags OFFで登録停止し、失効・削除APIを保持する。


### RAG構造metadata用追加migration（2026-10-17、未配備）

`mcp-server/migrations/0023_rag_metadata.sql`はrag_chunks.metadata_json TEXTを追加する。既存行はNULLで読み取り可能。新形式登録のみ列を必須とし、未適用DBへのlegacy入力は継続する。共通文書情報もchunk列内に保持し、既存source/account削除と共に除去する。位置情報だけの変更でも新lease chunkIDを発行、folder cloneはmetadataも複製する。source共通行へ新たな本文/metadataを残さない。remote migrationは未適用。公開順・停止・旧Workerへの切戻し条件は [RAG_STRUCTURED_INGESTION.md](RAG_STRUCTURED_INGESTION.md)。


## iPadの構造索引・出典接続（2026-10-17、ローカル実装）

原PDFのbytes hashでprepared Docling packageを検証し、新Notebookへ取り込む経路を実装。packageはNotebookのoptional属性に保持し、既存ロック暗号化に含める。編集時は失効し、manual/managed索引は現在の内容を使用する。Worker capabilityを確認し、構造batchを再分割せず送信する。出典metadataは会話保存と安全な補助表示へ接続し、source/page認可を維持する。精密bboxジャンプと原PDFの自動サーバー解析は未接続。iOS関連98成功・最終関連36成功（重複）、Worker1723成功。実機・iCloud移行・実資料精度の証明ではない。詳細: [RAG_IPAD_STRUCTURED_INTEGRATION.md](RAG_IPAD_STRUCTURED_INTEGRATION.md)。公開操作なし、自動スケジュールPAUSED。


## Doclingのprivate Container実行境界（2026-10-17、未配備）

独立services/docling-workerにprivate RPC/default flag false、単発jobの期限・取消・非本文状態・destroy後返却を実装。Container専用Python入口、ready前版/model検証、有限no-follow orphan cleanup、offline/nonroot Docker recipeとsample configを追加。既存MCP/iPadは未接続。JS28・Python関連60/既存49成功、型生成/bundleと合成2pageの実Nodefetch→Docling接続を確認（VMlifecycleはmock）。Docker不在でLinux build/実Cloudflare起動・隔離・停止は未検証。原PDF別同意/認可/admission・削除/予算・運用監視と依存監査を満たす前に有効化しない。DO stateはopaque ID/status/deadline/cleanup回数のみで本文なし、tombstone retentionは未設計。storage障害でpoison/alarm保存できない場合は運用停止確認が必要。詳細 [RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md](RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md)。公開操作・追加購入なし、自動スケジュールPAUSED。

## 原PDF同意の永続状態（2026-10-18、未適用）

追加migration `0024_rag_raw_pdf_consent.sql`はrawPDF専用の同意epoch/enabled、親RAG同意epoch、同意版のみを保存する。既存ユーザーの同意backfillや本文/PDF保存はしない。RAG同意変更/削除とaccount tombstoneのtriggerで原子的に失効し、削除途中失敗からaccount再開しても旧同意を復活させない。世代は単調増加、safe integer上限到達は再許可不可（失効は維持）。migration0006〜0009後の追加ファイルとしてローカルSQLiteで検証し、remoteには未適用。guardは未接続で、既存Workerのschema要件を変更しない。適用後は表/trigger/失効epochを削除するrollbackを行わない。詳細: [原PDF自動解析設計](RAG_DOCLING_AUTOMATIC_PROCESSING_DESIGN.md)。

## 新規原PDF intake（2026-10-18、0011未適用）

`0025_rag_pdf_intakes.sql`は解析前の受付をtext用rag_documentsから分離する。owner/documentごとに現在行と単調増加generationを残し、server UUID、request ID、rawPDF SHA256/長さ、両同意epoch、10分のserver期限、pending/cancelledだけを保持。本文・PDF・タイトルは保存しない。取消/同意失効/既存文書登録・変更・削除/account削除はtriggerでpendingを取り消しdigest/長さをNULL化する。期限切れは認可時に拒否し、時刻到達での物理削除/消去はまだない。

再送は元の期待世代・current request・metadata・両同意epoch一致の場合だけ同じID/期限を返す。旧世代の予約は上書き後に再送不可。全request履歴や過去request IDの永久重複禁止は保証せず、世代tombstoneを削除して再利用させない。retention・受付数制限はadmissionとともに公開前に整備する。既存rag_documentsのあるIDは新規intake不可。0010/0011はローカルSQLite検証のみ、remote未適用。rollback時も追加表/triggerをdropせず未接続を維持。

## PDF job admission（2026-10-18、0012未適用）

`0026_rag_pdf_jobs.sql`にowner/intake一意のjob、文書世代/両epoch、状態、execution token hash、不可逆dispatch印、UTC日窓、予約/精算units、memory weight、policy版、期限を追加。本文/原PDF/digest/タイトル/生tokenは保存しない。intake失効/差替え/削除triggerでstop_requestedへ進め、停止未確認のactive枠は解放しない。reserved→receivingのclaim勝者だけがtokenを得て、同tokenでdispatchは一度だけ。期限を延長する再予約やtoken再発行はない。

信頼済みserver policyは必須、job作成時のunits/weight/窓を保存する。単位はDocling受付のshadow budgetで実請求/既存AI creditsではない。未dispatchは停止確認後0、dispatch済みは予約全unitsを保守的に消費。未claimだけはstop後token不要で閉じられ、claim済みはtrusted executor token/停止確認で精算、再精算は冪等。物理削除・保持期限・停止不明時の手動復旧は未実装で、台帳dropによるrollbackは禁止。remote適用なし。

2026-10-18 内部orchestratorとbounded intake登録を追加。新migration追加なし。intakeのowner/global総行数・pending数を条件付きSQLで制限し、jobはreader/検証/consumerの実終了を確認してから精算する。新しい結果保存tableやpublic routeはなく、非公開consumerからの正式採用/retentionは別実装。実D1/remote適用は未実施。詳細: [内部接続記録](RAG_PDF_ORCHESTRATION_REPORT.md)。

## PDF停止再試行台帳（2026-10-18、0013未適用）

`0027_rag_pdf_job_recovery.sql`はjob IDだけを参照し、attempt数、次試行時刻、CAS lease、固定outcome/状態、remote停止確認時刻を保存する。owner/digest/本文/tokenは追加保存しない。最大3回、固定backoff、各DB段階と停止RPC候補は最大10件、pass最大10秒。未claimのstop_requestedだけ0精算し、claimedはremote停止確認後もmemory/unitsを保持。元executor精算後にdoneへ整理する。table/job/intakeを物理削除するretentionは未実装。

内部reaper/集計のみで公開route/schedulerへ未接続。旧Worker動作は変更せず、利用時に0012→0013が必要。migration0010〜0013はいずれもremote未適用。rollbackはreaper呼出しを止め、台帳を残す。詳細: [停止と復旧](RAG_PDF_RECOVERY.md)。

## 2026-10-18 実Linux・公開HTTP接続（最新）

実Linux amd64コンテナで合成2ページを解析（22.908秒）、通信遮断・UID10001・非書込コード/モデル・取消・期限切れ・SIGTERM・job削除を確認。認証済みローカルworkerd→private RPC→同Linux Docling→最終complete/精算も21.045秒で成功した。Cloudflareへの配備・remote migration・公開URL有効化は未実施で、ローカル成功をremote完了とは扱わない。

公開HTTP handlerは認証後に同意/intake/process/cancelを処理する。受信前認可・予約、転送中の再認可、停止精算後のcompleteを維持。早すぎるResponse返却によるworkerdの入力破棄、isolated Pythonの兄弟import、WranglerのCASE分割を実環境で修正。受付/cleanup/private実行flagsはfalse。本番private bindingなし。staging設定とdry-runを準備済み。

検証: サーバー全1,851件、processor61件、provision6件、HTTP/app/process42件成功。Python102依存のauditは既知脆弱性0・skip0（OS/モデルライセンスの保証ではない）。独立Code/Securityレビューの未解決所見なし。回答品質の有料評価・実資料・未使用20問は使っていない。

詳細・制約・ロールバック: [実Linuxと公開接続の検証](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)。次はstagingの既存配備/DB状態と利用条件を確認し、remote配備の承認範囲を確定してから段階適用・疎通する。iPad正式採用、claimed停止不明の復旧、retentionは残る。

## 2026-10-19 原PDF記録の保存・削除設計（未実装）

[保存期間・整理順](RAG_PDF_RETENTION_DESIGN.md)を追加。期限切れintakeは永続取消/詳細削減、停止不明jobは保持、精算済み詳細は暫定48時間＋過去UTC窓＋参照なしでのみ整理候補とする。世代/失効fenceと現DO spent markerは単純削除しない。settled_at/単調会計floor/原子的削除/旧writer互換が追加実装の前提。account削除callerのPDF停止pending接続、将来receiptと期限付きv2 RPC/DO purgeは残る。これは稼働中の保持保証ではなく設計で、実データ削除・設定変更は行っていない。

## 原PDF Step5-Aのローカル実装（2026-10-19）

追加0014にnullable精算時刻/control/index。旧schema停止互換、旧時刻NULL保持。内部期限整理はflag/schema gate下で最大10受付を永続取消し、PDF指紋/長さ/requestを削減、世代fenceと停止不明job/利用枠を維持する。非識別集計のみ、scheduler/公開接続なし。物理job/DO削除・account PDF pending・receiptは未完。最終server1865件＋実local D1成功、独立レビュー指摘修正済み。remote未適用。詳細: [Step5-A報告](RAG_PDF_RETENTION_IMPLEMENTATION_REPORT.md)。

## 原PDF Step5-Bの処理済み台帳整理（2026-10-19）

追加0015で初期無効の内部purgeを実装。精算から48h・過去UTC窓・永続失効/置換・既知時刻・復旧done/leaseなしだけ、粗い候補10件とcursorで有限整理。floor/child/parent/leaseは原子的rollback、writer fenceは停止後も維持。legacy/停止不明/registry参照は保持、将来採用migrationはpre-adoption契約を先に変更して旧purgeを閉じる。server1888件と実local D1同時pass/rollback検証成功。remote未適用、HTTP/cron/flag未有効化。詳細: [Step5-B報告](RAG_PDF_PURGE_IMPLEMENTATION_REPORT.md)。


<!-- Historical dae6129 checkpoint; JS references are historical. -->


## Step6-A停止証拠基盤（2026-10-19）

追加0016はstop-proof-v1のclaimに結び付く最小停止証拠tableを追加する。既存jobはlegacyのまま。証拠の巻戻し/削除を拒否し、0015の既知table契約によるpurgeは意図的に閉じる。証拠child/親の原子的整理契約を追加するまで旧purgeを再開しない。remote未適用。

詳細: [停止証拠の設計](RAG_PDF_STOP_EVIDENCE_DESIGN.md)。


## Step6-B停止証拠の実処理接続（2026-10-19）

追加0017で証拠tableを既存全列のまま再構築し、job親へのFK ON DELETE CASCADEを追加。既存jobは変更しない。purge契約をpre-adoption-stop-v2へ更新して以前のenabledを0へ戻し、writer fence/floorを維持する。親の条件確認→recovery削除→親と証拠cascade→context解除を同取引で実施、単独証拠削除は親不在条件で拒否。全1923件と実local D1成功。remote適用/backup/配備承認は未実施。

詳細: [Step6-B報告](RAG_PDF_STOP_INTEGRATION_REPORT.md)。


## Step5-Cアカウント削除とPDF後片付け（2026-10-20）

Step5-Cは既存KVのaccount削除checkpointへversion付きPDF phaseと独立phase完了状態を追加。独立消去後はstatus/identityKeys/pdfCleanup/independentCleanupCompleteへ縮小し、PDF完了までprivacy jobを保持する。旧deleted記録もPDF-only確認し、RAG未利用旧accountには拒否行だけを確立する。新migrationなし、PDF job/証拠/floor等のmetadataは保持。

詳細: [Step5-C報告](RAG_PDF_ACCOUNT_CLEANUP_REPORT.md)。


## Step5-D1 private v2期限境界（2026-10-20）

private DOのv2 stateへrpcVersion/notAfterを追加する未接続部品を実装。既存legacy stateへ期限を補完せず保持。DOにPDF/digestを保存せず、物理purgeなし。次D2aでMCPがdispatch前にimmutable envelopeを永続化する追加契約が必要。新DB migration/配備は今回なし。

詳細: [D1結果](RAG_DO_V2_BOUNDARY_REPORT.md)。


## Step5-D2a v2接続（2026-10-20）

0032_rag_pdf_rpc_v2.sqlを追加（remote未適用）。既存jobはrpc_version=1・追加値NULLのまま。v2の単一dispatch CASでrpc_version=2/rpc_pdf_sha256/rpc_not_after=deadlineを保存し、triggerで不正な初期設定・改変・NULL化・期限延長・downgradeを拒否。追加tableなし、0015/17の親purge・FK cascade・floor契約は維持。digestは取消時に消えるintakeの値と別で、停止不明/未精算とpurge未接続中は残り、既存の精算済親jobの整理時に一緒に削除する。匿名情報ではない。新migrationを削除するrollbackはせず、新規受付OFF＋v2停止コード/schemaを維持する。

詳細: [接続検証](RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。


## D2b-A：停止観測と削除前提（2026-10-20）

private DO v2 stateへdestroyConfirmedAt（最初のdestroy解決を保存した時刻）を追加。D1追加migrationなし。観測は過去の履歴であり、現在VM/全task停止や削除許可ではない。保存等の失敗はack拒否/poison保持。旧state/期限後空DOに補完しない。全消去後clock後退を空DOだけでは検知できないため外部fence等を別設計とし、物理purge/marker縮約/retention alarm未実装。


## D2b-B：再実行防止の設計（2026-10-20）

D2b-Bは設計のみ。既存jobへ独立start_protocolとnullableな消費metadataを追加する案を第一候補とした。旧rowを未実行とbackfillせず、新dispatch契約と一回限りstart CASを区別。RPC v2/stop-proof-v1の制約は流用しない。追加migration・親purge/floor契約の評価は次C1、今回DDL/DB変更なし。 [設計正本](RAG_DO_REPLAY_FENCE_DESIGN.md)。


## D2b-C1：開始許可のDB部品（2026-10-20）

0033_rag_pdf_start_gate.sql追加（remote未適用）。jobsへ独立start_protocol/start_claim_id/start_claimed_at、既存行legacy/NULL。新専用dispatch CASのみprotocol設定、初回grantだけ消費、reset/変更/REPLACEを拒否。新protocol親DELETE保留、eligible viewをlegacyに限定しmixedcursor前進を維持。既存0014〜18を編集せず、新tableなし。新start metadataは有限削除未対応で保持が続く。 [検証と制約](RAG_PDF_START_GATE_REPORT.md)。


## PDF処理のTS移植（2026-10-21）

`codex/rag-start-ts`で未統合の停止証拠/v2 RPC/開始許可をTSへ移植。最新アカウント削除のgeneration/alias保護とhashed完了markerを維持し、legacy deletedの自動再開は保留する。guard待機後・nested recoveryでも所有確認と外側期限を維持し、timer発火後の新しい開始CASをclosedで拒否する。詳しくは[RAG_TS_PDF_PORT_REPORT](RAG_TS_PDF_PORT_REPORT.md)。開始gateのprivate接続C2とremote migration/番号衝突照合は未完、実config未変更。

## RAGのmigration番号の付け替え(2026-10-24)

main側の `0006_legacy_standard_accounts`・`0007_moderation`・`0008_subscriber_transaction` と、RAG側の `0006_rag`・`0007_rag_context`・`0008_rag_control` が同じ番号を使っていた。mainの3件は本番に適用済みで名前を変えられないため、**RAG側の14件を、順序を保ったまま 0020〜0033 に付け替えた**。内容は変えていない(ファイル名だけ)。以降の新しい番号は 0034 から。

| 旧い名前 | 新しい名前 |
|---|---|
| `0006_rag.sql` | `0020_rag.sql` |
| `0007_rag_context.sql` | `0021_rag_context.sql` |
| `0008_rag_control.sql` | `0022_rag_control.sql` |
| `0009_rag_metadata.sql` | `0023_rag_metadata.sql` |
| `0010_rag_raw_pdf_consent.sql` | `0024_rag_raw_pdf_consent.sql` |
| `0011_rag_pdf_intakes.sql` | `0025_rag_pdf_intakes.sql` |
| `0012_rag_pdf_jobs.sql` | `0026_rag_pdf_jobs.sql` |
| `0013_rag_pdf_job_recovery.sql` | `0027_rag_pdf_job_recovery.sql` |
| `0014_rag_pdf_retention.sql` | `0028_rag_pdf_retention.sql` |
| `0015_rag_pdf_purge.sql` | `0029_rag_pdf_purge.sql` |
| `0016_rag_pdf_stop_evidence.sql` | `0030_rag_pdf_stop_evidence.sql` |
| `0017_rag_pdf_evidence_retention.sql` | `0031_rag_pdf_evidence_retention.sql` |
| `0018_rag_pdf_rpc_v2.sql` | `0032_rag_pdf_rpc_v2.sql` |
| `0019_rag_pdf_start_gate.sql` | `0033_rag_pdf_start_gate.sql` |

- **本番**: RAG側は未適用だったので、影響はない。
- **ステージング**: RAG側を旧い名前で適用済みだったため、D1の適用履歴(`d1_migrations`)の名前を、新しい名前に書き換えた(0030〜0033 に当たる旧0016〜0019は、未適用のまま)。
- 日付つきの過去の記録(`RAG_STAGING_PREFLIGHT_20261019.*`、`RAG_VERIFICATION_BASELINE_20261019.json`、各種 `*_RESULTS.json`、`docs/releases/` など)には、旧い名前が残っている。上の表で読み替える。
