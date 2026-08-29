# Studiquo MCP Server

Studiquoアプリから同期したノート・OCRテキスト・暗記カード・カレンダーを、MCP対応AIクライアントから参照するためのCloudflare Workersサーバーです。

## 仕組み

- Studiquoアプリが `PUT /api/snapshot` に現在の学習データを送ります。
- AIクライアントは `/mcp` にBearerトークン付きで接続します。
- AIの書き込み系ツールは直接アプリを書き換えず、`/api/actions` に変更案をキューします。
- Studiquoアプリで「今すぐ同期」を押すと、キューされた暗記カード・予定を取り込みます。

## 開発

```bash
npm install
npm run dev
```

本番デプロイ前に、`wrangler.jsonc` のKV IDを実際の値へ置き換えてください。
