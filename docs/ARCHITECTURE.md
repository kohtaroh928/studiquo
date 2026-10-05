# Studiquo Architecture

最終更新: 2026-10-05

## 1. 目的

この文書は、Studiquoの現在のシステム構成、責務の境界、主要データフロー、変更時に守る設計上の制約をまとめる。
実装の詳細はコードを正本とし、この文書にはコードから読み取りにくい全体像と設計意図を残す。

対象範囲は次の2つである。

- `studiquo/`: iPad向けSwiftUIアプリ
- `mcp-server/`: Cloudflare Workers上のAPI、MCP、リアルタイム機能、運営機能

## 2. システムコンテキスト

```text
┌──────────────────────── iPad ────────────────────────┐
│ SwiftUI Views                                          │
│   ├─ SwiftData ──────────────── CloudKit               │
│   ├─ Keychain: セッション・暗号鍵・任意のAIキー       │
│   ├─ UserDefaults: UI設定・軽量な端末設定              │
│   └─ Services ─ HTTPS ─────────────────────────┐       │
└────────────────────────────────────────────────│───────┘
                                                 │
                                      ┌──────────▼──────────┐
外部MCPクライアント ─ OAuth/PKCE ───▶│ Cloudflare Worker   │
                                      │                     │
                                      │ KV / D1 / DO        │
                                      └───┬────┬────┬───────┘
                                          │    │    │
                         AI providers ◀────┘    │    └────▶ APNs
                         RevenueCat webhook ────┘
                         Resend / Slack / Cloudflare Access
```

原則として、学習コンテンツの正本はiPad側のSwiftDataにあり、CloudKitがAppleデバイス間同期を担う。
Workerは認証、AIプロキシ、友達・グループ・共同編集、MCP連携、課金状態、通知、運営情報を担当する。
MCPへ公開される学習データは、アプリが明示的にWorkerへ同期したスナップショットであり、CloudKitストアそのものではない。

## 3. リポジトリ構成

| パス | 責務 |
| --- | --- |
| `studiquo/StudiquoApp.swift` | アプリ起動、SwiftDataスキーマ、CloudKit接続、通知delegate、ルート画面 |
| `studiquo/Models/` | SwiftDataモデルと値オブジェクト |
| `studiquo/Views/` | SwiftUI画面、画面状態、ユーザー操作 |
| `studiquo/Services/` | 認証、通信、AI、課金、入出力、暗号化、通知などの非UI処理 |
| `studiquo/Ink/` | Apple Pencil対応の独自描画エンジン |
| `studiquoTests/` | iOSユニットテスト |
| `studiquoUITests/` | iOS UIテスト |
| `project.yml` | XcodeGenプロジェクト定義の正本 |
| `mcp-server/src/app.js` | WorkerのHTTPルーティングとMCPサーバー構築 |
| `mcp-server/src/worker.js` | WranglerのエントリーポイントとDurable Object export |
| `mcp-server/src/*.js` | 機能別ハンドラー、認証、永続化、外部連携 |
| `mcp-server/migrations/` | D1の追加型migration |
| `mcp-server/wrangler.jsonc` | Worker、KV、D1、Durable Objects、Rate Limit、観測設定 |

## 4. iOSアプリ

### 4.1 起動と画面遷移

1. `StudiquoApp`がRevenueCat、クラッシュ診断、CloudKitエラー監視を初期化する。
2. `StartupStoreLoader`がSwiftDataの`ModelContainer`を非同期に開く。
3. CloudKit付き構成を最初に試し、失敗した場合はローカル構成へフォールバックする。
4. 永続ストアの準備後、`AccountGateView`が認証状態に応じてログイン、メール確認、オンボーディング、`ContentView`を切り替える。
5. `StudiquoAppDelegate`がAPNs登録と通知タップのルーティングを担当する。

起動時に永続ストアを開けない場合、空のインメモリストアへ黙って切り替えず、エラー画面と再試行を表示する。

### 4.2 UIと状態管理

- SwiftUIの`@State`、`@StateObject`、`@EnvironmentObject`で画面・セッション状態を管理する。
- SwiftDataの`@Query`と`ModelContext`で学習データを読み書きする。
- `AuthenticationStore`がログイン状態、メール確認、オンボーディング、ログアウトを集約する。
- `SubscriptionStore`がRevenueCatのOfferingとEntitlementを`standard`、`plus`、`pro`へ変換する。
- `AI.provider`は既定で`WorkerAIProvider`を使い、UIテストでは差し替え可能にしている。

現在は厳密なレイヤードアーキテクチャや単一のViewModel規約ではない。
画面固有処理はViews、再利用するI/O・ポリシーはServices、永続化対象はModelsへ置くことを基本とする。

### 4.3 SwiftDataモデル

`studiquoSchema`がアプリで利用する全SwiftDataモデルを列挙する。主な集約は次のとおり。

| 集約 | 主なモデル | 所有関係 |
| --- | --- | --- |
| ノート | `Notebook`、`NotePage`、`PageElement` | Notebook削除でPage、Elementをcascade削除 |
| 暗記カード | `FlashcardDeck`、`Flashcard` | Deck削除でCardをcascade削除 |
| フォルダ | `Folder` | 子Folderはcascade、格納アイテムとの関係はnullify |
| カレンダー・学習履歴 | `CalendarEvent`、`StudyActivity` | 独立した時系列データ |
| AI会話・復習 | `AIChatThread`、`AIChatMessage`、`AIReviewItem` | Thread削除でMessageをcascade削除 |
| 文書 | `TextDocument`、`DocumentBlock`、表、コメント、脚注、変更履歴 | Documentをルートとする編集モデル |
| スライド | `SlideDeck`、`Slide`、`SlideMaster`、Layout、Placeholder、Element | Deckをルートとする編集モデル |
| MCP取り込み | `MCPImportReceipt` | Workerの受信項目を重複取り込みしないための記録 |

画像、描画、暗号化データなどの大きなバイナリは、必要に応じてSwiftDataの`externalStorage`属性を使う。
CloudKit互換性を壊しやすいため、モデル追加・必須属性・関係・削除規則の変更はHighリスク変更として扱う。

### 4.4 端末内ストレージ

| 保存先 | 内容 |
| --- | --- |
| SwiftData | ノート、カード、文書、スライド、予定、AI会話、取り込み履歴 |
| CloudKit | SwiftDataのAppleデバイス間同期。コンテナは`iCloud.com.yabuko.studiquo` |
| Keychain | Workerセッショントークン、ノート暗号鍵、任意の直接接続AIキー |
| UserDefaults / AppStorage | 言語、プロフィール、UI設定、Worker endpointなどの軽量設定 |
| 一時ファイル | PDF、DOCX、PPTX、共有・プレビュー用の生成物 |

ノート暗号鍵はiCloud Keychain同期を利用する。Workerの認証トークンと任意の直接接続AIキーは端末Keychainへ保存する。

## 5. Cloudflare Worker

### 5.1 リクエスト処理

Wranglerは`src/worker.js`を読み込み、実処理を`src/app.js`へ委譲する。
`app.js`は次の順序で要求を処理する。

1. ヘルスチェック、Cloudflare Access対象の運営API、OAuth metadataなどの公開・管理経路。
2. 法務ページ、招待ページ、Passkey、チャット、報告、お知らせなどの機能別ハンドラー。
3. `/mcp`のMCP transport。
4. `/api/auth/*`の未認証ログイン経路。
5. その他の`/api/*`でBearer token、期限、実在セッション、失効状態を検証。
6. MCP同期、AI、共同編集などの認証済み機能へ配送。

HTTP本文にはサイズ上限を設け、入力スキーマ、認可、Rate Limitを各境界で確認する。

### 5.2 Workerの永続化

| ストレージ | 主な用途 |
| --- | --- |
| `STUDIQUO_DATA` KV | セッション、失効情報、ID対応、MCPスナップショット、OAuth補助情報 |
| `ADMIN_DB` D1 | 購読者、RevenueCatイベント、利用イベント、問題報告、アプリエラー、お知らせ |
| `USER_REGISTRY` Durable Object | ユーザープロフィール、友達コード、友達・グループ関係の調整 |
| `CHAT_ROOM` Durable Object | チャットルーム、メッセージ、添付情報 |
| `DOCUMENT_ROOM` Durable Object | 共同編集参加者、提案、承認状態 |
| `RATE_COUNTER` Durable Object | AIなどの利用量カウンター |
| `MCP_INBOX` Durable Object | 外部MCPクライアントが作成した項目の受信箱と取り込み状態 |
| Cloudflare Rate Limiting bindings | 認証、チャット、MCP、Webhookなどの短時間レート制限 |

Durable Objectはユーザーまたはルーム単位の直列化が必要な状態に使い、D1は運営上の検索・集計、KVはキー参照中心の状態に使う。

### 5.3 外部サービス

| サービス | 用途 |
| --- | --- |
| Apple / Google | ID tokenを検証しStudiquoセッションを発行 |
| WebAuthn / Passkeys | パスキー登録・ログイン |
| Resend | メール確認コード送信 |
| RevenueCat | App Store課金、Webhook経由のサーバー側プラン同期 |
| Gemini / Anthropic / OpenAI | AIチャット、採点、復習教材生成 |
| APNs | チャット、お知らせなどのプッシュ通知 |
| Cloudflare Access | `/api/admin/*`管理画面・管理APIの保護 |
| Slack webhook | 問題報告の運営通知 |

外部サービスの秘密鍵はWorker secretsで管理し、iOSアプリやリポジトリへ入れない。

## 6. 主要データフロー

### 6.1 ノート編集とCloudKit同期

1. ユーザー操作をSwiftUI Viewが受け取る。
2. ViewまたはServiceが`ModelContext`でSwiftDataモデルを更新する。
3. SwiftDataがローカルストアへ保存する。
4. CloudKit対応ストアの場合、Appleの同期機構が別端末へ反映する。

Workerはこの同期経路に参加しない。CloudKit障害とWorker障害は別の障害領域である。

### 6.2 認証とセッション

1. ユーザーはメール、Apple、Google、Passkeyのいずれかで認証する。
2. Workerが外部資格情報またはメール資格情報を検証する。
3. Workerが正規化したユーザーidentityと期限付きBearer tokenを発行し、セッションをKVへ記録する。
4. iOSはtokenをKeychainへ保存し、API要求に付与する。
5. Workerはtoken期限、セッションの実在、identity統合、失効、アカウント削除状態を毎回確認する。
6. ログアウト時は端末tokenを先に削除し、Workerへ失効をbest effortで通知する。

認証済みであることと、対象ルーム・文書・管理機能への権限があることは別々に検証する。

### 6.3 AI機能

1. iOSの`WorkerAIProvider`が会話、画像、採点対象などをWorkerへ送る。
2. WorkerがセッションとRevenueCat由来のプランを解決する。
3. `RATE_COUNTER`と設定値で日次利用量を検証する。
4. Workerが許可されたAI provider/modelへ要求を中継する。
5. チャットはSSE、採点・復習は構造化結果としてiOSへ返す。

既定経路ではAIの秘密鍵はWorkerだけが持つ。
`ClaudeDirectProvider`はユーザー自身のAnthropic APIキーをKeychainに保存して直接接続する任意経路として残っている。

### 6.4 MCP連携

1. iOSがノートのOCR、カード、予定、文書、スライド、フォルダ情報をスナップショットとしてWorkerへ送る。
2. 外部MCPクライアントがOAuth Authorization Code + PKCEで接続し、read/write scopeを得る。
3. 読み取りツールは認証ユーザーのスナップショットだけを参照する。
4. 書き込みツールは`MCP_INBOX`へ項目をキューし、直接SwiftDataを変更しない。
5. iOSが受信箱を取得し、SwiftDataへの保存と`MCPImportReceipt`追加を同じトランザクションで行う。
6. 外部クライアントは`get_import_status`でpending/importedを確認する。

この構成により、外部AIが端末のローカルDBへ直接書き込むことを防ぎ、重複取り込みも抑止する。

### 6.5 友達・グループ・共同編集

- `USER_REGISTRY`がユーザー、友達コード、友達・グループ関係を管理する。
- `CHAT_ROOM`がルーム単位のメッセージと添付を直列化する。
- `DOCUMENT_ROOM`が文書参加者、権限、変更提案、承認を管理する。
- iOSの`FriendChatService`と`DocumentCollabService`が認証済みAPIとしてアクセスする。
- APNsは新着や状態変化の通知に使い、最終状態の正本にはしない。

### 6.6 課金

1. iOSがRevenueCat SDKで購入、復元、Entitlement取得を行う。
2. 認証完了後、RevenueCatのapp user idをStudiquoの正規identityへ合わせる。
3. RevenueCat webhookをWorkerが受け、D1の`subscribers`を更新する。
4. AI要求時、WorkerはD1から`standard`、`plus`、`pro`を判定する。

iOSのProduct ID、Entitlement ID、Workerのプラン対応は複数箇所で手動同期されるため、変更時は同時に確認する。

## 7. セキュリティ境界

- iOS入力、外部MCP入力、AI出力、Webhook payloadはすべて信頼しない。
- Workerはクライアントが送るユーザーIDではなく、検証済みセッションのidentityを認可判断に使う。
- ユーザー単位のキーやDurable Object名にはtokenまたはidentityのハッシュを使用し、生値を露出しない。
- 管理APIはCloudflare AccessをWorker内でも検証する。RevenueCat webhookは共有secretで別に保護する。
- API本文サイズ、件数、文字数、添付サイズ、URL schemeを境界で制限する。
- ノート本文、認証情報、AIキーをログへ出さない。診断情報は必要最小限にする。
- アカウント削除は端末データ、KV、Durable Objects、D1上の関連情報、外部連携を横断するHighリスク処理として扱う。

詳細なセキュリティ・プライバシー運用は、`docs/SECURITY_AND_PRIVACY.md`を正本とする。

## 8. ビルド、設定、デプロイ

### iOS

- iOS 17以上、iPad専用、Swift 5設定。
- Xcodeプロジェクトは`project.yml`からXcodeGenで生成する。
- Swift Package依存はGoogleSignIn、RevenueCat、SwiftMath。
- `project.yml`変更後は`xcodegen generate`を行う。
- XcodeGenの制約により、Sign in with AppleとCloudKitの`SystemCapabilities`が生成後も正しいか必ず確認する。
- Bundle IDは`com.yabuko.studiquo`、CloudKit containerは`iCloud.com.yabuko.studiquo`。

### Worker

- Node.js ESM、Cloudflare Workers、Wranglerを使用する。
- `npm test`は`src/*.test.js`をNode test runnerで実行する。
- D1 migrationは番号順の追加型とし、適用済みファイルを書き換えない。
- デプロイ、migration適用、secret変更は明示的な運用作業として分離する。
- `wrangler.jsonc`の`preview_id`は現在、本番と同じKV namespaceを指している。`wrangler dev`でも共有データへ触れ得るため、ローカル検証時は特に注意する。
- Observabilityはログ有効、traceはサンプリング有効である。

## 9. テスト戦略

- iOSロジックは`studiquoTests/`でサービス、モデル、ポリシー、移行、セキュリティ境界を検証する。
- 主要導線は`studiquoUITests/`で認証後の画面、AI、ライブラリ、タブ操作などを検証する。
- Workerは機能モジュールごとにNodeの単体・統合相当テストを置き、認証、認可、入力上限、並行状態を確認する。
- 外部サービスはテストダブルを使い、実サービスへの接続を通常のテスト成功条件にしない。
- SwiftDataスキーマ、CloudKit互換性、D1 migration、アプリとWorkerの新旧互換性は変更時の重点確認項目とする。

現時点では、リポジトリ内にCI設定は確認できない。ローカル検証結果を引き渡し時に明記する。

## 10. 変更時のルール

- 新しい画面固有ロジックはまずView内で小さく保ち、複数画面で共有するI/O・ポリシーはServiceへ移す。
- SwiftDataモデル追加時は`studiquoSchema`、テスト対象、CloudKit互換性を同時に更新する。
- Worker API追加時は認証要否、認可主体、入力上限、Rate Limit、保存先、削除経路を決める。
- 新しい状態の保存先は、検索・集計ならD1、キー参照ならKV、直列化されたルーム状態ならDurable Objectを基本に選ぶ。
- アプリとWorkerを同時に公開できると仮定せず、少なくとも1世代の互換性と公開順序を設計する。
- 外部サービス追加時はsecret管理、失敗時の挙動、タイムアウト、再試行、利用量上限、削除要求への対応を決める。
- 重要な設計判断を変更する場合は`docs/adr/`へADRを追加し、この文書の該当箇所も更新する。

## 11. 既知の制約と改善候補

- `ContentView.swift`と`StudiquoApp.swift`に複数責務が集まっており、変更時のコンパイル負荷と影響範囲が大きい。
- Product ID、RevenueCat Entitlement、Workerのプラン対応が自動生成されず、手動同期である。
- `RevenueCatConfiguration.publicAPIKey`は現在placeholderであり、出荷前に公開SDKキーの設定が必要である。
- Workerの開発用KVが本番namespaceと共有されている。
- `ClaudeDirectProvider`とWorker経由AIの2経路があり、機能差と秘密情報の責任範囲が異なる。
- API契約はSwift構造体、Zod schema、ハンドラーへ分散しており、機械可読な単一仕様はない。
- 詳細なデータ保持・削除表、障害Runbook、Release Checklistは別文書として今後整備する。

これらを変更する場合は、現行挙動を先にテストで固定し、小さな単位で移行する。

## 12. 関連文書

- `README.md`: セットアップと機能概要
- `AGENTS.md`: AIエージェントの常時ルールと開発手順モード
- `docs/DEVELOPMENT_WORKFLOW.md`: fullモードで使う詳細開発手順
- `docs/SECURITY_AND_PRIVACY.md`: データ分類、セキュリティ境界、保持・削除、既知課題
- `docs/cloudkit-verification.md`: CloudKit設定と確認事項
- `docs/ai-math-rendering.md`: AI数式表示の設計と公開順序
- `mcp-server/README.md`: WorkerとMCPの利用・運用概要
