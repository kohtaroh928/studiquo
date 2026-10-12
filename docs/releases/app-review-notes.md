# App Reviewのメモ(貼り付け用)

App Store Connect → 1.0 の「App Review」→「メモ」に貼る。`[PASSWORD]`は、審査用アカウントの実際のパスワードに差し替える(このファイルには書かない)。
審査用アカウントは、`yabukohtaroh+appreview@gmail.com`(本番)。4,000文字以内。

```
Thank you for reviewing Studiquo. / Studiquoの審査をありがとうございます。

[HOW TO SIGN IN / ログイン方法]
Please sign in with the demo account below. Do not use "Create account" — new registrations send a verification code by email that we cannot deliver to you.
下のデモアカウントでログインしてください。「アカウント作成」は使わないでください(新規登録は、メールで確認コードが届くため、審査担当者には届きません)。
  Email / メール:    yabukohtaroh+appreview@gmail.com
  Password / パスワード: [PASSWORD]
Choose "Sign in with email" (メールでサインイン), then enter the email and password. No verification code is needed for an existing account. Sign in with Apple and Google are also available.
「メールでサインイン」を選び、メールとパスワードを入力します。既存のアカウントなので、確認コードは不要です。Appleでサインイン、Googleにも対応しています。

[APP OVERVIEW / アプリの概要]
Studiquo is an iPad app for handwritten notes and PDFs, with AI help for studying and sharing with friends. Japan only; the interface is Japanese.
Studiquoは、手書きノートとPDF、学習のためのAI、友達との共有を備えたiPadアプリです。日本のみで配信し、画面は日本語です。

[SUBSCRIPTIONS / サブスクリプション]
Open the "その他" (Settings) tab, then "プランとお支払い" (Plans & Payment). Standard (yearly, with a 7-day free trial for new subscribers), Plus (monthly / yearly) and Pro (monthly / yearly) are auto-renewable subscriptions in one group, "Studiquo Plans". Restore purchases, Terms of Use and Privacy Policy are on the same screen. Please test with your sandbox account.
「その他」タブ →「プランとお支払い」を開きます。Standard(年額、新規は7日間無料)、Plus(月額・年額)、Pro(月額・年額)は、グループ「Studiquo Plans」の自動更新サブスクです。購入の復元、利用規約、プライバシーポリシーも、同じ画面にあります。Sandboxのアカウントでお試しください。

[AI FEATURES / AI機能]
The AI features (chat, marking, next-day review) use OpenAI (ChatGPT models) through our own server. On first use the app asks the user to confirm their age band (18+, 13-17 with a guardian's consent, or under 13) and to allow sending content to OpenAI. Users under 13 cannot use the AI features. Please choose "18+" and allow it to try the AI chat. User text is also screened with OpenAI's moderation endpoint.
AI機能(チャット・添削・翌日復習)は、自社サーバー経由で OpenAI(ChatGPTのモデル)を使います。初回に、年齢区分(18歳以上/13〜17歳で保護者の同意あり/13歳未満)の確認と、OpenAIへの送信の許可を求めます。13歳未満はAI機能を使えません。AIチャットを試すには、「18歳以上」を選んで許可してください。送信する文章は、OpenAIのモデレーションでも確認します。

[ACCOUNT DELETION / アカウント削除]
Settings (その他) > アカウント > アカウントを削除.
「その他」→「アカウント」→「アカウントを削除」。

[SERVER / サーバー]
The backend runs on Cloudflare Workers and is live during review.
バックエンドは Cloudflare Workers で稼働しており、審査の間も動いています。

Contact / 連絡先: yabukohtaroh@gmail.com
```

## 提出前に確認すること

- 審査で、AIを動かすには、提出前に、本番の`AI_PROVIDER_APPROVED`を`true`にしておく(1.0は未公開で、旧版アプリはないので、先に有効にして問題ない)。
- ペイウォールの状態(有効にして提出するか)で、「プランとお支払い」の表示が変わる。メモの説明と合わせる。
- ログイン画面のボタン名(「メールでサインイン」など)が、実際の画面と一致しているか確認する。
