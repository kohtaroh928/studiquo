---
title: OpenAIへの問い合わせ文(下書き)Sign in with ChatGPT
date: 2026-10-09
tags: [draft, ai, openai]
---

# OpenAIへの問い合わせ文(下書き)

- 状態: 下書き。**未送信**。送信は本人が行う。
- 送り先: OpenAIの「Request a client ID」ページまたはinterest form(https://developers.openai.com/siwc/quickstart からリンクされている)
- 送る前に埋める: `【 】`の箇所(運営者名、連絡先、公開予定時期など)。実際の事実だけを書く。
- 背景: [ADR-0002](decisions/adr-0002-ai-provider-google-only-and-consent-gate.md)の改定(持ち込み利用枠)

## 英文(送信用)

Subject: Inquiry about Sign in with ChatGPT and ChatGPT plan usage for a native iPad app

Hello,

I am the developer of Studiquo, a study app for iPad (SwiftUI) with an AI chat feature. The app talks to a backend on Cloudflare Workers, which calls AI providers on behalf of signed-in users. Operator: 【運営者名・所在地】. Planned release: 【公開予定時期】.

We would like to let users who have a ChatGPT Plus or Pro plan use their own plan allowance in our AI chat, as an optional, opt-in feature. Our own subscription plans would remain for everyone else. We would not use the feature to replace our plans, and the feature would be off by default with a separate, versioned consent screen.

We read the developer documentation and would like to confirm the following before applying:

1. Native apps. The documentation lists websites, ChatGPT plugins and open-source apps. Is ChatGPT plan usage available for a closed-source, native iPad app whose backend is a hosted server? If so, which flow do you recommend (for example, a web-based authorization flow handled by our backend, with the iPad app opening it in an in-app browser session)?
2. Eligibility and review. What are the criteria and the expected timeline for approval of sign-in and of plan usage? Are the two approved separately?
3. Minors and students. Our users are mainly students, and some may be under 18. Are there age or education-related conditions for apps using Sign in with ChatGPT or plan usage?
4. API. We currently use the Chat Completions API. Plan usage appears to apply to Responses API requests. Is the Responses API required, and which scopes would we need?
5. Data handling. How are requests made with a user's plan retained and used (including for model training) compared with API traffic? We will disclose this to users on our consent screen.
6. Token handling. We plan to store the user's OAuth tokens only on our backend (never on the device), allow users to disconnect at any time, and delete the tokens when an account is deleted. Is there anything else you require?

Contact: 【メールアドレス】

Thank you.

## 日本語の要点(確認用)

Studiquo(iPad向け学習アプリ、AIチャットあり)で、ChatGPTのPlus/Pro契約者が自分の枠を任意で使えるようにしたい。Studiquoのプラン制は残す。次の6点を確認したい。

1. ネイティブのiPadアプリ(バックエンドはWorkers)で枠を使えるか。使えるなら推奨の流れは何か。
2. 承認の基準と期間。ログインと枠の利用は別々に承認されるか。
3. 学生・未成年の利用者がいる場合の条件。
4. 今はChat Completions APIを使っている。枠の利用はResponses APIが必須か。必要なスコープは何か。
5. 枠で行ったリクエストの保存期間と訓練利用。API経由との違い。
6. トークンはバックエンドだけに保存し、解除とアカウント削除で消す計画。ほかに要件はあるか。

## 返事が来たら

- 回答をADR-0002の前提条件1に反映する。
- Notionのカード「AIチャットでChatGPT/Claudeの利用枠を共有して使えるようにする」の「次の一手」を更新する。
