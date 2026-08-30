# Studiquo MCP Server

Studiquoアプリから同期したノート・OCRテキスト・暗記カード・カレンダーを、MCP対応AIクライアントから参照するためのCloudflare Workersサーバーです。

## 仕組み

- Studiquoアプリが `PUT /api/snapshot` に現在の学習データを送ります。
- AIクライアントは `/mcp` にBearerトークン付きで接続します。
- AIの書き込み系ツールは直接アプリを書き換えず、`/api/actions` に変更案をキューします。
- Studiquoアプリで「今すぐ同期」を押すと、キューされた暗記カード・予定を取り込みます。

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
