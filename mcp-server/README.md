# Studiquo MCP Server

Studiquoアプリから同期したノート・OCRテキスト・暗記カード・カレンダーを、MCP対応AIクライアントから参照するためのCloudflare Workersサーバーです。

## 仕組み

- Studiquoアプリが `PUT /api/snapshot` に現在の学習データを送ります。
- AIクライアントは `/mcp` にBearerトークン付きで接続します。
- AIの書き込み系ツールは直接アプリを書き換えず、`/api/actions` に変更案をキューします。
- Studiquoアプリで「今すぐ同期」を押すと、キューされた暗記カード・予定を取り込みます。

## Claude・ChatGPTの会話から資料を作る

1. iPadのホーム画面の「＋」→「MCPクラウド連携」でMCP URLをコピーします。
2. Claudeまたは対応するChatGPTのカスタムMCP連携にURLを登録します。
3. ブラウザーに表示された12文字の接続コードを、同じ画面の「接続コード」に入力します。接続先と権限を確認して許可します。端末トークンを外部サービスに貼り付ける必要はありません。
4. 会話中に「この内容をstudiquoの文書にして」などと依頼します。MCPツールは依頼IDを返し、iPadが開いている間は約30秒以内に、閉じている場合は次回起動時に取り込みます。MCPの`get_import_status`で取り込み済みか確認できます。
5. 接続はiPadの「MCPクラウド連携」から解除できます。解除後、発行済みアクセストークンもMCPに使えません。

公開ツールは `create_flashcards`、`create_document`、`create_notebook`、`add_calendar_event`、`get_import_status` と、資料・フォルダを参照するツールです。フォルダを指定する場合は先にiPadの「今すぐ同期」を実行し、`list_folders` に出たパスを指定します。保存先を省略するとホームです。受信した資料はアプリ内の「受信した資料」に履歴が残ります。

リモートMCPの認証は動的クライアント登録、OAuth認可コード＋PKCE、アクセストークン更新を使います。初回接続時の確認はログイン済みiPadでのコード承認です。作成内容はアカウントごとのDurable Object受信箱に保持し、iPadのSwiftData保存記録と同じトランザクションで取り込み済みとして記録します。ChatGPT側の書き込み機能の利用可否は契約プランとクライアントの対応状況に依存します。

## AI（OpenAI）プロキシ

アプリのAIトークと証明添削は、各社のAPIを直接呼ばずにこのWorkerを経由します。**APIキーはこのWorkerだけが持ち、アプリには一切入りません。**

| エンドポイント | 用途 |
| --- | --- |
| `POST /api/ai/chat` | AIトーク（SSEで逐次返す）。プラン対応モデルを選べる |
| `POST /api/ai/rubric` | 模範解答から採点基準を作る（Luna固定） |
| `POST /api/ai/grade` | 答案画像を採点基準で採点する（Luna固定） |
| `POST /api/ai/review` | 復習教材（解説＋一問一答）を作る（Luna固定） |

認証は `/api/*` と同じ端末トークンで、`session.sub` を `entitlements.js`の`getPlan`でRevenueCatの`subscribers`テーブル（D1 `ADMIN_DB`、`admin.js`のWebhookが書き込む）に照会し、standard/plus/proのいずれかを解決します。RevenueCatの`app_user_id`はiOS側が`Purchases.shared.logIn(session.sub)`を呼ぶ前提でstudiquoの`sub`と一致させています（呼ばれていないと常にstandard扱いになります）。

AIの利用量は**クレジット**で数え、プランごとに4つの窓（1分あたりの回数・5時間・1日・1か月。1日と1か月は日本時間）で同時に制限します。数える単位は端末ではなく**アカウント**です（`ai-credits.js`）。1クレジットは約$0.0007の原価で、モデルごとの重み（Luna 1 / Sol 20 / Terra 22 / Astra 100）と機能ごとの倍率（チャット1 / 採点基準2 / 採点・復習3）を掛けた値を、1回の呼び出しで消費します。

| | 1分(回数) | 5時間 | 1日 | 1か月 |
|---|---|---|---|---|
| standard | 5 | 40 | 60 | 120 |
| plus | 10 | 400 | 600 | 1,500 |
| pro | 20 | 1,000 | 1,500 | 4,000 |

上限に達すると429（`code: "ai_limit"`、`window` は `minute` / `fiveHours` / `day` / `month` / `global`）を返します。別に、機能ごとのサービス全体の1日の上限（`GLOBAL_*_DAILY_LIMIT`）も残してあります。重みや上限を直すときは`ai-credits.js`の表だけを変えます（アプリに表示するクレジット数は`SubscriptionPlansView.swift`に手で合わせます）。

`/api/ai/chat`のみ、リクエストボディの`model`でプラン対応モデルを選べます（standardはChatGPT Luna、plusはLunaに加えてTerra・Sol、proはさらにAstra）。プラン外のモデルは403です。`model`を省略した場合はLunaを呼びます。AnthropicのコードはWorkerに残っていますが、どのプランの表にも載せていないため無効です。

**AIを使える人の条件と安全策**（OpenAIの利用条件が13歳未満を対象外とし、未成年には保護者の同意を求めるため）:

- アプリは初回に年齢区分（`adult`＝18歳以上、`teen`＝13〜17歳で保護者の同意あり）を確認し、リクエストに`X-Studiquo-Age`ヘッダーを付けます。13歳未満は選べず、AIを使えません。ヘッダーが無い・不正な値のリクエストは`ai-privacy.js`が403で止めます。
- 同意の版は`openai-v1`（`X-Studiquo-AI-Consent`）。古い版や`AI_PROVIDER_APPROVED`が`true`でないときは使えません。
- 利用者の入力文はOpenAIのモデレーション（`omni-moderation-latest`）にかけ、不適切と判定されたら送らずに400（`code: "content_rejected"`）を返します（自傷関連は止めません。モデレーション自体が落ちているときは通します。`AI_MODERATION=off`で無効化）。
- OpenAIへ送るときは`store: false`と、アカウントのハッシュを元にした`safety_identifier`を付けます（アカウントIDそのものは送りません）。

システムプロンプトと採点スキーマはWorker側にあるので、**採点の指示を直すのにアプリの再申請は要りません。** モデルは`OPENAI_*_MODEL`で差し替えられます。

### 初回セットアップ

```bash
npx wrangler secret put OPENAI_API_KEY
```

プロンプトが出たらキーを貼り付けます。キーはCloudflareに保存され、コードにもgitにも残りません。OpenAIの実際のモデルIDは本リポジトリでは未確定のため、OpenAIの最新ドキュメントを見て決め、下記も設定してください（モデル名自体は機密情報ではないので `wrangler.jsonc` の `vars` に書いても構いません）。

```bash
npx wrangler secret put OPENAI_LUNA_MODEL
npx wrangler secret put OPENAI_TERRA_MODEL
npx wrangler secret put OPENAI_SOL_MODEL
npx wrangler secret put OPENAI_ASTRA_MODEL
```

（`wrangler.jsonc` の `vars` に、2026-10-12時点のIDを入れてあります。変えるときはそこを直します。）

`OPENAI_API_KEY` が未設定だとAIのリクエストはエラーになります。`OPENAI_*_MODEL` が未設定のまま該当の`"openai-luna"` / `"openai-terra"` / `"openai-sol"` / `"openai-astra"`を選ぶと503を返します。

```bash
npx wrangler deploy
```

### 動作確認

```bash
curl -s https://api.studiquo.app/health
```

## APNsプッシュ通知

iOSアプリは、通知を初めて必要とする画面で許可を求め、許可後に
`POST /api/chat/devices`へAPNsデバイストークンを登録します。許可済みの
端末では起動・ログイン時に再登録し、ログアウト時は
`DELETE /api/chat/devices`でこの端末だけを解除します。

Apple DeveloperでProduction用とSandbox用のAPNs認証キーを発行し、
次の5項目をWrangler secretsへ登録してください。秘密鍵はヘッダーと
フッターを含む`.p8`ファイルの全文です。

```bash
npx wrangler secret put APNS_PRODUCTION_AUTH_KEY
npx wrangler secret put APNS_PRODUCTION_KEY_ID
npx wrangler secret put APNS_SANDBOX_AUTH_KEY
npx wrangler secret put APNS_SANDBOX_KEY_ID
npx wrangler secret put APNS_TEAM_ID
```

移行互換のため、従来の`APNS_AUTH_KEY` / `APNS_KEY_ID`は両環境で使える
旧形式キーまたはProduction用キーとして引き続きフォールバックされます。

Bundle IDに対応する`APNS_TOPIC`は`wrangler.jsonc`で
`com.yabuko.studiquo`に設定済みです。秘密鍵はコードや設定ファイルへ
直接書き込まないでください。

### スナップショットの暗号化

MCPが読む同期データ(ノートのOCR文字、暗記カード、予定)をKVに保存する前にAES-256-GCMで暗号化します。鍵を設定してからデプロイしてください。鍵が無いと平文のまま保存されます(`SNAPSHOT_ENCRYPTION_REQUIRED=true`にすると、鍵が無い間は同期を拒否します)。

```bash
openssl rand -base64 32 | npx wrangler secret put SNAPSHOT_ENCRYPTION_KEY
```

鍵を失うと保存済みの写しは読めなくなりますが、アプリで再同期すれば復旧します。鍵を替えるときは、現在の鍵を`SNAPSHOT_ENCRYPTION_KEY_OLD`(`SNAPSHOT_ENCRYPTION_KEY_OLD_ID`に旧ID)へ移し、新しい鍵を`SNAPSHOT_ENCRYPTION_KEY`(`SNAPSHOT_ENCRYPTION_KEY_ID`に新ID)へ入れます。

## 開発

```bash
npm install
npm run dev
```

KVネームスペース `STUDIQUO_DATA` のIDは `wrangler.jsonc` に設定済みです。別のCloudflareアカウントで動かす場合は、`npx wrangler kv namespace create STUDIQUO_DATA` で作り直してIDを差し替えてください。
