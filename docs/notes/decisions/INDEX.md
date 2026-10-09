---
title: decisions 目次
date: 2026-10-08
tags: [index, adr]
---

# decisions 目次

設計判断の記録(ADR)。1判断につき1ファイルで、ファイル名は`adr-番号-内容.md`にする。各ファイルの「未記入(自分で補う)」は、docsから読み取れなかった理由の欄で、自分の記憶で埋める。

- [ADR-0001](adr-0001-swiftdata-cloudkit-source-of-truth.md): ノートの正本はSwiftData+CloudKit、Workerは同期に参加しない。同期やデータ移行を変えるときに読む
- [ADR-0002](adr-0002-ai-provider-google-only-and-consent-gate.md): AIの標準提供先をGoogle一社に限定し、同意と承認のゲートを置く。ChatGPT契約者の持ち込み利用枠は条件付きで許可(2026-10-09改定)。AI提供先やAI送信の範囲を変えるときに読む
- [ADR-0003](adr-0003-login-rate-limit-and-argon2id-queue.md): ログインの待機・混雑を、パスワード違いと区別して扱う。ログインの制限や文言を変えるときに読む
- [ADR-0004](adr-0004-complete-account-deletion.md): アカウント削除で、学習スナップショットと共同編集ノートも消す。削除の対象や、共同編集の参加者のキーを変えるときに読む

Up: [notes 目次](../INDEX.md)
