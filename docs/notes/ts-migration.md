# mcp-server の JavaScript → TypeScript 移行

状態の正は Notion の「Studiquo タスク」。ここには決めたことだけを書く。

## 決めたこと

- 対象は `mcp-server/src`。JS と TS を並存させ、1ファイルずつ `.ts` にする。最後に `allowJs` を外し `strict` を有効にする。
- 実行は Node 24 の型除去(テスト)と wrangler のバンドル(Worker)。ビルド工程は足さない。
  - import は実ファイル名(`./x.ts`)で書く。`enum`・`namespace`・引数プロパティは使わない(`erasableSyntaxOnly` で検査)。
- `Env` 型は `mcp-server/src/env.ts` に手書きする。シークレットや調整値は wrangler.jsonc の外で設定されるため、`wrangler types` の生成物には全部は載らない。bindings を変えたら wrangler.jsonc と合わせる。
- `npm run typecheck` を CI の Worker ジョブ(`.github/workflows/ci.yml`)で `npm test` の前に実行する。
- Durable Object のクラス名・エクスポート名・保存キーは変えない(migration に影響する)。

## フェーズ

0. 土台(tsconfig・typecheck・Env・CI) 1. ユーティリティ 2. 認証・AI・ドメイン層 3. Durable Object 4. エントリポイント・wrangler 5. テスト 6. strict 化・文書

## 対象外・あとで扱う

- `scripts/vuln-watch`、`security/dast`(`.mjs`)、`security/sast/fixtures`(検査用の見本なので変換しない)。
- フェーズ4では `security/dast/harness.mjs` が `mcp-server/src/worker.js` をバンドルしている点も直す。

## 進み具合

- フェーズ1 完了: `access` `ai-body` `auth` `block-check` `http` `jwks-verify` `library-id` `message-notification` `oauth-links` `pwned-passwords` `rate-limit` `slack` `token` `snapshot-crypto` `test-access` `test-account-generations`。他のファイルからの import は `.ts` に書き換え済み。
- 他の末端ファイルの行き先: Durable Object 周り(`chat-room` `mcp-inbox` `counter-state` `document-room-store`)はフェーズ3、`anthropic` `openai` `entitlements` と管理画面の `*-ui` はフェーズ2、`index` `smoke` はフェーズ4。
- `Env` の Durable Object は暫定の `UntypedNamespace`。フェーズ3で各クラスの型に置き換える。
- ファイル名を書いた文書(`docs/`、`.claude/agents/`、`.codex/agents/`、`.agents/skills/`)は、全て移行し終わるフェーズ6でまとめて直す。
