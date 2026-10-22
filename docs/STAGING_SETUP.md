# Studiquo ステージング環境の準備と確認

最終更新: 2026-10-22(10章を追加)
状態: **ステージング環境は作成済みで、一部の確認は完了している。** 3〜5章は作成時の手順(再作成や、別の環境を作るときの手引き)、6章は確認項目と実測の記録である。クラウド上のリソースの作成と秘密情報の設定は、運営者が行う。

## 現在の状態(認証検証は2026-10-08、RAG整備は2026-10-09時点)

認証の従来記録に加え、2026-10-09に承認済みRAG staging配信・合成100ページ検証を実施した。配信情報・flag・削除結果は読み取りで最終確認した。

| 項目 | 状態 |
| --- | --- |
| Worker | `studiquo-mcp-staging` が存在する。RAG開発版を2026-10-09 21:53(日本時間)に配信。最終版 `3cb1bc6e-29cd-4906-9f00-d049e5a9bf85`、RAG／AI承認flagはfalse |
| KV・D1 | 専用のKVと`studiquo-admin-staging`(D1)を使う。本番のIDは使わない(`wrangler.jsonc`の`env.staging`、コミット `8cfeb4e`) |
| D1のmigration | 2026-10-09にRAG検証用の`0007_rag_context.sql`まで適用済み。**本番へ出すスキーマ(0005まで)とは一致しない**(本番は`0005`が未適用で、`0006`以降は出さない) |
| 確認済み | 6.2(応答時間の均一化)、6.3(通知メールとSlackアラート)、6.4(`ARGON2_WRITE`の2段階の予行)、6.5(退会)。いずれも 2026-10-07 |
| 未確認 | 6.1のアプリ表示(結果の記録なし)。6.6の自己紹介(ステージング上。ローカルでは確認済み)。退会時のDurable Object内のデータ。`0005`の再実行・途中失敗 |
| 後片付け | 未実施。Worker・KV・D1が残っている |

**現在のステージングはRAG開発スナップショットであり、認証リリース候補の検証環境と同一ではない。** 以下はRAG更新前に残っていた認証・bioの確認項目で、今回のRAG試験でも確認していない。
- `50ad5b9`: サインイン時のメール連携で、変わっていないKVの書き込みをやめる
- `8082f27`: フレンドの自己紹介(bio)の保存と共有
- `2b098c8`: テストのみ(ステージングへの影響なし)

本番へ出す前に必要なこと:
- リリース候補のコミットを、ステージングへデプロイし直す。デプロイは、作業ツリーからではなく、対象コミットのクリーンな取り出しから行う(作業ツリーには、未コミットのRAGの作業がある)。
- `0005`の再実行と途中失敗を確認する。
- フレンドの自己紹介(bio)を確認する。
- ステージングを、本番と同じスキーマで確認できる形にするかを決める。

## 1. 目的と、先に知っておくこと

RAG整備後の修正・再検証（2026-10-09）: [RAG_STAGING_FIX_REPORT.md](RAG_STAGING_FIX_REPORT.md)。localhostの私有ランタイムから実bindingで27/27確認、検証データ削除済み。公開staging Workerを更新したものではない。

RAGの追加整備記録（2026-10-09）: 専用Vectorize `studiquo-rag-v1-staging`（1024次元・cosine）と4つのmetadata indexを作成し、0007を適用した。追加整備時は私有ランタイムで検証し、後続の承認により公開staging Workerも更新した。最終的にRAG/AI承認flagはfalseへ戻した。合成100ページの公開API試験と私有model計測の詳細は [RAG_100_PAGE_STAGING_REPORT.md](RAG_100_PAGE_STAGING_REPORT.md)を参照。これは以下の認証リリース検証とは別工程であり、[RAG_STAGING_VALIDATION_REPORT.md](RAG_STAGING_VALIDATION_REPORT.md)に記録する。

認証まわりの変更(ログインの多段制限、Argon2idへの移行、新しい環境の通知、退会時の削除)のうち、ローカルでは確かめられないものを、本番に出す前に確認する。

- ステージングは、**別のKV・D1・秘密情報を持つ、別のWorkerとして作る**。本番のbindingを、1つも共有しない。トップレベルの`mcp-server/wrangler.jsonc`には、KV(`preview_id`も同じ)とD1は本番のものだけが書かれており、この設定のまま別名のWorkerを出すと、本番のデータに書き込む。
- `wrangler`の`env`は、トップレベルのbindingを**継承しない**。`env.staging`に、使うbindingをすべて書き直してある。
- 手順の途中で、`--env staging`を付け忘れると、本番に対する操作になる。コマンドは、ステージング用の**明示的なID**(`--namespace-id`、`--database`)を指定する形で書いてある。

## 2. 事前に用意するもの

| 項目 | 内容 |
| --- | --- |
| Resend | ステージング用のAPIキー。コード送信の確認は、**Resendのアカウントの持ち主の、ご自身のメールアドレス**を使う(共通の送信元は、持ち主のアドレスにだけ配送できる)。`delivered@resend.dev`(Resendのテスト用宛先)は、実在の人に届かないが、使えるかは、確認していない |
| Slack | テスト用チャンネルのIncoming Webhook URL。本番のチャンネルには、投稿しない |
| ランダムな値 | `CSRF_SECRET`など、ステージング専用の値(`openssl rand -base64 32`) |
| シミュレータまたは実機 | アプリの表示確認用。アプリは`https`のエンドポイントだけ受け付ける |

使わないもの(設定しない): `GEMINI_API_KEY`。AI(`AI_PROVIDER_APPROVED=false`)は、この確認の対象外である。管理画面(`ACCESS_*`)、プッシュ通知(`APNS_*`)、課金のWebhook(`REVENUECAT_WEBHOOK_SECRET`)は、2026-10-22に使えるようにした。設定は**10章**を参照(最初は、どれも未設定)。

## 3. リソースの作成

名前は例。既存のものと重ならないようにする。

```bash
cd mcp-server

# 1. ステージング用のKV namespace(出力されるidを控える)
npx wrangler kv namespace create STUDIQUO_DATA_STAGING

# 2. ステージング用のD1(出力されるdatabase_idを控える)
npx wrangler d1 create studiquo-admin-staging
```

D1のmigrationは、手順4でD1のIDを入れ替えた**後**に、ステージングのD1にだけ適用する(トップレベルの設定には、このDBがないため、`--env staging`が必要)。

```bash
npx wrangler d1 migrations apply studiquo-admin-staging --env staging --remote
```

## 4. `wrangler.jsonc`のIDを入れ替える

`mcp-server/wrangler.jsonc`の末尾には、`env.staging`を**追加済み**である(トップレベルの本番の設定は、変更していない)。ただし、2つのIDは、わざと**ダミーの値**にしてある。手順3で控えたIDに、置き換える。

| 場所 | ダミーの値 | 置き換える値 |
| --- | --- | --- |
| `env.staging.kv_namespaces`の`id`と`preview_id`(2か所) | `REPLACE_WITH_STAGING_KV_NAMESPACE_ID` | `wrangler kv namespace create`が出力したid |
| `env.staging.d1_databases`の`database_id` | `REPLACE_WITH_STAGING_D1_DATABASE_ID` | `wrangler d1 create`が出力したdatabase_id |

ダミーのままデプロイしても、失敗するだけで、何も変更されない。

`env.staging`の内容は、次の通りである。

- 別名のWorker(`studiquo-mcp-staging`)。時刻起動(cron)なし。
- 別のKV、別のD1、別のDurable Objects(同じクラスを、別のWorkerとして持つ)。
- レート制限は、本番と同じ名前・回数で、`namespace_id`だけを`10NN`から`20NN`に変えてある(本番とカウンタが混ざらない)。
- `vars`は、`PRIVACY_RETENTION_ENABLED`と`AI_PROVIDER_APPROVED`が`"false"`、`ARGON2_WRITE`が`"false"`。送信元メールは、`Studiquo Staging <onboarding@resend.dev>`。

**IDを入れ替えた後に、必ず確認すること**(デプロイの前に、読み取りだけで確認する):

```bash
npx wrangler deploy --env staging --dry-run --outdir /tmp/staging-dry
```

出力のbindingの一覧で、`STUDIQUO_DATA`のIDが**ステージング用**、`ADMIN_DB`が`studiquo-admin-staging`になっていることを、目で確認する。本番のID(`e1171479…`、`fb64e302…`)が1つでも出たら、デプロイしない。

(この設定を追加した時点で確認済み: ダミーIDでの`--env staging`のdry-runに、本番のIDは出ない。`--env`なしの本番のdry-runは、変更前と同じ内容である。)

## 5. 秘密情報の設定と、デプロイ

```bash
npx wrangler secret put RESEND_API_KEY --env staging
npx wrangler secret put SLACK_ISSUE_REPORT_WEBHOOK_URL --env staging
npx wrangler secret put CSRF_SECRET --env staging

npx wrangler deploy --env staging
```

デプロイ後の`https://studiquo-mcp-staging.<アカウントのサブドメイン>.workers.dev`が、ステージングのURLである。

## 6. 確認項目

ステージングのURLを`STG`とする。

### 6.1 アプリの表示(429・503・漏えいパスワードの拒否)

アプリのエンドポイントを、シミュレータの設定として、ステージングに向ける。

```bash
xcrun simctl spawn booted defaults write com.yabuko.studiquo mcpCloudEndpoint "https://<STG>"
```

| 確認 | 手順 | 期待 |
| --- | --- | --- |
| 新規登録のコード送信 | アカウント作成で`delivered@resend.dev`宛に送る | 確認画面に進む(メールは、Resendのダッシュボードで確認) |
| 漏えいパスワードの拒否 | `password123`で登録し、コードを入力する | 確認画面に留まり、「別のパスワードを入力してください」と新しいパスワードの欄が出る。同じコードで続けられる |
| ログインの429 | 誤ったパスワードで7回続けて失敗する | 「あと約15秒お待ちください。」。「違います」とは表示されない |
| 確認コードの429 | 同じメールで、コード送信を6回続ける | 「確認コードの送信が続いたため…」 |
| ログインの503 | 同時に大量のログイン(負荷)をかけたとき | 「サーバーが混み合っています」。普通は、自動の再試行で、利用者には見えない |

終わったら、本番に戻す: `xcrun simctl spawn booted defaults delete com.yabuko.studiquo mcpCloudEndpoint`

### 6.2 応答時間の均一化

未登録のメールと登録済みのメールの、誤ったパスワードの応答時間を、ステージングに対して測る。ネットワークのばらつきを避けるため、各20回以上、順番を回して測る。IPごとの制限(10回/分)に当たらないよう、7秒おきに送る。ステージングのKVに、Argon2idと旧PBKDF2の両方のアカウントを入れる(7.を参照)。

**実測の結果(2026-10-07、ステージング、各20回):**

| 種類 | 中央値 | p10〜p90 |
| --- | --- | --- |
| Argon2idのアカウント | 1745ms | 1506〜2288ms |
| 旧PBKDF2のアカウント | 1746ms | 1559〜2479ms |
| 未登録のメール | 1704ms | 1520〜2369ms |

- 3つの中央値の差は、41.7ms(2.4%)で、ばらつき(p10〜p90の幅は約800ms)より小さい。応答本文は、3つとも同一で、すべて401だった。登録の有無や、保存形式は、応答時間から判別できない。
- **絶対値が大きいのは、この測定の条件による。** 毎回、新しいメールアドレスを使ったので、Durable Objectが毎回新規に作られた。同じアカウントへの繰り返し(Durable Objectが暖まった状態)では、実時間は約0.3〜0.5秒、CPU時間は約240〜400msだった。`wrangler tail`の`cpuTime`と`wallTime`で確認した。
- 実際の利用の遅さの目安は、暖まった状態の値(約0.3〜0.5秒)。ハッシュを行わない経路は、ネットワークを含めて約0.2秒。

### 6.3 通知メールとSlackアラート

| 確認 | 手順 | 期待 |
| --- | --- | --- |
| 新しい環境の通知メール | 別の国・ネットワークからのログイン(VPNなど)で、成功させる | Resendのダッシュボードに、通知メールが記録される。本文にIPが載らない |
| 失敗の急増のアラート | 閾値を一時的に下げたビルドで、閾値を超える失敗を送る | テスト用のSlackに、1回だけ投稿される |

**実施の結果(2026-10-07):**

- **Slackアラートの経路:** 本物の閾値(1時間に100件)は、私のネットワーク(ASN)の失敗回数の上限(無料100回)に、同時に当たる。そのため、**閾値を5に下げたビルドを、ステージングだけに出し**(コミットしない、独立した作業ディレクトリから)、8件の誤ったパスワードを送った。サーバー側では、8件がログに残り、エラーも例外も0件だった。Slackへの投稿の成功は、サーバーからは見えない(応答を確認していない)ので、テスト用のチャンネルを目で確認した: **「ログイン失敗が急増しています」が1件だけ**入っていた(8件の失敗に対して、重複なし)。本文は固定の文言と、閾値の件数だけで、メールアドレスもIPも含まない(本文の件数は、一時的な閾値の「5件」。本来のビルドでは「100件」と出る)。確認後、本来の閾値のビルドに戻した。
- **新しい環境の通知メール(送信の経路):** 初めてのログイン成功(履歴なし)でも通知メールを送る仕様なので、テスト用アカウント(`tmodern15@example.com`)で試した。ログ(`wrangler tail`)に、`sign-in notice failed … Resend responded 422`が記録された。**ログイン自体は成功**(200)で、通知の失敗は、ログインを止めない設計どおり。`example.com`宛のメールは、どこにも届かず、**Resendの「Emails」にも、記録は残らない**(APIの時点で拒否されるため。前の版の記述を訂正)。
- **通知メールの本文の確認には、実際に届く宛先が必要。** Resendの共通の送信元(`onboarding@resend.dev`)は、**Resendのアカウントの持ち主のメールアドレスにだけ**、配送できる。持ち主のアドレスのテスト用アカウントを、ステージングのKVに直接作り(履歴のない状態)、初めてログインすると、そのアドレスに、通知メールが届く。受信箱で、件名、日時、場所、ネットワーク名、**IPが載っていない**ことを確認する。
- **持ち主のアドレスでの確認(2026-10-07、合格):** Resendのアカウントの持ち主のアドレスで、テスト用アカウントを、ステージングのKVにだけ作り(履歴のない状態、パスワードは、ランダムで、画面にもチャットにも出さない)、初めてログインした。ログインは200で、ログに通知の失敗はなく、**通知メールは、受信箱に届いた**。件名、日時(日本時間)、場所(国・地域)、ネットワーク名が書かれていて、**本文にIPアドレスも、URLのリンクも、載っていない**ことを、利用者が目で確認した。確認の後、そのアドレスを含む記録(アカウント、連携の3つ、セッション)を、ステージングのKVから削除し、パスワードのファイルも消した(本番のKVの、同じアドレスのアカウントは、触っていない)。
- **本番のリリースの前に確認すること:** 本番も、`RESEND_FROM_EMAIL`が未設定だと、同じ共通の送信元になり、持ち主以外のアドレスには、確認コード(新規登録・パスワード再設定)も、通知メールも、配送できない可能性が高い。Resendで、自分のドメインを認証して、そのドメインのアドレスを、本番の`RESEND_FROM_EMAIL`に設定する。

### 6.4 `ARGON2_WRITE`の2段階リリースの予行

設定ファイルは編集せず、デプロイ時に`--var`で上書きする(`true`のまま残らないようにするため)。

```bash
npx wrangler deploy --env staging --var ARGON2_WRITE:true   # 段階2
npx wrangler deploy --env staging                           # 段階3(設定ファイルの値の"false"に戻る)
```

`--var`で渡した値は、CLIの出力で`(hidden)`と表示されるので、`true`になったかどうかは、動作で確認する。

**実測の結果(2026-10-07、ステージング)**

| 段階 | 確認 | 結果 |
| --- | --- | --- |
| 1: `false` | 旧形式のアカウントで、正しいパスワードでログイン | 200。保存の形式は、旧形式のまま |
| 2: `true` | 旧形式のアカウントで、正しいパスワードでログイン | 200。保存の形式が`argon2id`(m=19456, t=2, p=1, gen=0)に変わった。2件で確認 |
| 2: `true` | 変更後のアカウントで、もう一度ログイン、誤りのパスワード | 200、401 |
| 2: `true` | 旧形式のアカウントで、**誤った**パスワード | 401。形式は変わらない |
| 3: `false`に戻す | 書き換え済みのアカウントで、正しい・誤りのパスワード | 200、401。戻した後も、ログインできる |
| 3: `false` | 旧形式のアカウントで、正しいパスワード | 200。**書き換わらない**(20秒後も旧形式) |
| 3: `false` | 最初からArgon2id形式のアカウント | 200 |

- **KVの読み取りは、書き込み直後に古い値を返すことがある。** 書き換えの直後に、CLIで読むと、旧形式のままに見えることがあった(約1分後には、新形式)。ログインの処理の誤りではなく、世代の仕組みが想定している、KVの性質である。確認するときは、時間を置いて読む。
- **ログインに成功する経路は、失敗の経路より、ずっと遅い。** ステージングの実測で、成功は約6秒、失敗は約0.9秒だった。区間ごとに測ると(`Server-Timing`ヘッダーと、KVの操作ごとの時間を、一時的に出して測った)、遅さの大半は、元からあるKVの処理だった。

  | 区間 | 変更前 | 変更後 |
  | --- | --- | --- |
  | メールの連携(`linkVerifiedEmail`) | 2.6〜4.0秒 | 0.6〜1.5秒(書き込みなし、読み取り1段) |
  | セッションの発行(`mintSession`) | 1.4〜3.2秒 | 1.2〜2.3秒(未変更) |
  | 回数制限のDurable Object(`begin`) | 0.56〜0.76秒(新規のDOのとき) | 同じ |
  | パスワード照合(Argon2id) | 0.24〜0.31秒 | 同じ |

  連携の処理が、ログインのたびに、連携済みの全identityのマッピングを、内容が変わらなくても書き直していたので、変更があったものだけを書くようにした。連携済みのアカウントのログインは、約5.5〜7秒から、約3.2〜3.9秒になった(最悪で5.9秒)。初めてのログイン(identityごとに1回)は、書き込みが要るので、約6秒のまま。

  **残る遅さの原因は、KVの遅さである。** KVは、最近読まれていないキーを、遠い保存先から取りに行くので、1回の操作に、0.3〜2.4秒(ときどき3.8秒や9秒)かかる。`mintSession`は、KVの操作を、3回、順番に行う(`account-deletion`の読み取り、`privacy-rc-delete`の読み取り、セッションの書き込み)。最初の2つの読み取りは、並列にできる(約0.3〜0.9秒の短縮)。`session.ts`は、別の作業の変更があるときは、触らない。根本的には、Durable Objectやキャッシュへの移行を検討する。

### 6.5 退会

テストのアカウントで、アプリ(またはAPI)から退会し、次を確認する。

- アカウント本体、メールの連携の記録が、消えている。
- 退会したアカウントの資格情報では、ログインできず、古いセッションも使えない。
- パスワードの世代カウンタだけは、7日間残る(`SECURITY_AND_PRIVACY.md`の15.2)。

**実施の結果(2026-10-07、`tmodern13@example.com`):**

- ログインして、そのセッションで`DELETE /api/account`(`{"confirmation":"DELETE"}`)を呼ぶと、**202**、`{"deleted":true,"externalDeletionPending":true}`が返った(外部の削除は、順次処理される、という仕様どおり)。
- 次の4つのキーが、すべて消えた: `account:local:…`、`email-accounts:…`、`email-account-owner:…`、`identity-canonical:email:…`。隣の、無関係なアカウント(`tmodern14`)のキーは、そのまま残った。
- 退会したアカウントの資格情報でのログインは、401。退会前のセッションで認証が必要なAPIを呼んでも、401。
- **確認の注意:** `wrangler kv key get`は、削除の後でも、時間を置いて(70秒)、古い値(キーが「ある」)を返した。**`wrangler kv key list --prefix`で確認する**と、正しく0件だった。KVの結果整合性の影響で、削除の確認は、`get`ではなく、`list`か、時間を置いた再確認で行う。
- **未確認:** Durable Object内のデータ(ログイン元の履歴、失敗カウンタなど)が、消えたことは、外から読めないので、確認していない(コードとテストでは、`purgeAll`と世代の退役を確認済み)。


### 6.6 自己紹介(bio)

フレンドの自己紹介(`POST /api/chat/me`の任意項目`bio`、`GET /api/chat/friends`の応答)の確認。

**ローカルでの確認(2026-10-08、コミット`db41a16`のクリーンな取り出し、`wrangler dev --local`、19件すべて合格):**
テスト用アカウント3人(Alice、Bob、Carol)を、ローカルのKVにだけ作って確認した。AliceとBobがフレンド、Carolは他人。
- 保存と共有: Aliceが自己紹介を保存でき(200)、Bobの一覧に、改行を保ったまま出る。
- 公開範囲: フレンドでないCarolの一覧にAliceは出ない。CarolがAliceに申請した応答と、申請中の一覧に、自己紹介は含まれない。
- 互換性: `bio`を省略した更新(旧アプリ相当)では、自己紹介が維持される。
- 更新と消去: 更新でき、空文字で消せる。
- 入力検証: `null`・数値・オブジェクト・配列・501文字は、すべて400で拒否され、直前の値は壊れない。500文字(絵文字)ちょうどは保存できる。
- 認証: 認証なしの更新は401。

これは、ローカルで動くWorkerの確認であり、ステージング環境そのものの確認ではない。

**ステージングでの確認(未実施。運営者が、ステージング用のアカウントで行う):**

| 確認 | 手順 | 期待 |
| --- | --- | --- |
| エンドポイントの切り替え | `xcrun simctl spawn booted defaults write com.yabuko.studiquo mcpCloudEndpoint "https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev"` でステージングに向ける | アプリがステージングに接続する |
| フレンドになる | 2台(または2つのシミュレータ)で、別々のステージング用アカウントを作り、フレンド申請と承認をする | 双方のフレンド一覧に相手が出る |
| 自己紹介の設定 | 片方のプロフィールで自己紹介を入力する(改行を含める) | 数秒〜数十秒後に、もう片方のフレンドのプロフィールの「自己紹介」に、改行を保って表示される |
| 未設定の表示 | 自己紹介を設定していない相手のプロフィールを開く | 「自己紹介はまだありません」と表示される |
| 消去 | 自己紹介を空にする | 相手側の表示が「自己紹介はまだありません」に戻る |
| 上限 | 501文字以上を入力する | アプリは500文字までを共有する(超えた分は送られない) |
| フレンド以外 | フレンドでない第三者のアカウントで、相手のプロフィールを探す | 自己紹介は見えない |

終わったら本番に戻す: `xcrun simctl spawn booted defaults delete com.yabuko.studiquo mcpCloudEndpoint`

## 7. ステージングのデータの扱い

旧形式のアカウントを作るには、PBKDF2のレコードをKVに直接書く。**必ず、ステージングのKVの`--namespace-id`を明示する**(`--binding`だけで指定すると、本番を指す可能性がある)。

```bash
npx wrangler kv key put "account:local:legacy1@example.com" --path legacy1.json \
  --namespace-id <STAGING_KV_ID> --remote
```

レコードの形式は、`mcp-server/src/local-auth.ts`の旧形式(`salt`、`passwordHash`、`iterations`)。パスワードのハッシュは、`node:crypto`の`pbkdf2Sync(…, 100000, 32, 'sha256')`で作る。

## 8. 後片付け

確認が終わったら、次を行う。

```bash
npx wrangler delete --env staging                 # ステージングのWorker
npx wrangler kv namespace delete --namespace-id <STAGING_KV_ID>
npx wrangler d1 delete studiquo-admin-staging
```

残しておく場合は、定期的に、データと秘密情報を見直す。ステージングには、個人情報や本番のデータを、入れない。

## 9. 注意

- `wrangler dev`を、`--remote`付きで実行しない。この設定のままでは、`--remote`の開発用のプレビューが、本番のKVを使う。
- ステージングでのメール送信は、Resendのテスト用宛先を使う。実在の人に、メールを送らない。
- 本番へのデプロイは、この確認とは別の工程で、明示的な承認を得て行う。

2026-10-09の出典修正版再検証: [RAG_CITATION_STAGING_RECHECK_REPORT.md](RAG_CITATION_STAGING_RECHECK_REPORT.md)。実環境76/76、終了時の無効化・削除確認済み。比較出典の適合性と実iPad確認は残る。

## 10. ステージングの目印・管理画面・プッシュ通知・課金Webhook(2026-10-22追加)

状態: **コードと設定ファイルは用意した。ステージングへは未配備。** 秘密の設定とCloudflare・Apple・RevenueCat・Slackの画面操作は、運営者が行う(下の手順)。

### 10.1 ステージングからの連絡の目印

`wrangler.jsonc`の`env.staging.vars`に`ENVIRONMENT_LABEL: "staging"`を置いた。本番(トップレベル)には置かない。これがあるとき、ステージングのWorkerが出す次のものに、`STAGING`の目印が付く。本番は何も変わらない。

| 出るもの | 目印 |
| --- | --- |
| Slackの通知(問題報告、アプリのエラー、通報、ログイン失敗の急増などのアラート。すべて`slack.ts`を通る) | 見出しの先頭に`[STAGING]`(見出しがない通知は、先頭の行に注意書き)、続けて「STAGING環境(テスト用)からの通知です。本番ではありません」、通知の一覧に出る文字も`[STAGING]`で始まる |
| プッシュ通知 | 題名の先頭に`[STAGING]` |
| メール(確認コード、新しい環境の通知、パスキーの通知) | 件名の先頭に`[STAGING]`(送信元の名前は、元から`Studiquo Staging`) |
| 管理画面(`/admin`、`/admin/announcements`) | タブの題名に`[STAGING]`、画面の上に橙色の帯「STAGING環境(本番ではありません)」 |

目印に使う値は、`staging`のような短い英数字だけ(`environment.ts`)。秘密も個人情報も付かない。`production`・`prod`・空・変な文字の値は、目印なし(本番と同じ)として扱う。

### 10.2 Slackの宛先が本番と同じかの確認(結果: このセッションからは確認できない)

- **確認できなかった理由:** Cloudflareの秘密(`wrangler secret`)は、書き込み専用で、設定した後に値を読み出せない。`wrangler secret list`で分かるのは、**名前があるか**(ステージングにも本番にも`SLACK_ISSUE_REPORT_WEBHOOK_URL`はある)だけで、宛先は分からない。Webhookの値の比較(ハッシュの比較など)も、値を読めないので、できない。値を表示・記録する方法は、禁止されているので使っていない。
- **ユーザーの確認方法(どれか1つ):**
  1. **Slackの画面で確認する(読むだけ)。** <https://api.slack.com/apps> →Studiquoの通知用のアプリ→「Incoming Webhooks」。Webhook URLごとに「どのチャンネルに投稿するか」が一覧で出る。本番用に設定したURLと、ステージング用に設定したURLが、**別の行・別のチャンネル**になっているかを見る。(URLそのものは、どこにも貼らない。)
  2. **一番確実なのは、確認せずに作り直すこと。** Slackにステージング専用のチャンネル(例: `#studiquo-staging-alerts`)を作り、そこ宛ての新しいWebhookを発行し、`npx wrangler secret put SLACK_ISSUE_REPORT_WEBHOOK_URL --env staging`で入れ替える。これで、必ず別の宛先になる。本番用の方は触らない。
  3. 配備後に、ステージングで問題報告を1件送り、`[STAGING]`の付いた投稿がどのチャンネルに出るかを見る。本番のチャンネルに出たら、2.を行う(目印が付いているので、本番の利用者の報告とは区別できる)。
- 推奨: 2.を先に行ってから、配備する。

### 10.3 ステージングで管理画面を使う(Cloudflare Access)

**コードは変更不要。** `access.ts`は、`ACCESS_TEAM_DOMAIN`と`ACCESS_AUD`が設定されていれば、その値でCloudflare Accessのログインを検証し、未設定なら、すべて401にする(安全側)。いまのステージングは未設定なので、`/api/admin/*`は全部401である(管理画面のページ自体は開けるが、数字は出ない)。

必要なもの:

| 名前 | 内容 | 本番との関係 |
| --- | --- | --- |
| Accessのアプリ | ステージングのURL用の、**別の**Access「Self-hosted」アプリ | 本番のアプリとは別に作る |
| `ACCESS_TEAM_DOMAIN` | Zero Trustのチーム名のドメイン(`<チーム名>.cloudflareaccess.com`。`https://`は付けない) | 本番と同じ値 |
| `ACCESS_AUD` | そのAccessアプリの「Application Audience (AUD) Tag」 | **本番とは別の値**。これが違うので、本番のログイン証明書は、ステージングでは通らない(逆も同じ) |
| ポリシー | あなた(管理者)のメールアドレスだけを許可する | ステージング専用に作る |

運営者の手順(Cloudflareの画面。Access for Workersの公式の説明: <https://developers.cloudflare.com/workers/configuration/cloudflare-access/>):

1. Cloudflareの管理画面→Zero Trust→Access→Applications→「Add an application」→**Self-hosted**。
2. 名前は`Studiquo Staging Admin`。Destination(保護する場所)に、次の2つを入れる。
   - ホスト: `studiquo-mcp-staging.<アカウントのサブドメイン>.workers.dev`、パス: `admin`
   - ホスト: 同じ、パス: `admin/*`
   - **`api/admin`は入れない。** `/api/admin/revenuecat-webhook`はRevenueCatのサーバーが呼ぶので、Accessのログインで止めてはいけない(止めると課金が届かない)。`/api/admin/*`は、Worker自身がAccessの証明書を検証して守る(`access.ts`)。ページを開いてログインすると付くCookieで、画面からのAPI呼び出しは通る。
   - **Workerの「Access」タブにある「Protect this Worker behind Access」(Worker全体の保護)は使わない。** アプリの通信とWebhookも止まる。
3. ポリシーは、Action: Allow、Include: Emails→あなたのメールアドレス。他の人は入れない。
4. 保存して、アプリの概要にある**Application Audience (AUD) Tag**を控える。(秘密ではないが、チャットには貼らなくてよい。)
5. 秘密として設定する(値は対話入力で。履歴に残さない):

```bash
cd mcp-server
npx wrangler secret put ACCESS_TEAM_DOMAIN --env staging
npx wrangler secret put ACCESS_AUD --env staging
```

6. もし、Zero Trustの画面が、`workers.dev`のホスト名やパスの指定を受け付けないときは、ここで止めて知らせる。代わりに、ステージング用の独自ドメイン(例: `staging-api.studiquo.app`)をWorkerに付ける案があるが、アプリの向き先とRevenueCatのURLが変わるので、判断が要る。

配備後の確認:

| 確認 | 手順 | 期待 |
| --- | --- | --- |
| ログインなしで閉じている | ログインしていないブラウザ(または`curl`)で`https://<STG>/api/admin/stats`を開く | 401 |
| 管理画面が開く | ブラウザで`https://<STG>/admin`を開く→Accessのログイン→ダッシュボード | 橙色の「STAGING環境」の帯と、数字(新しい環境なので、ほぼ0)が出る |
| **本番の証明書が通らない(必須)** | 本番の管理画面にログインした同じブラウザで、`https://<STG>/admin`を開き、その後`https://<STG>/api/admin/stats`を開く | ステージングのAccessのログインを別に求められ、ログイン前は401。すぐ通ってしまうなら、`ACCESS_AUD`に本番の値を入れてしまっている。入れ直す |
| 数字が本番でない | ユーザー数などが、本番の数字と違う | ステージングのD1のデータ |

### 10.4 プッシュ通知(APNs)

**コードは変更不要。** `push.ts`は、端末ごとの環境(`sandbox`か`production`)で、APNsのホストと鍵を切り替える。確認した内容:
- `sandbox`の端末→`api.sandbox.push.apple.com`、鍵は`APNS_SANDBOX_AUTH_KEY`と`APNS_SANDBOX_KEY_ID`(なければ`APNS_AUTH_KEY`と`APNS_KEY_ID`)。`production`の端末→`api.push.apple.com`、鍵は`APNS_PRODUCTION_*`(なければ同じ`APNS_AUTH_KEY`と`APNS_KEY_ID`)。テストで確認済み(`push.test.ts`)。
- アプリは、**Debugビルドが`sandbox`、Releaseが`production`**で端末を登録する(`FriendChatService.swift`)。Xcodeから実機に入れたDebugビルドは、`sandbox`になる。`aps-environment`も`development`(`project.yml`)で一致している。
- `APNS_TOPIC`は、`env.staging.vars`に`com.yabuko.studiquo`を設定済み(本番と同じアプリなので同じ値)。

ステージングに足りないもの:

| 名前 | 内容 | 設定場所 |
| --- | --- | --- |
| `APNS_TEAM_ID` | AppleのTeam ID(10文字。Apple Developerの「Membership details」) | 秘密(`secret put`) |
| `APNS_SANDBOX_KEY_ID` | APNsの鍵(`.p8`)のKey ID(10文字) | 秘密 |
| `APNS_SANDBOX_AUTH_KEY` | `.p8`ファイルの中身 | 秘密 |

**ステージングには、サンドボックスの鍵だけを入れる。** 本番(`production`)の鍵は入れない。TestFlightやApp Storeのアプリの端末は、ステージングを向かないので、不要。万が一、`production`の端末がステージングに登録されても、鍵がないので、送信されず、ログに`apns_configuration_missing`が出るだけ。(`APNS_AUTH_KEY`は、環境を問わない旧式の鍵なので、ステージングには入れない。入れると本番環境向けにも使われる。)

運営者の手順(Apple Developer。鍵の発行はあなたの操作):

1. Apple Developerの「Certificates, Identifiers & Profiles」→「Keys」を開く。**Appleは、APNsの鍵を2本までしか持てない。** 本番がすでに2本(`APNS_AUTH_KEY`系と`APNS_SANDBOX_*`)を使っているときは、新しく作れないので、次のどちらかにする。
   - 本番で使っているサンドボックスの鍵の`.p8`を、手元に保存してあれば、それを再利用する(鍵はWorkerごとに、別の秘密として入れる。端末のトークンは別なので、ステージングから本番の端末へは送れない)。**ただし、鍵そのものを共有するので、ステージングから鍵が漏れると、本番の送信権限も漏れる。鍵が「Sandbox限定」で作られているかをAppleの画面で確認し、限定でなければ、共有してよいか自分で判断する。**`.p8`は、再ダウンロードできない。**手元にないなら、ステージング用には作り直せない。
   - 使っていない鍵があれば取り消して、新しく作る(本番が使っている鍵を取り消すと、本番の通知が止まるので、**取り消す前に必ずWorkerで使っていないことを確認する**)。
2. 新しく作るときは、「Apple Push Notifications service (APNs)」にチェックし、環境は「Sandbox」(選べるとき)にする。`.p8`を一度だけダウンロードして、安全な場所に保存する。Key IDを控える。
3. 秘密として設定する(`.p8`は、標準入力から渡す。チャットに貼らない):

```bash
cd mcp-server
npx wrangler secret put APNS_TEAM_ID --env staging
npx wrangler secret put APNS_SANDBOX_KEY_ID --env staging
npx wrangler secret put APNS_SANDBOX_AUTH_KEY --env staging < /安全な場所/AuthKey_XXXXXXXXXX.p8
```

   (鍵とKey IDは、同時に入れ替える。片方だけ変えると、通知が失敗する。)

配備後の確認:
1. Debugビルドのアプリを、実機(iPad)に入れ、エンドポイントをステージングにする(6.1と同じ。`mcpCloudEndpoint`)。ステージング用のアカウントを2つ作ってフレンドにする。
2. 受信側のアプリの通知を許可し、送信側からメッセージを送る→受信側に、題名が`[STAGING]`で始まる通知が届く。
3. 届かないとき: `npx wrangler tail --env staging`で、`apns_configuration_missing`(鍵の設定漏れ)、APNsの応答の`reason`(`BadDeviceToken`は、環境の取り違え)を見る。

### 10.5 RevenueCatのWebhook(課金のイベントの受信)

**コードは変更不要。ただし、安全のため1つ足した:** ステージングは、RevenueCatの`PRODUCTION`(本物のお客さまの購入)のイベントを、**受け取って捨てる**(`{"received":true,"ignored":true}`を返し、DBに何も書かない)。サンドボックスのイベントだけを記録し、プランに反映する(`ALLOW_SANDBOX_PURCHASES: "true"`は元から設定済み)。Webhookの設定を間違えても、本物のお客さまの情報が、ステージングのDBに入らない。テストは`admin.test.ts`。

ステージングのURL: `https://studiquo-mcp-staging.<アカウントのサブドメイン>.workers.dev/api/admin/revenuecat-webhook`(本番のURLとは別。本番のURLは、ここに書かない)。

必要なもの:

| 名前 | 内容 |
| --- | --- |
| `REVENUECAT_WEBHOOK_SECRET`(秘密) | **本番とは別の、ステージング専用のランダムな値。** `openssl rand -base64 32`で作る。RevenueCatの「Authorization header」に入れる文字列と、`secret put`する値を、**完全に同じ**にする(`Bearer `などの接頭辞も含む)。違うとすべて401 |
| `REVENUECAT_SECRET_API_KEY`(秘密、任意) | 退会時にRevenueCat上の顧客を消すための鍵。ステージングで退会の外部削除まで試すときだけ。本番の鍵を流用せず、RevenueCatで別に作る(権限は最小に)。なければ、外部削除の予約が溜まるだけで、他の機能には影響しない |

運営者の手順(RevenueCatの画面):
1. 秘密を作って設定する:

```bash
cd mcp-server
echo "Bearer $(openssl rand -base64 32)" | pbcopy   # 画面に出さず、クリップボードに入れる(Macの場合)
npx wrangler secret put REVENUECAT_WEBHOOK_SECRET --env staging   # クリップボードの値を貼る。RevenueCatの欄にも同じ値を貼ったら、クリップボードを別のものに上書きする
```

2. RevenueCatのダッシュボード→Project settings→Integrations→Webhooks→「Add new webhook」(追加。**既存の本番のWebhookは編集しない**)。
   - Webhook URL: 上のステージングのURL
   - Authorization header value: 手順1で作った値(`Bearer …`)
   - **Environment（送るイベントの環境）: Sandbox のみ**
   - 対象のアプリ: Studiquo
3. (推奨・本番の設定の変更なので、あなたが判断する)既存の本番のWebhookの環境を **Production のみ**にする。いまの設定が「両方」だと、Debugビルドのサンドボックス購入が、本番にも届く。本番は`ALLOW_SANDBOX_PURCHASES: "false"`なのでプランには反映しないが、`revenuecat_events`に記録は残る。

テストと確認:
1. RevenueCatの「Send test event」で、ステージングのWebhookにテストイベントを送る。結果が**200**ならSecretが合っている(`401`なら、ヘッダーの値の不一致。`Bearer `の有無を見る)。
2. Debugビルド(StoreKitのサンドボックス、またはテスト用Apple ID)で、アプリをステージングに向けて、サンドボックス購入をする。管理画面の「購読者」にプランが出る、または、アプリ側のプランが変わる。
3. 本番のダッシュボードの数字(売上・購読者)が、増えていない。

### 10.6 配備の前に確認すること(未配備のため)

- [ ] `npx tsc --noEmit`・`npm test`が通る(作業の完了時点で通過済み)。
- [ ] `wrangler deploy --env staging --dry-run`の出力で、`STUDIQUO_DATA`・`ADMIN_DB`がステージングのID、`ENVIRONMENT_LABEL`が`staging`、本番のID(`e1171479…`、`fb64e302…`)が出ていない。
- [ ] **配備のときは、前回の配備(RAG有効・判定shadow)と同じ`--var`の上書きを付ける。** 設定ファイルの値は`RAG_ENABLED: "false"`などなので、付けないとRAGが無効に戻る。
- [ ] 10.2の宛先を確認(または、新しいテスト用Webhookに入れ替え)した。
- [ ] 秘密を設定した(10.3〜10.5)。名前は`npx wrangler secret list --env staging`で確認できる(値は出ない)。
- [ ] ロールバック: 設定ファイルの変更は`ENVIRONMENT_LABEL`の1行だけ。戻すときは、前の版を`wrangler rollback --env staging`、または、このブランチの前の版から再配備する。秘密は`wrangler secret delete <名前> --env staging`で消せる。本番には何も触れていない。

### 10.7 配備の後に、人が確認すること

1. ステージングで問題報告を送る→Slackに`[STAGING]`の付いた投稿が、**テスト用のチャンネルだけ**に出る。
2. 管理画面にログインできる。未ログインの`/api/admin/stats`が401。
3. Debugビルドの実機で、プッシュ通知が`[STAGING]`の題名で届く。
4. RevenueCatのテストイベントが200。サンドボックス購入がステージングにだけ反映される。
5. 本番のSlack・管理画面・RevenueCatの数字に、ステージングの痕跡が出ていない。

### 10.8 直した別件: レート制限の`namespace_id`の重複

RAG統合ブランチで、`RATE_LIMIT_RAG_INDEX/SEARCH/PDF`が、mainの`RATE_LIMIT_ATTEST_*`と同じ番号(本番`1025`〜`1027`、ステージング`2025`〜`2027`)だった。同じ番号の制限はカウンターを共有する可能性がある。RAG側を本番`1028`〜`1030`、ステージング`2028`〜`2030`に変えた(RAGは本番に未配備なので、本番のカウンターには影響しない。mainの`ATTEST`は番号を変えていない)。環境ごとに番号が重ならないことを`environment.test.ts`で検査する。**ステージングへは、次の配備で反映される。**
