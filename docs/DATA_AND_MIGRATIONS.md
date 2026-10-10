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
