# リリース記録: Worker更新 — 入口の独自ドメイン化・サーバーAPIの堅牢化(2026-10-17)

状態: **本番へ配備済み。経過観察中。** 作成日: 2026-10-17
根拠: [RELEASE_CHECKLIST.md](../RELEASE_CHECKLIST.md)。この記録は、実際に行った配備と確認だけを書く。未確認のことは、未確認と書く。
前の記録: [2026-10-08の下書き](2026-10-08-worker-update.md)(内容は古い。対象の変更は、この記録の配備に含まれる)。

## 1. 配備した内容

本番Worker(`studiquo-mcp`)に、次の順で配備した。時刻は、日本時間の2026-10-17。

| 順 | 版 | 対象commit(`main`) | 内容 |
| --- | --- | --- | --- |
| 1 | `9835f85f` | `95a02c3` | サーバーAPIの小さな堅牢化(共同編集の招待を友達限定、AIの処理順とレート制限、`/mcp`・同期の回数制限、保存領域の上限、HTMLのヘッダ、エラー本文の非表示)。あわせて、それまで本番に出ていなかった変更(OpenAIへの切替、AIのクレジット制、スナップショット暗号化、退会・再登録の修正)が入った |
| 2 | (秘密情報の追加) | — | `REVENUECAT_SECRET_API_KEY`(退会時のRevenueCat側の削除に使う) |
| 3 | `dc5740e3` | `f82852d` | `ARGON2_WRITE`を`"true"`にした(パスワードのhash移行の2段階目) |
| 4 | `aa9351ad` | `bf6eb45` | 接続先を独自ドメイン`api.studiquo.app`に切り替え(PasskeyのRP IDを含む) |
| 5 | `c65dd84e` | `3044cd4` | 本番の`workers.dev`とプレビューURLを無効にした |
| 6 | `3e5942a6` | `f8f0d83` | 優先度の低い指摘の修正(IPv6を/64で数える、友達コードを10文字に、リクエストの自動ログ行の停止、管理APIの他サイトからの書き込みの拒否、運用スイッチ、OAuthの細部、ログインの絶対期限) |

ステージング(`studiquo-mcp-staging`)には、1の内容を先に配備し、実機で確認した(版`34d1633b`)。4・5・6は、ステージングを経由せず、本番へ直接配備した。

## 2. 配備前の確認

| 確認 | 結果 |
| --- | --- |
| 自動テスト(Worker) | 各配備の直前に全件成功(最終: 872件)。1件、実行ごとに通ったり落ちたりするテストがあった(`snapshot-crypto`の改ざん検出)。原因はテストの書き方(base64の末尾の文字だけを変えていた)で、テストを直した(40回の実行で、直す前は9回失敗、直したあとは0回) |
| 秘密情報の検査 | マージ前に、gitleaksとtrufflehogを通した。いずれも0件 |
| 予行演習 | `wrangler deploy --dry-run`で、保存先が本番用(KV`e1171479…`、D1`studiquo-admin`)であることを毎回確認した |
| D1のmigration | 本番は、全て適用済み(`wrangler d1 migrations list`で確認)。今回の配備で、新しいmigrationはない |

## 3. 配備後の確認

| 確認 | 結果 |
| --- | --- |
| `/health`、認証なしの`/api/plan`(401)、招待ページのヘッダ、アプリ関連づけファイル | 各配備のあとに、`curl`で確認した |
| `workers.dev`(本番) | 404(閉じている)。ステージングは200 |
| WAFのレート制限 | 400件の同時リクエストで、206件が通り194件が429になり、待つと元に戻った |
| 管理APIへの他サイトからの書き込み | `Origin: https://evil.example`で403 |
| 実機(iPad) | サインイン、同期、招待リンク、Passkeyの登録、パスワードのログイン(`ARGON2_WRITE`が`"true"`のあと)。利用者の報告で、問題なし。確認した項目の細部は、記録していない |

未確認: AI(本番は`AI_PROVIDER_APPROVED="false"`のため、503のまま)。実際の利用者の規模での負荷。リクエストの自動ログ行の停止が、Cloudflareの画面で反映されたかの目視。

## 4. 本番の設定(この時点)

- 入口: `api.studiquo.app`(Workerのカスタムドメイン)だけ。ゾーン`studiquo.app`のWAFに、レート制限ルール`api-per-ip-limit`(IPごと、10秒に200件、ブロック10秒)。
- 変数: `AI_PROVIDER_APPROVED="false"`、`ARGON2_WRITE="true"`、`PRIVACY_RETENTION_ENABLED="false"`、`ALLOW_SANDBOX_PURCHASES="false"`。運用スイッチ`MAINTENANCE_MODE`・`MIN_APP_BUILD`・`SESSION_MAX_DAYS`は、未設定(無効または既定)。
- 秘密情報(名前だけ確認): `SNAPSHOT_ENCRYPTION_KEY`、`RESEND_API_KEY`、`RESEND_FROM_EMAIL`、`REVENUECAT_SECRET_API_KEY`、`REVENUECAT_WEBHOOK_SECRET`、`OPENAI_API_KEY`、APNs、Cloudflare Access、Slack、`CSRF_SECRET`。

## 5. 切戻しと、戻してはいけない操作

- `wrangler rollback`で戻せるのは、版`9835f85f`以降の間だけ。それ以前の版は、Argon2idで保存されたパスワードを読めないので、**戻してはいけない**。
- 独自ドメインを変えると、登録済みのPasskeyが使えなくなる(RP IDがドメインに結びつく)。Passkeyを持つアカウントはパスワードで入れず、復旧に48時間かかる([RUNBOOK](../RUNBOOK.md)のRB-13)。
- `workers.dev`を、本番で再び有効にしない(WAFの外から入られる)。

## 6. 公開後の確認と、残っていること

- 数日、Cloudflareのセキュリティイベントとログ(429・5xx)を見る。共用IPで正しい利用者が止まる報告があれば、WAFの上限を上げる。
- 設計の見直しを伴う、残りの指摘は、運営のタスク管理(Notionの「Studiquo タスク」)で管理する。公開リポジトリのため、詳細はここに書かない。
- 「提出済み」「公開済み」「公開後確認済み」(App Store)は、このWorkerの配備とは別の状態で、まだ該当しない。
