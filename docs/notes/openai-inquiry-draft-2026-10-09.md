---
title: OpenAIへの問い合わせ文(送信済み)Sign in with ChatGPT
date: 2026-10-09
revised: 2026-10-09
tags: [sent, ai, openai]
---

# OpenAIへの問い合わせ文(送信済み)

- 状態: **送信済み(2026-10-09、本人がinterest formから送信)**。返事待ち。下の「英文」は元の長い版で、フォームには字数を考えて短くまとめた版を貼った(次の節)。
- 送り先: [Sign in with ChatGPT interest form](https://openai.com/form/sign-in-with-chatgpt-interest/)。公式の[Request a client ID](https://developers.openai.com/siwc/request-client-id)ページからもリンクされている。フォームの入力欄は公開されていないので、欄に合わせて下の文を切り貼りする。
- `【 】`は埋め済み(運営者名、公開予定時期=2027-01-01、連絡先)。送る前に、フォームの欄に合わせて確認する。
- 背景: [ADR-0002](decisions/adr-0002-ai-provider-google-only-and-consent-gate.md)の改定(持ち込み利用枠)

## 公式資料で分かったこと(2026-10-09調べ。問い合わせの対象から外した)

- 枠の利用に必要な権限(スコープ)は`offline_access resource.invoke chatgpt.tokens.use.direct`で、`resource=https://api.openai.com/v1`も付ける。ログインだけなら`openid profile email`。ログインのIDトークンだけでは枠を使えない。
- 枠を使うリクエストは、利用者のアクセストークンを`Bearer`にして、Responses APIに`store: false`、`stream: true`で送る。利用者の会話や記憶には触れない。
- アクセストークンの有効期間は例で1時間。更新トークンは更新のたびに入れ替わる。
- 公開されている「枠の利用」の手順は、**オープンソースとローカルで動くアプリ向け**で、利用者の端末の`127.0.0.1`でコールバックを受ける公開クライアント(シークレットなし)。**有料・リモートで動くアプリは対象外**と明記されていて、interest formに進むよう案内されている。Studiquoはこちらに当たる。
- 枠の利用は、利用者がChatGPT側で週ごとの上限を決められ、新しい枠が増えるわけではない。対象はPlusとPro。
- 公開資料にないこと: 承認基準と期間、フォームの入力欄、未成年・学生の扱い、枠で行ったリクエストの保存期間と訓練利用、ネイティブ(モバイル)アプリの扱い、利用規約(Sign in with ChatGPT Terms)の本文。

## 実際にフォームへ入れた内容(2026-10-09)

- 機能: サインインとAIリクエストへのChatGPTプランの利用
- 会社名: Kohtaroh Yabusaki / ウェブサイト: 本番Workerの`/privacy` / 公開予定: 2027-01-01
- 製品の説明欄(質問を同封):

```
Studiquo: a study app for iPad (SwiftUI) with an AI chat feature, backend on Cloudflare Workers, own paid subscription plans. We want users with ChatGPT Plus/Pro to optionally use their own plan allowance in the AI chat. Target release January 1, 2027; the ChatGPT plan feature would launch only after OpenAI's approval.
Questions: (1) Our app is paid and has a hosted backend. Can our backend act as the OAuth client and hold the access/refresh tokens server-side only, never on the device? (2) What are the approval criteria and timeline? Our app is not released yet; can a pre-release app get a test client ID for development, and can you share the applicable terms? (3) Does the plan allowance cover general text/image Responses API requests, such as a study-assistant chat (help center says "Codex/ChatGPT work usage")? Which models, and what signal do we get when a cap is reached? (4) Our users are mainly students, some under 18. Are there conditions? (5) How are requests made with a user's plan retained and used, including for training? Contact: yabukohtaroh@gmail.com
```

(2)は、公開前のアプリがテスト用のクライアントIDをもらえるかを足した版。以下の英文(元の長い版)の(2)とは文言が違う。

## 英文(元の長い版)

Subject: Inquiry about ChatGPT plan usage for a paid iPad app with a hosted backend

Hello,

I am the developer of Studiquo, a study app for iPad (SwiftUI) with an AI chat feature. The app talks to a backend on Cloudflare Workers, which calls AI providers on behalf of signed-in users. Operator: Kohtaroh Yabusaki (individual developer), Japan. Target release of the app: January 1, 2027. The ChatGPT plan usage feature would be released only after your approval. The app has its own paid subscription plans.

We would like to let users who have a ChatGPT Plus or Pro plan use their own plan allowance in our AI chat, as an optional, opt-in feature that is off by default, with a separate consent screen. Our own plans would remain for everyone else.

We read the developer documentation. The plan-usage documentation covers open-source and locally hosted apps, and says paid or remotely hosted apps should use the interest form, so we are applying through it. We have the following questions:

1. Integration path. For a paid iPad app with a hosted backend, which client type and redirect flow do you recommend? In particular, can our backend act as the OAuth client (receiving the callback and holding the access and refresh tokens server-side, never on the device), with the iPad app opening the sign-in in an in-app browser session? Or must tokens live on the user's device?
2. Approval. What are the criteria and expected timeline? Are identity sign-in and plan usage approved separately? Could you share the Sign in with ChatGPT Terms that would apply to us?
3. Scope of the allowance. Help Center describes plan usage as "Codex / ChatGPT work usage included in your plan". Does the allowance cover general text and image requests to the Responses API, such as a study-assistant chat? Which models are available, and what error or signal do we receive when a user's cap or allowance is reached, so that we can show a clear message?
4. Minors and students. Our users are mainly students, and some may be under 18. Are there age or education-related conditions for apps using plan usage, and are requests from accounts with ChatGPT's teen protections treated differently?
5. Data handling. How are requests made with a user's plan retained and used, including for model training, compared with API traffic? We will disclose this to users on our consent screen.

For reference, we would store tokens only on our backend, let users disconnect at any time, and delete the tokens when an account is deleted.

Contact: yabukohtaroh@gmail.com

Thank you.

## 日本語の要点(確認用)

Studiquo(有料プランのあるiPad向け学習アプリ、バックエンドはWorkers)で、ChatGPTのPlus/Pro契約者が自分の枠を任意で使えるようにしたい。公開資料の枠の利用はオープンソース・ローカルアプリ向けで、有料・リモートのアプリはinterest formとされているので、そちらから申請する。聞きたいのは5点。

1. 経路: バックエンドをOAuthクライアントにして、トークンをサーバー側だけに置く形でよいか。端末に置く必要があるか。
2. 承認: 基準と期間。ログインと枠の利用は別承認か。適用される利用規約(Sign in with ChatGPT Terms)をもらえるか。
3. 枠の範囲: 「Codex/ChatGPTのwork usage」とあるが、学習アシスタントのチャットのような一般的なテキスト・画像のResponses APIにも使えるか。使えるモデル。枠や上限に達したときの合図。
4. 未成年・学生: 条件の有無。ChatGPTのティーン保護が掛かったアカウントの扱い。
5. データの扱い: 枠で行ったリクエストの保存期間と訓練利用。

## 返事が来たら(返事がなければ、数週間後に様子を見て、再送などを検討する)

- 回答をADR-0002の前提条件1に反映する。
- Notionのカード「AIチャットでChatGPT/Claudeの利用枠を共有して使えるようにする」の「次の一手」を更新する。
