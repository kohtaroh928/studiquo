# ステージングを本番と同じ機能で分離する手順

## 目的

`studiquo` と `studiquo-staging` は同じソースコード、同じ機能、同じリリース番号から作る。違うのは接続先と保存先だけである。ステージングの操作・通知・課金テスト・同期データが本番の利用者や本番データに混ざらないことを目的とする。

`studiquo-staging` は新しい画面や試作版ではない。既存の Xcode スキームであり、`Staging` ビルド設定により別アプリとして端末へ入る。表示名は「studiquo Staging」、bundle ID は `com.yabuko.studiquo.staging` とする。

## リポジトリで固定した境界

| 対象 | 本番 | ステージング |
|---|---|---|
| iPad アプリ | `com.yabuko.studiquo` | `com.yabuko.studiquo.staging` |
| Worker | `api.studiquo.app` | `staging-api.studiquo.app` |
| Keychain・端末設定・RAG状態 | 通常の名前空間 | `.staging` を付けた名前空間 |
| SwiftData / CloudKit | `iCloud.com.yabuko.studiquo` | `iCloud.com.yabuko.studiquo.staging` |
| 共有シート用 App Group | `group.com.yabuko.studiquo.share` | `group.com.yabuko.studiquo.staging.share` |
| APNs topic | `com.yabuko.studiquo` | `com.yabuko.studiquo.staging` |
| パスキー RP / AASA | `api.studiquo.app` / 本番 App ID | `staging-api.studiquo.app` / staging App ID |
| フレンド招待 URL | `https://api.studiquo.app/invite` | `https://staging-api.studiquo.app/invite` |
| Apple / Google 認証 | 本番 OAuth client | staging 専用 OAuth client |
| RevenueCat | 本番 project | staging 専用 project と webhook secret |
| Worker KV・D1・DO・Vectorize・制限番号 | 本番 resources | 既存の staging resources |

Worker はパスキー、Apple ID、Google ID token の対象を環境変数から決める。本番向け token を staging Worker が受け入れる設定にはしない。

## 外部サービスで一度だけ行う設定

以下が済むまでは、ステージングを「本番と同じ機能が確認できる環境」とは扱わない。未設定の機能は無効化して代替するのではなく、専用の設定を作ってから有効にする。

1. Apple Developer で `com.yabuko.studiquo.staging` と `com.yabuko.studiquo.staging.share` を登録する。Sign in with Apple、Push Notifications、Associated Domains、CloudKit、App Groups を有効化する。
2. staging 専用の CloudKit container `iCloud.com.yabuko.studiquo.staging` と App Group `group.com.yabuko.studiquo.staging.share` を作り、両 target に関連付ける。CloudKit schema は本番と同じ状態にする。
3. `mcp-server/wrangler.jsonc` の staging Custom Domain を含めて staging Worker を配備する。Cloudflare が `staging-api.studiquo.app` の DNS と TLS を作成する。既存の同名 CNAME は作成前に取り除く。TLS が有効になった後、`/.well-known/apple-app-site-association` が staging App ID だけを返すことを確認する。`workers.dev` は無効化し、iOS の WebAuthn associated domain に使わない。
4. staging Worker に `PASSKEY_RP_ID`、`PASSKEY_ORIGIN`、`PASSKEY_APP_ID`、`APPLE_OAUTH_CLIENT_ID` を staging 値どおりに設定して配備する。
5. Google Cloud で staging bundle ID 用の iOS client と staging 専用の server client を作る。iOS client ID、server client ID、reverse client ID を `Configuration/Staging.local.xcconfig` に設定する。server client ID は staging Worker の `GOOGLE_OAUTH_SERVER_CLIENT_ID` にも設定する。空のままでは staging Worker は Google sign-in を拒否する。
6. RevenueCat に staging project / app を作る。公開 SDK key は `Configuration/Staging.local.xcconfig`、secret API key と webhook secret は staging Worker の secret に設定する。Webhook URL は staging Worker にする。
7. staging bundle ID 用の APNs credential と topic を用意し、staging Worker の APNs secrets にだけ設定する。通知本文と Slack 通知には既存の `Staging` 目印を残す。
8. staging 用に独立した `TOKEN_SIGNING_KEY`、`CSRF_SECRET`、snapshot encryption key、Resend / Slack / OpenAI 等の必要な secret を設定する。本番の secret はコピーしない。
9. `RAG_ENABLED`、AI、課金、App Attest などの feature flag を、本番と同じ値にそろえる。ただし RAG の意味判定は、固定評価の承認条件を満たすまで両環境で `off` のままにする。

公開 SDK key と OAuth client ID は secret ではないが、リポジトリに本番と staging を混在させない。`Configuration/Staging.xcconfig` は雛形としてコミットし、実値だけを `Configuration/Staging.local.xcconfig` に書く。このローカルファイルはコミットしない。

## 配備前の確認

1. `xcodegen generate` 後、Xcode で既存の `studiquo-staging` を選ぶ。Run は `Staging`、本番の `studiquo` は Debug、archive は Release になっていることを確認する。
2. 端末に「studiquo」と「studiquo Staging」が同時に存在し、互いのログイン状態・資料・通知トークンを共有しないことを確認する。
3. `wrangler deploy --env staging --dry-run` で KV、D1、Vectorize、DO、rate-limit がすべて staging resource を指すことを確認する。
4. staging の AASA、Apple / Google sign-in、パスキー、CloudKit同期、共有シート、APNs、RevenueCat sandbox purchase / webhook、Slack、管理画面、RAGを実機で確認する。
5. staging Worker のログに staging marker があり、本番 URL・本番 D1 / KV の ID・本番 Slack 宛先が現れないことを確認する。

## ロールバック

ステージングだけに不具合があれば、staging Worker route を外すか staging Worker を直前版へ戻す。ステージング app を端末から削除しても本番 app と本番 CloudKit container には影響しない。本番の Worker、secret、DNS route、CloudKit container、RevenueCat project はこの手順では変更しない。
