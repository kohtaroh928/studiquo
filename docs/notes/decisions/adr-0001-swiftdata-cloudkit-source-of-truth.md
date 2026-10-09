---
title: ADR-0001 ノートの正本はSwiftData+CloudKit、Workerは同期に参加しない
date: 2026-10-08
tags: [adr, architecture, cloudkit, swiftdata]
status: 採用済み(docsの記述から起こした。理由の補足は要記入)
---

# ADR-0001 ノートの正本はSwiftData+CloudKit、Workerは同期に参加しない

## 決定

- 学習コンテンツ(ノート、カード、文書など)の正本は、iPad側のSwiftDataに置く。
- Apple IDの端末間同期はCloudKitが担う。
- Cloudflare Workerは、認証、AIプロキシ、友達・共同編集、MCP連携、課金状態、通知、運営情報を担当し、ノートの同期経路には参加しない。
- MCPに公開される学習データは、アプリが明示的にWorkerへ同期したスナップショットであり、CloudKitのストア自体ではない。

## 根拠(docsに書かれていること)

- CloudKit障害とWorker障害を別の障害領域に分けられる。
- 現行アプリは端末ごとの単一ライブラリで、Studiquoのログインアカウントごとの別ストアではない。Apple IDのCloudKitとStudiquoのログインidentityは別物である。
- ログアウトや別アカウントへの切替を、データ移行やCloudKit所有者変更と同一視しない。

## 結果として守ること

- ブランチ`feature/icloud-sync-optin`(マージ済み)のコミットに「アカウント削除後も同期設定を残す」とある。同期を利用者の選択制にしたかどうかは、ブランチ名からの推測なので、コードで確認する。
- ノートの保存形式を変えるときは、移行の検証を別に行う([DATA_AND_MIGRATIONS](../../DATA_AND_MIGRATIONS.md))。

## 未記入(自分で補う)

- CloudKitを選んだ理由(代替案と、採らなかった理由)。
- 認証をアカウントベースにしても、ノート同期はApple ID側に残す、という方針の確認。

Related: [ARCHITECTURE](../../ARCHITECTURE.md) の2章・6.1節、[DATA_AND_MIGRATIONS](../../DATA_AND_MIGRATIONS.md) の2章、[cloudkit-verification](../../cloudkit-verification.md)、[未決事項](../open-decisions.md)
