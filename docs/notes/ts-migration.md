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

- なし(`mcp-server` 以外の JavaScript も .ts にした。下の「他のフォルダ」)。

## 進み具合

- フェーズ1 完了: `access` `ai-body` `auth` `block-check` `http` `jwks-verify` `library-id` `message-notification` `oauth-links` `pwned-passwords` `rate-limit` `slack` `token` `snapshot-crypto` `test-access` `test-account-generations`。他のファイルからの import は `.ts` に書き換え済み。
- フェーズ2 完了(2a 認証系18、2b AI系7、2c その他のドメイン層17の計42ファイル)。KV に保存する JSON の形は `records.ts`(複数ファイルで共有するもの)と各ファイル内の interface で型にした。KV 一覧の cursor は `kv.ts` の `nextCursor`、D1 の結果は `first<T>()` / `all<T>()` で型を付ける。
- フェーズ2では `noImplicitAny` を有効にしていないため、引数の型を省いた関数が残っている。フェーズ6で `noImplicitAny` と `strictNullChecks` を有効にして埋める。
- 型は消えるので、`npm test` が通っても型エラーは見つからない。`npm run typecheck` を別に必ず実行する。
- フェーズ3 完了: Durable Object 5本(`chat-room` `user-registry` `document-room` `rate-counter` `mcp-inbox`)と `counter-state` `document-room-store` を .ts 化。クラス名・エクスポート名・保存キー・SQLは変えていない。`Env` の Durable Object は暫定の `UntypedNamespace` をやめ、`DurableObjectNamespace<クラス>` にした。RPC の戻り値で型が深くなりすぎる・`SqlStorageValue` になる所は、メソッドに戻り値の型を明示するか `sql.exec<行の型>` で付ける。
- 挙動を変えていないことの確かめ方: `node:module` の `stripTypeScriptTypes` で各 .ts の型を消し、移行前の .js(import の拡張子だけ読み替え)と空白・コメントを無視して比べる。フェーズ3の時点で、差が出るのは `nextCursor` への置き換えなど、レビュー済みの意図した箇所だけ。
- フェーズ4 完了: `app` `transport` `index` `worker` `smoke` を .ts 化。`wrangler.jsonc` の `main`(`src/worker.ts`)、`package.json` の `start` `smoke`、`security/dast/harness.mjs` のバンドル入口を .ts に直した。MCP のツール結果は SDK の `CallToolResult` で型を付けた。`npm run smoke`(`node src/index.ts` を子プロセスで起動)で .ts のまま Node が動かせることを確かめた。
- ファイル名を書いたコメントと文書は、.ts にしたファイルの分をフェーズ3の後に直した(`src` のコメント、`docs/`、`mcp-server/README.md`、3つのツールのエージェント定義)。直さないもの: `docs/archive/`・`docs/releases/`(当時の記録)、適用済みの `migrations/`、アプリ側(Swift)のコメント。フェーズ4の分(`app` `worker` `index` `smoke` `transport`)も同じ要領で直した。

## テストの型検査

- フェーズ5で `*.test.js` 57本をすべて `.test.ts` にした。`npm test` は `src/*.test.ts` を Node の型除去で動かす。型を消して移行前の .js と比べると、全て同じ(増えたのは先頭のコメントだけ)。
- 型検査は2本立て: `tsconfig.json` は `src` をテストを除いて検査し、`tsconfig.test.json` はテストも含めて検査する(`npm run typecheck` が両方を実行)。テスト側は `strict: false` と、`test-types/loose.d.ts`(`Response.json()` を `any` にする)で検査している。
- 型エラーがあった49本の先頭に `// @ts-nocheck` を付けていた。原因は、JS のときは暗黙に許されていた書き方が .ts では型エラーになること: 偽の `Env`・偽の KV や Durable Object を `Env` や各クラスの型として渡している(エラーの約半分)、補助関数の引数が既定値から推論された型で狭い、呼び出しより多くの引数を必須にしている。
- 2026-10-20 に、49本のうち31本の `@ts-nocheck` を外した(残り18本)。やったこと:
  - `src/test-env.ts` に `partialEnv(...)` `partialCtx(...)` `partialState(...)` を足した。「テストは使う binding だけを持つ偽物を渡す」ことを、呼び出しごとのキャストではなく型で一度だけ表す(実行時は引数をそのまま返すだけ)。
  - 補助関数の `{ method = "GET", token, body } = {}` のような引数に、明示の型を付けた。
  - 型を消して(`partialEnv` などの包みも除いて)移行前と比べると、外した31本のうち30本は同一。違う1本は `legal.test.ts`(下)。
- `legal.test.ts` の見つけた問題: 「Worker が通信する外部ホストは、全てプライバシーポリシーに載っているか」の検査が、`.js` のファイルだけを探していた。ソースが `.ts` になってからは、何も調べずに通っていた。`.ts` を探すように直し、探したファイル数とホスト数が少なすぎたら失敗する確認を足した(今は 70 ファイル、11 ホストを調べ、全て通る)。
- 2026-10-20 に、残る18本(mcp-server)と vuln-watch の3本の `@ts-nocheck` も外した。テストの型検査は全て有効になった(`grep -r "@ts-nocheck" mcp-server scripts security` は 0 件)。やったこと:
  - 偽の束縛を返す補助関数の戻り値や、変数のまま渡す引数を `partialEnv` などで包んだ(`partialSql` `partialStorage` `partialNamespace` を追加)。`partialEnv` の型は `LooseEnv`(各束縛が `any`)にした。テストは束縛を自分の偽物に差し替え(`env.USER_REGISTRY = {...}`)、偽物の記録を読む(`env.RATE_COUNTER.purged`)ため、本物の束縛の型では書けない。
  - `contextOf(instance)`: Durable Object の `protected ctx` を型付きで取り出す。`migrationFiles()` `readMigration(file)`: テストが D1 のマイグレーションを読む(`new URL(...)` を `readFileSync` に渡すと、Workers の `URL` 型と Node の `URL` 型が食い違うため)。
  - `test-types/loose.d.ts`: `KVNamespace.get(key, "json")` もテスト側だけ `any` を返す。
  - 偽の D1 の文クラスのフィールド宣言、`call` 補助関数の引数の型、結果の絞り込み(`counter-state` の `takeOk`)。
  - 実装側の型を、実装が既に許していたとおりに直した: `handleDeviceRoutes` `handleMCPOAuth` の `ctx`、`handleAI` の `session` `plan` を省略可能に(いずれも本体が省略を許す書き方)。
  - vuln-watch は `http.ts` に `FetchLike` を足して、テストの偽の `fetch` を型で表した。
  - テスト 1060 件(通過 1059、スキップ 1)は変更前と同じ。`src` を型除去して比べると、実行時の差はない。
- `any` の置き換え(2026-10-20〜21): 明示の `any` は `src`(mcp-server)で 1 か所、vuln-watch と DAST で 0 か所、テストで約 13 か所(型を付けると検査の意味が変わる偽物など)になった。やり方は、使われ方から推論した型を `tsc` が通るものだけ採用する(作業用の道具で一括)ことと、残りを手で型付けすること。手で付けた主な型: `ThrottleState`/`ThrottlePolicy`/`LoginAttempt`(ログイン試行の制限)、`CborValue`/`Certificate`(App Attest)、`CreditRequest`(AI の利用枠)、`AnnouncementRow`、`StudyStats`/`BlockedContact`/`SnapshotNotebook`(records.ts)、vuln-watch の `Finding`/`RankedFinding`/`TriageItem`/`State`/`OsvVuln`/`NvdCve`/`JvnItem`、DAST の `ScanSummary`。外部から来た JSON を検証する関数(`validateOp` `sanitize*` `parseAnnouncement` `normalize` など)は引数を `unknown` にして、読む項目を疑ったまま取り出す。
- 残した `any`: `src/http.ts` の `readJSONLimited` の戻り値。40 か所を超える呼び出し元が、信用しない本体から期待する項目を読んで検証している。`unknown` にすると各呼び出し元に同じ型の断定を足すだけになるため、JSON の境界としてコメント付きで残した。テストの約 13 か所は、偽の D1 の呼び出し、`Record<string, any>`(偽物の引数の束)など。
- テストの strict: `alwaysStrict` `noImplicitThis` `strictBindCallApply` `strictFunctionTypes` `useUnknownInCatchVariables` は有効にした。`noImplicitAny`(約 1,500 件)と `strictNullChecks`(約 490 件)は、偽の Env や補助関数の引数に型を付ける作業が大きく、まだ無効。推論で約 410 か所の引数に型を足した(1,913 件→1,493 件)。残りは偽物の形そのものに型を付ける手作業になる。

## フェーズ6(strict 化)の結果

- `mcp-server/tsconfig.json` は `allowJs: false`・`strict: true`(`src` のテスト以外)。`Env` の添字シグネチャ(`[name: string]: unknown`)も外した。使っている変数・バインディングは全て `env.ts` に載っている。
- 型を後付けしたとき、実行時の挙動を変えないことを優先した。`!`(非 null 表明)と `as` は型を消すと何も残らない。値を変える書き換えは次の2つだけ(結果は同じ): `.filter(Boolean)` を `.filter(plan => Boolean(plan))` に、`const { iterations } = record` を `const iterations = record.iterations` に。
- 具体的な型を付けにくかった所は、暗黙の any を `: any` として明示した(当初約600か所。2026-10-20 の置き換えで `src` は約126か所)。新しいコードで暗黙の any は出せないが、この `any` は具体的な型へ直していく(Notion の別カード)。
- テスト(`*.test.ts`)は `tsconfig.test.json` で `strict: false` のまま、一部の strict 検査だけ有効(上)。`@ts-nocheck` は無くなった。
- 型を付けたとき、`AttestRecord.publicKey` を `Uint8Array` と誤って書いていたのを `string`(base64url)に直した。フェーズ3のレビューでも見つからなかった例なので、`any` を具体的な型にするときは実際に保存・送信される値を確かめる。

## 他のフォルダ(`mcp-server` 以外)

- `scripts/vuln-watch`(14+3本)・`security/dast`(3本)・`security/sast/fixtures/javascript.js`(→ `typescript.ts`)を .ts にした。リポジトリに JavaScript(`.js` `.mjs` `.cjs`)は残っていない。
- 実行は `node src/cli.ts ...` のように .ts を直接指定する(Node が型を除去する)。型検査: `scripts/vuln-watch` は自分の `tsconfig.json` と devDependencies(`typescript` `@types/node`)、`security/dast` は `security/tsconfig.json`(Node の型は `mcp-server` の `node_modules` から)。どちらも `strict`。引数の型は多くが明示の `any`(`mcp-server` と同じ方針)。
- `security/package.json`(`"type": "module"`)を足した。`.ts` を ESM として読ませるため。
- SAST: `.semgrep.yml` の規則は元から `[javascript, typescript]` なので、`.ts` もこれまで通り走査される。`security/sast/run.py` の「JavaScript を走査したか」の確認は、`.ts` を必須にした(コードが全部 .ts になったので、`.ts` の走査が抜けたら失敗させる。`.js` が1本残っていても通さない)。移行前と後で Semgrep の指摘は同じ20件(規則・ファイルとも同じ、行番号だけ違う)。
- CI: `ci.yml` に `scripts` ジョブ(vuln-watch の型検査とテスト)を足し、`security-dast.yml` に DAST スクリプトの型検査を足した。 `dependabot.yml` に `/scripts/vuln-watch` を足した(typescript と @types/node の更新を見るため)。
- vuln-watch は Claude Code のスケジュールタスクが `scripts/vuln-watch/RUNBOOK.md` に従って実行する。コマンドが `node src/cli.ts ...` に変わるので、許可設定(`.claude/settings.local.json` の `Bash(node src/cli.js scan)`)も `.ts` に直す必要がある(利用者の設定ファイルなので、ここでは直していない)。
