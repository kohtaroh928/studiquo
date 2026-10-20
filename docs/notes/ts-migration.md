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
- フェーズ2 完了(2a 認証系18、2b AI系7、2c その他のドメイン層17の計42ファイル)。KV に保存する JSON の形は `records.ts`(複数ファイルで共有するもの)と各ファイル内の interface で型にした。KV 一覧の cursor は `kv.ts` の `nextCursor`、D1 の結果は `first<T>()` / `all<T>()` で型を付ける。
- フェーズ2では `noImplicitAny` を有効にしていないため、引数の型を省いた関数が残っている。フェーズ6で `noImplicitAny` と `strictNullChecks` を有効にして埋める。
- 型は消えるので、`npm test` が通っても型エラーは見つからない。`npm run typecheck` を別に必ず実行する。
- フェーズ3 完了: Durable Object 5本(`chat-room` `user-registry` `document-room` `rate-counter` `mcp-inbox`)と `counter-state` `document-room-store` を .ts 化。クラス名・エクスポート名・保存キー・SQLは変えていない。`Env` の Durable Object は暫定の `UntypedNamespace` をやめ、`DurableObjectNamespace<クラス>` にした。RPC の戻り値で型が深くなりすぎる・`SqlStorageValue` になる所は、メソッドに戻り値の型を明示するか `sql.exec<行の型>` で付ける。
- 挙動を変えていないことの確かめ方: `node:module` の `stripTypeScriptTypes` で各 .ts の型を消し、移行前の .js(import の拡張子だけ読み替え)と空白・コメントを無視して比べる。フェーズ3の時点で、差が出るのは `nextCursor` への置き換えなど、レビュー済みの意図した箇所だけ。
- 他の末端ファイルの行き先: Durable Object 周りはフェーズ3で完了、`anthropic` `openai` `entitlements` と管理画面の `*-ui` はフェーズ2、`index` `smoke` はフェーズ4。
- ファイル名を書いたコメントと文書は、.ts にしたファイルの分をフェーズ3の後に直した(`src` のコメント、`docs/`、`mcp-server/README.md`、3つのツールのエージェント定義)。直さないもの: `docs/archive/`・`docs/releases/`(当時の記録)、適用済みの `migrations/`、アプリ側(Swift)のコメント。`app` `worker` `index` `smoke` `transport` は、フェーズ4で .ts にするときに同じ要領で直す。
