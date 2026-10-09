---
title: 未決事項と技術的な課題
date: 2026-10-08
tags: [open-decisions, release, security, tech-debt]
---

# 未決事項と技術的な課題

2026-10-08時点のスナップショット。正本はそれぞれの出典のdocsで、ここは「人が決めること」を1枚で見るための索引にする。決めたら、該当のADRを作り、この表から外す。

## 公開前に人間が決める項目

| 項目 | 状態 | 出典 |
| --- | --- | --- |
| Geminiの対象年齢・学生向け提供可否・契約・訓練利用・保存期間の確認 | 未完了。確認まで`AI_PROVIDER_APPROVED=false`を維持 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 6、[ADR-0002](decisions/adr-0002-ai-provider-google-only-and-consent-gate.md) |
| 退会後の再登録の方針(課金顧客の世代管理、旧課金Webhookとの区別、D1削除済み識別子の保持期限) | 未確定 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 5、[SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章 P0-4 |
| Sign in with Appleの認可取消し、共同編集データの削除範囲、CloudKit同期の削除の実機確認 | 未確認 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 7 |
| Privacy ManifestとApp Store Connectのプライバシー申告の照合 | 未実施 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 8 |
| 本番D1のバックアップ、migration `0005_privacy_retention.sql`のテスト環境検証 → 本番migration → Worker → アプリの順の更新 | 本番反映は未実施 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 1 |
| `REVENUECAT_SECRET_API_KEY`の設定と、テスト用顧客での削除確認 | 未実施 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 2 |
| `PRIVACY_RETENTION_ENABLED`をtrueにする時期と、未処理の警告の監視・通知 | 未実施 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 3, 4 |
| 旧Slack投稿と、所有者を復元できない旧問題報告の整理 | 運営対応が必要 | [PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md) 9 |

## 運用・環境

| 項目 | 状態 | 出典 |
| --- | --- | --- |
| ステージングでの確認(ステージング用アカウントで運営者が実施) | 未実施。Worker・KV・D1の後片付けも未実施 | [STAGING_SETUP](../STAGING_SETUP.md) |
| `RESEND_FROM_EMAIL`が本番で設定されているか | 未確認。未設定だと共通の送信元になり、自分のドメイン以外へ届かない(ステージングで422を確認)。ダッシュボードで確認し、自分のドメインを認証する | [SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章 |
| ログイン関連のSlackアラートの閾値の見直し | 未実施。`SLACK_ISSUE_REPORT_WEBHOOK_URL`が未設定だとアラートは出ない | [RUNBOOK](../RUNBOOK.md) |
| `ARGON2_WRITE=true`の本番相当の環境での確認、応答時間の均一化、通知メールとSlackの実送信 | 未実施 | [SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章 |
| ログイン成功の経路が約3〜6秒かかる(ステージングの実測) | 原因は`mintSession`のKV操作が順番に3回あること。最初の2つの読み取りは並列にできる | [SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章 |

## 認証方針の確認(自分の以前の方針と、現状のずれ)

以前は、端末ごとの匿名トークン方式からアカウントベース認証へ移行し、Sign in with Appleへの置き換えとリフレッシュトークン方式の採用を検討する方針だった。現在のdocsでは、メールとパスワード、Sign in with Apple、Google Sign-In、Passkeyが併存している。

- 決める: 認証手段を併存のままにするか、Appleへ絞るか。リフレッシュトークンを採るか。決めたらADRにする。
- 出典: [ARCHITECTURE](../ARCHITECTURE.md) 6.2節、[SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 認証節

## 認証まわりの改善候補

- 保存する識別子の塩なしSHA-256を、サーバー秘密鍵によるHMACへ移行する。
- Argon2id移行後にPBKDF2のレコードが残らなくなったら、`local-auth.js`のPBKDF2のダミー計算と旧レコードの分岐を外す。
- App Attest(端末とアプリの証明)の導入を、CAPTCHAに代わる対策として検討する。

出典: [SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章

## 技術的な課題

[ARCHITECTURE](../ARCHITECTURE.md) の11章にある内容と、[SECURITY_AND_PRIVACY](../SECURITY_AND_PRIVACY.md) 19章のP1の項目をまとめた。着手の優先度は自分で付ける。

- `ContentView.swift`と`StudiquoApp.swift`に複数の責務が集まっている。
- Product ID、RevenueCat Entitlement、Workerのプラン対応が手動同期である。
- `RevenueCatConfiguration.publicAPIKey`がplaceholderのまま。出荷前に公開SDKキーを設定する。
- Workerの開発用KVが本番namespaceと共有されている。
- `ClaudeDirectProvider`とWorker経由のAIの2経路があり、機能差と秘密情報の責任範囲が異なる。
- API契約がSwift構造体、Zod schema、ハンドラーに分散している。
- `StudiquoApp.swift`の一部の起動ログが`String(describing: error)`をpublic privacyで記録している。
- `PrivacyPolicyView`と`mcp-server/src/legal.js`を手作業で重複管理している。

Related: [ブランチ対応表](branches.md)、[ADR-0001](decisions/adr-0001-swiftdata-cloudkit-source-of-truth.md)、[ADR-0002](decisions/adr-0002-ai-provider-google-only-and-consent-gate.md)、[ADR-0003](decisions/adr-0003-login-rate-limit-and-argon2id-queue.md)、[RELEASE_CHECKLIST](../RELEASE_CHECKLIST.md)
