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

## AI（Gemini）プロキシ

アプリのAIトークと証明添削は、Geminiを直接呼ばずにこのWorkerを経由します。**APIキーはこのWorkerだけが持ち、アプリには一切入りません。**

| エンドポイント | 用途 |
| --- | --- |
| `POST /api/ai/chat` | AIトーク（SSEで逐次返す） |
| `POST /api/ai/rubric` | 模範解答から採点基準を作る |
| `POST /api/ai/grade` | 答案画像を採点基準で採点する |

認証は `/api/*` と同じ端末トークンです。1端末あたりの1日の上限（チャット120回・添削20回）をKVで数えており、`CHAT_DAILY_LIMIT` / `GRADING_DAILY_LIMIT` で変更できます。

システムプロンプトと採点スキーマはWorker側にあるので、**採点の指示を直すのにアプリの再申請は要りません。** モデルも `GEMINI_CHAT_MODEL` / `GEMINI_GRADING_MODEL` で差し替えられます。

### 初回セットアップ

```bash
npx wrangler secret put GEMINI_API_KEY
```

プロンプトが出たらキーを貼り付けます。キーはCloudflareに保存され、コードにもgitにも残りません。

```bash
npx wrangler deploy
```

### 動作確認

```bash
curl -s https://studiquo-mcp.studiquo-mcp-server.workers.dev/health
```

## 開発

```bash
npm install
npm run dev
```

KVネームスペース `STUDIQUO_DATA` のIDは `wrangler.jsonc` に設定済みです。別のCloudflareアカウントで動かす場合は、`npx wrangler kv namespace create STUDIQUO_DATA` で作り直してIDを差し替えてください。
