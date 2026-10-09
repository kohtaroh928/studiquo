---
title: ADR-0002 AIの提供先をGoogle一社に限定し、同意と承認のゲートを置く
date: 2026-10-08
tags: [adr, ai, privacy, security]
status: 実装済み・公開前の承認が未完了
---

# ADR-0002 AIの提供先をGoogle一社に限定し、同意と承認のゲートを置く

## 決定

- AIの初期提供先をGoogleのみにする。旧モデル定義は内部に残るが、アプリの選択肢と公開API境界で制限し、direct Anthropic経路は拒否する。
- AIへ送る前に、送信内容を説明し、バージョン付きの許可を必須にする。拒否しても、通常のノート機能は使える。
- 開いているノートを自動送信しない。送るのは、質問・会話履歴と、利用者が選んだ資料だけにする。
- 翌日AI復習と自動診断は初期OFFにする。旧版の設定を新しい許可へ自動移行しない。
- 提供条件の確認が済むまで、サーバー側の`AI_PROVIDER_APPROVED=false`を維持し、AIを停止する。

## 根拠(docsに書かれていること)

- 学生・未成年者への提供可否、契約、モデル訓練利用の有無、保存期間が未確認である。
- 旧アプリには新しい同意ヘッダーがないため、新Workerは旧アプリからのAI送信を拒否する。通常の学習機能は継続できる。
- 異常時は、承認フラグをfalseに戻せば止められる。

## 未記入(自分で補う)

- Googleを一社目に選んだ理由(Anthropic、OpenAIを後回しにした理由)。
- 他の提供先を追加するときの条件。

## 関連する未決事項

公開前に、Geminiの対象年齢・学生向け提供可否・契約・訓練利用・保存期間を確認する。詳細は[未決事項](../open-decisions.md)の「公開前に人間が決める項目」を参照。

Related: [SECURITY_AND_PRIVACY](../../SECURITY_AND_PRIVACY.md) の分類表・AI節、[PRIVACY_RELEASE_CHECKLIST](../../PRIVACY_RELEASE_CHECKLIST.md)、[ARCHITECTURE](../../ARCHITECTURE.md) の6.3節
