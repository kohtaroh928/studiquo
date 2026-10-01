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

公開ツールは `create_flashcards`、`create_document`、`create_slides`、`create_notebook`、`add_calendar_event`、`get_import_status` と、資料・フォルダを参照するツールです。フォルダを指定する場合は先にiPadの「今すぐ同期」を実行し、`list_folders` に出たパスを指定します。保存先を省略するとホームです。受信した資料はアプリ内の「受信した資料」に履歴が残ります。

リモートMCPの認証は動的クライアント登録、OAuth認可コード＋PKCE、アクセストークン更新を使います。初回接続時の確認はログイン済みiPadでのコード承認です。作成内容はアカウントごとのDurable Object受信箱に保持し、iPadのSwiftData保存記録と同じトランザクションで取り込み済みとして記録します。ChatGPT側の書き込み機能の利用可否は契約プランとクライアントの対応状況に依存します。

## AI（Gemini / Anthropic / OpenAI）プロキシ

アプリのAIトークと証明添削は、各社のAPIを直接呼ばずにこのWorkerを経由します。**APIキーはこのWorkerだけが持ち、アプリには一切入りません。**

| エンドポイント | 用途 |
| --- | --- |
| `POST /api/ai/chat` | AIトーク（SSEで逐次返す）。プラン対応モデルを選べる |
| `POST /api/ai/rubric` | 模範解答から採点基準を作る（Gemini固定） |
| `POST /api/ai/grade` | 答案画像を採点基準で採点する（Gemini固定） |
| `POST /api/ai/review` | 復習教材（解説＋一問一答）を作る（Gemini固定） |

認証は `/api/*` と同じ端末トークンで、`session.sub` を `entitlements.js`の`getPlan`でRevenueCatの`subscribers`テーブル（D1 `ADMIN_DB`、`admin.js`のWebhookが書き込む）に照会し、standard/plus/proのいずれかを解決します。RevenueCatの`app_user_id`はiOS側が`Purchases.shared.logIn(session.sub)`を呼ぶ前提でstudiquoの`sub`と一致させています（呼ばれていないと常にstandard扱いになります）。

1端末・1日あたりのAIクレジット上限はプラン別（standard 30 / plus 750 / pro 2000、`ai.js`の`PLAN_LIMITS`）で、`CHAT_DAILY_LIMIT` / `GRADING_DAILY_LIMIT` / `REVIEW_DAILY_LIMIT` で上書きできます。`/api/ai/chat`のみ、リクエストボディの`model`でプラン対応モデル（standardはGemini、plus以降でAnthropic Haiku/Sonnet・OpenAIミッド、proでAnthropic Opus・OpenAIフラッグシップまで）を選べ、プラン外のモデルを指定すると403になります。`model`を省略した場合は従来通りGeminiのみを呼びます。

システムプロンプトと採点スキーマはWorker側にあるので、**採点の指示を直すのにアプリの再申請は要りません。** Geminiのモデルは `GEMINI_CHAT_MODEL` / `GEMINI_GRADING_MODEL` で差し替えられます。

### 初回セットアップ

```bash
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put OPENAI_API_KEY
```

プロンプトが出たらキーを貼り付けます。キーはCloudflareに保存され、コードにもgitにも残りません。OpenAIの実際のモデルIDは本リポジトリでは未確定のため、OpenAIの最新ドキュメントを見て決め、下記も設定してください（モデル名自体は機密情報ではないので `wrangler.jsonc` の `vars` に書いても構いません）。

```bash
npx wrangler secret put OPENAI_MID_MODEL
npx wrangler secret put OPENAI_FLAGSHIP_MODEL
```

`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` が未設定のまま該当プロバイダのモデルを選ぶとそのリクエストだけがエラーになり（Geminiや設定済みの他モデルには影響しません）、`OPENAI_MID_MODEL` / `OPENAI_FLAGSHIP_MODEL` が未設定のまま`"openai-mid"` / `"openai-flagship"`を選ぶと503を返します。

```bash
npx wrangler deploy
```

### 動作確認

```bash
curl -s https://studiquo-mcp.studiquo-mcp-server.workers.dev/health
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

## 開発

```bash
npm install
npm run dev
```

KVネームスペース `STUDIQUO_DATA` のIDは `wrangler.jsonc` に設定済みです。別のCloudflareアカウントで動かす場合は、`npx wrangler kv namespace create STUDIQUO_DATA` で作り直してIDを差し替えてください。
