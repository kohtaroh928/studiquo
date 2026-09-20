import { securityHeaders } from "./http.js";

// Publicly served legal pages (no bearer token required) — registered in
// app.js alongside /health and the Apple app-site-association file, before
// the /api/ bearer-token gate, since App Store Connect, Sign in with Apple's
// configuration, and a user opening the link from Settings all need this
// reachable with no auth.
//
// TODO before shipping: replace CONTACT_EMAIL below with a real, monitored
// address, and PUBLISHED_DATE with the date this is actually published —
// both are placeholders and must not go live unfilled.
const CONTACT_EMAIL = "【お問い合わせ用メールアドレスを記載してください】";
const PUBLISHED_DATE = "【公開日を記載してください】";

// Kept in sync by hand with PrivacyPolicyView's body text in
// ContentView.swift — the in-app sheet and this hosted page are two
// different renderings of the same policy, not two independent documents.
// Whoever edits the wording in one place should mirror it in the other.
function privacyPolicyHTML() {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>studiquo プライバシーポリシー</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; line-height: 1.8; max-width: 680px; margin: 0 auto; padding: 32px 20px 80px; color: #1c1c1e; }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.1em; margin-top: 2em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
  .updated { color: #666; font-size: 0.9em; }
  ul { padding-left: 1.4em; }
</style>
</head>
<body>
<h1>studiquo プライバシーポリシー</h1>
<p class="updated">最終更新日: ${PUBLISHED_DATE}</p>

<p>本ポリシーは、学習アプリ「studiquo」(以下「本アプリ」)が、利用者の情報をどのように取り扱うかを説明するものです。</p>

<h2>収集する情報とその利用目的</h2>
<ul>
  <li><strong>アカウント情報</strong>:サインイン方法に応じて、メールアドレス、Apple IDまたはGoogleアカウントの識別子、氏名の一部を取得します。本アプリの利用を可能にするために使用します。</li>
  <li><strong>プロフィール情報</strong>:設定した表示名。友達機能・共同編集機能で他の利用者に表示するために使用します。</li>
  <li><strong>学習コンテンツ</strong>:ノート、暗記帳、文書、スライドなど、利用者が作成したコンテンツ。本アプリの基本機能を提供するために保存します。</li>
  <li><strong>友達・チャット機能に関する情報</strong>:友達コード、友達関係、チャットメッセージ、送信した添付ファイル。友達同士のコミュニケーション機能を提供するために保存します。</li>
  <li><strong>利用状況</strong>:学習時間の記録、各機能の利用回数。学習記録機能・利用制限の管理のために使用します。</li>
  <li><strong>AI機能利用時に送信する内容</strong>:AIトーク・添削・翌日復習・AI学習計画などの機能を使うと、質問文、ノートの内容、答案の画像などが外部のAIサービスに送信されます。詳しくは次の項目をご覧ください。</li>
</ul>

<h2>第三者サービスとの連携</h2>
<ul>
  <li><strong>Sign in with Apple / Google Sign-In</strong>:アカウント作成・ログインのために使用します。</li>
  <li><strong>Google Gemini</strong>:AIトーク・添削・翌日復習・AI学習計画機能で、既定の生成AIとして使用します。これらの機能を使うたびに、上記の内容がGoogleに送信されます。</li>
  <li><strong>Anthropic Claude</strong>:利用者が自分自身のAnthropic APIキーを設定した場合に限り、同様の内容がAnthropicにも送信されます。APIキーを設定しない限り、この連携は行われません。</li>
  <li><strong>Cloudflare</strong>:本アプリのサーバーインフラとして使用しており、上記のアカウント情報・学習コンテンツ・チャット内容の保管場所です。</li>
  <li><strong>Apple iCloud</strong>:一部のデータは、CloudKitを通じて利用者ご自身のiCloudアカウント内で端末間同期されます。</li>
</ul>

<h2>広告・トラッキングについて</h2>
<p>本アプリは広告配信を行っておらず、第三者による行動トラッキングも行っていません。</p>

<h2>お子様のご利用について</h2>
<p>本アプリは学生の学習を主な想定用途としていますが、現時点で年齢確認の仕組みはありません。保護者の方は、お子様の利用状況をご確認いただくことをお勧めします。</p>

<h2>データの削除について</h2>
<p>現在、アプリ内からご自身でアカウントやデータを削除する機能は準備中です。削除をご希望の場合は、下記の連絡先までご連絡ください。</p>

<h2>セキュリティについて</h2>
<p>通信は暗号化された経路で行われます。一部のノートは、生体認証や暗号化によって保護する機能を利用できます。ただし、いかなる方法も完全な安全性を保証するものではありません。</p>

<h2>本ポリシーの変更について</h2>
<p>本ポリシーの内容は、必要に応じて変更されることがあります。重要な変更がある場合は、アプリ内でお知らせします。</p>

<h2>お問い合わせ先</h2>
<p>本ポリシーや保有する情報の取り扱いに関するご質問・ご請求は、${CONTACT_EMAIL} までご連絡ください。</p>
</body>
</html>
`;
}

export function handleLegal(url) {
  if (url.pathname === "/privacy") {
    return new Response(privacyPolicyHTML(), {
      status: 200,
      headers: securityHeaders({
        "content-type": "text/html; charset=utf-8",
        // securityHeaders()'s default CSP (default-src 'none') is tuned for
        // JSON API responses and would silently drop this page's inline
        // <style> block under a strict browser's CSP enforcement — still
        // readable without it, but unstyled. No script of any kind runs on
        // this static, un-templated page, so allowing inline styles alone
        // (nothing else) keeps the same protection against injected scripts.
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      }),
    });
  }
  return null;
}
