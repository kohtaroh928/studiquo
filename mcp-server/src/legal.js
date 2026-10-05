import { securityHeaders } from "./http.js";

// Publicly served legal pages (no bearer token required) — registered in
// app.js alongside /health and the Apple app-site-association file, before
// the /api/ bearer-token gate, since App Store Connect, Sign in with Apple's
// configuration, and a user opening the link from Settings all need this
// reachable with no auth.
//
const CONTACT_EMAIL = "yabukohtaroh@gmail.com";
const PUBLISHED_DATE = "2026年10月5日";
// The privacy policy changes on its own schedule (diagnostic data, 2026-10-03).
const PRIVACY_PUBLISHED_DATE = "2026年10月5日";

function homePageHTML() {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>studiquo</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; line-height: 1.8; max-width: 720px; margin: 0 auto; padding: 48px 20px 80px; color: #1c1c1e; }
  h1 { font-size: 2em; margin-bottom: 0.2em; }
  h2 { font-size: 1.15em; margin-top: 2.2em; }
  a { color: #1769aa; }
  .lead { color: #555; font-size: 1.05em; }
</style>
</head>
<body>
<h1>studiquo</h1>
<p class="lead">ノート、学習計画、カレンダーをひとつにまとめる学生向け学習アプリです。</p>

<h2>Googleカレンダー連携</h2>
<p>利用者が明示的に連携した場合に限り、Googleカレンダーの予定を読み取り専用で取得し、studiquo内の学習予定と一緒に表示します。予定の作成、変更、削除をGoogleカレンダーへ送信することはありません。</p>

<h2>お問い合わせ</h2>
<p><a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a></p>

<p><a href="/terms">利用規約</a> ・ <a href="/privacy">プライバシーポリシー</a></p>
</body>
</html>`;
}

// Kept in sync by hand with TermsOfUseView's body text in ContentView.swift,
// the same "two renderings of one document" relationship privacyPolicyHTML
// above has with PrivacyPolicyView — and linked from SubscriptionPlansView
// next to the purchase buttons, per App Store Review Guideline 3.1.2's
// requirement that an auto-renewable subscription link to its Terms of Use
// (EULA) from inside the app, not just from the App Store listing.
function termsOfUseHTML() {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>studiquo 利用規約</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; line-height: 1.8; max-width: 680px; margin: 0 auto; padding: 32px 20px 80px; color: #1c1c1e; }
  h1 { font-size: 1.4em; }
  h2 { font-size: 1.1em; margin-top: 2em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
  .updated { color: #666; font-size: 0.9em; }
  ol { padding-left: 1.4em; }
  ul { padding-left: 1.4em; }
</style>
</head>
<body>
<h1>studiquo 利用規約</h1>
<p class="updated">最終更新日: ${PUBLISHED_DATE}</p>

<p>この利用規約(以下「本規約」)は、学習アプリ「studiquo」(以下「本アプリ」)の利用条件を定めるものです。本アプリをダウンロード、インストール、または利用することで、本規約に同意したものとみなされます。本規約に同意できない場合は、本アプリを利用しないでください。</p>

<h2>1. サービスの内容</h2>
<p>本アプリは、ノート、暗記帳、学習計画、カレンダーを管理するための学生向け学習支援アプリです。機能の一部は、利用者自身のApple IDまたはGoogleアカウントでのサインインを必要とします。</p>

<h2>2. アカウント</h2>
<ul>
  <li>利用者は、登録情報を正確に保つ責任を負います。</li>
  <li>アカウントおよびログイン情報の管理は利用者自身の責任で行ってください。アカウントを通じて行われた操作については、利用者本人が行ったものとみなされます。</li>
  <li>本アプリは学生の学習を主な想定用途としていますが、年齢確認の仕組みはありません。未成年者が利用する場合は、保護者の方の責任のもとでご利用ください。</li>
</ul>

<h2>3. 利用者が作成するコンテンツ</h2>
<p>ノート、暗記帳、文書、スライドなど、利用者が本アプリ内で作成するコンテンツの権利は利用者に帰属します。運営は、本アプリの機能(保存、同期、友達・グループへの共有、AI機能への送信など、利用者自身が指示した処理)を提供するために必要な範囲でのみ、これらのコンテンツを取り扱います。</p>

<h2>4. AI機能について</h2>
<p>AIトーク・添削・翌日復習などの機能は、Google GeminiなどのAI連携先サービスを利用して応答を生成します。AIの回答は誤りを含む可能性があり、学習の参考情報として提供されるものであって、内容の正確性・完全性を保証するものではありません。成績や試験結果等に関する判断は、利用者自身の責任で行ってください。送信される情報の詳細は<a href="/privacy">プライバシーポリシー</a>をご確認ください。</p>

<h2>5. サブスクリプションと支払い</h2>
<ul>
  <li>Plus・Proプランは、App Storeを通じた自動更新のサブスクリプションです。</li>
  <li>購入はApple IDに設定した決済手段で行われ、料金・購読期間は購入画面に表示される内容のとおりです。</li>
  <li>サブスクリプションは、現在の購読期間が終了する24時間前までに解約しない限り、同一期間で自動的に更新されます。更新の請求は、期間終了前24時間以内に行われます。</li>
  <li>解約は、App Storeの「設定」からAppleアカウントのサブスクリプション管理画面で行ってください。本アプリ内からApp Storeの契約を直接解約することはできません。購入後のキャンセル期間を過ぎた分の未使用期間についての返金は、Appleの規定に従います。</li>
  <li>プラン別に提供されるAIクレジットの上限・利用可能なAIモデルは、本アプリ内の表示および運営の判断により変更される場合があります。</li>
</ul>

<h2>6. 禁止事項</h2>
<ul>
  <li>法令または公序良俗に違反する行為</li>
  <li>他の利用者への嫌がらせ、誹謗中傷、迷惑行為</li>
  <li>本アプリまたは関連サーバーへの不正アクセス、リバースエンジニアリング、過度な負荷をかける行為</li>
  <li>他者の知的財産権、プライバシー、その他の権利を侵害する行為</li>
  <li>本アプリを不正または詐欺的な目的で利用する行為</li>
</ul>

<h2>7. 本アプリの変更・中断・終了</h2>
<p>運営は、事前の通知なく本アプリの内容を変更し、提供を一時的に中断し、または終了することがあります。これにより利用者に生じた損害について、運営は法令上許容される範囲で責任を負いません。</p>

<h2>8. アカウントの削除・利用停止</h2>
<p>利用者は、「設定」からいつでも自身のアカウントを削除できます。削除すると、学習資料・プロフィール・フレンド・グループ情報等が削除されます。詳しくは<a href="/privacy">プライバシーポリシー</a>をご確認ください。運営は、本規約に違反した利用者について、通知なくアカウントの利用を停止する場合があります。App Storeのサブスクリプションは、アカウント削除だけでは解約されないため、App Storeで別途解約の手続きを行ってください。</p>

<h2>9. 免責事項</h2>
<p>本アプリは「現状有姿」で提供され、特定の目的への適合性、正確性、継続的な可用性について、明示または黙示を問わずいかなる保証も行いません。本アプリの利用により生じた損害について、運営は法令上許容される最大限の範囲で責任を負いません。</p>

<h2>10. 準拠法・管轄</h2>
<p>本規約の解釈には日本法を準拠法とします。本アプリに関して生じた紛争については、運営の所在地を管轄する裁判所を第一審の専属的合意管轄裁判所とします。</p>

<h2>11. 本規約の変更</h2>
<p>運営は、本規約を変更することがあります。重要な変更がある場合は、アプリ内でお知らせします。変更後も本アプリの利用を継続した場合、変更後の規約に同意したものとみなされます。</p>

<h2>お問い合わせ先</h2>
<p>本規約に関するご質問は、<a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> までご連絡ください。</p>
</body>
</html>
`;
}

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
<p class="updated">最終更新日: ${PRIVACY_PUBLISHED_DATE}</p>

<p>本ポリシーは、学習アプリ「studiquo」(以下「本アプリ」)が、利用者の情報をどのように取り扱うかを説明するものです。</p>

<h2>収集する情報とその利用目的</h2>
<ul>
  <li><strong>アカウント情報</strong>:サインイン方法に応じて、メールアドレス、Apple IDまたはGoogleアカウントの識別子、氏名の一部を取得します。本アプリの利用を可能にするために使用します。</li>
  <li><strong>プロフィール情報</strong>:設定した表示名。友達機能・共同編集機能で他の利用者に表示するために使用します。</li>
  <li><strong>学習コンテンツ</strong>:ノート、暗記帳、文書、スライドなど、利用者が作成したコンテンツ。本アプリの基本機能を提供するために保存します。</li>
  <li><strong>友達・チャット機能に関する情報</strong>:友達コード、友達関係、チャットメッセージ、送信した添付ファイル。友達同士のコミュニケーション機能を提供するために保存します。</li>
  <li><strong>利用状況</strong>:学習時間の記録、各機能の利用回数。学習記録機能・利用制限の管理のために使用します。</li>
  <li><strong>Googleカレンダー情報</strong>:利用者がGoogleカレンダー連携を選択した場合、カレンダー名、予定のタイトル、開始・終了日時、説明を読み取り、学習予定と一緒に表示するために端末内へ保存します。Googleカレンダーへの書き込みは行いません。</li>
  <li><strong>AI機能利用時に送信する内容</strong>:AIトーク・添削・翌日復習などの機能を使うと、質問文、ノートの内容、答案の画像などが外部のAIサービスに送信されます。詳しくは次の項目をご覧ください。</li>
  <li><strong>自動送信される診断情報</strong>:アプリのクラッシュ・フリーズや、起動・同期などの失敗が起きると、エラーの種類、発生した箇所を示す技術的な情報(プログラム上の関数名など)、アプリのバージョン、端末モデル、OSのバージョン、発生日時が、運営のサーバーへ自動的に送信されます。ノート・チャット・AIへの質問などの内容や、メールアドレス・氏名は含まれません。同じ問題が何人に起きたかを数えるため、アカウントを特定できない形に変換した識別子を使用します。アプリの改善と不具合の調査のために使用し、「設定」の「エラー情報を自動送信」からいつでも停止できます。</li>
  <li><strong>問題報告の内容</strong>:ホーム画面の「問題を報告」機能を使うと、送信した説明文、任意で添付したスクリーンショット、端末モデル・OS・アプリのバージョンなどの情報が送信されます。不具合の調査のために使用します。</li>
</ul>

<h2>第三者サービスとの連携</h2>
<ul>
  <li><strong>Sign in with Apple / Google Sign-In</strong>:アカウント作成・ログインのために使用します。</li>
  <li><strong>Google Calendar API</strong>:利用者の許可を得たうえで、選択されているカレンダーの予定を読み取り専用で同期します。取得した情報を広告、行動追跡、第三者への販売には使用しません。</li>
  <li><strong>Google Gemini</strong>:AIトーク・添削・翌日復習機能で、既定の生成AIとして使用します。これらの機能を使うたびに、上記の内容がGoogleに送信されます。</li>
  <li><strong>Anthropic Claude</strong>:利用者が自分自身のAnthropic APIキーを設定した場合に限り、同様の内容がAnthropicにも送信されます。APIキーを設定しない限り、この連携は行われません。</li>
  <li><strong>Cloudflare</strong>:本アプリのサーバーインフラとして使用しており、上記のアカウント情報・学習コンテンツ・チャット内容の保管場所です。</li>
  <li><strong>Apple iCloud</strong>:「iCloudで同期する」をオンにした端末では、ノート・暗記帳・文書・スライド・フォルダ・カレンダーの予定(連携して取得した予定を含む)・AIトークの履歴・学習記録など、アプリ内に保存されるデータが、CloudKitを通じて利用者ご自身のiCloudアカウント内で端末間同期されます。この設定は端末ごとの任意の設定で、新しくインストールした場合は初期状態でオフです(以前のバージョンから引き続き利用している場合は、これまでどおりオンです)。同期されたデータは利用者ご自身のiCloudに保存され、iCloudの保存容量を使用します。</li>
  <li><strong>Slack</strong>:「問題を報告」で送信された内容と、自動送信された診断情報の通知を運営が確認するために使用します。</li>
</ul>

<h2>広告・トラッキングについて</h2>
<p>本アプリは広告配信を行っておらず、第三者による行動トラッキングも行っていません。</p>

<h2>お子様のご利用について</h2>
<p>本アプリは学生の学習を主な想定用途としていますが、現時点で年齢確認の仕組みはありません。保護者の方は、お子様の利用状況をご確認いただくことをお勧めします。</p>

<h2>データの削除について</h2>
<p>アプリの「設定」からアカウントを削除できます。削除すると、端末およびクラウド上の学習資料、プロフィール、フレンド・グループ情報、ログイン情報など、アカウントに関連するデータが削除されます。他の利用者との会話を維持するため、その利用者側に残る過去のメッセージは「削除済みユーザー」の発言として匿名化される場合があります。iCloud同期をオンにしている端末では、端末のデータの削除がiCloudにも反映されます。同期をオフにしている場合や、過去にオンにしていた場合にiCloudに残っているデータは、アカウントの削除では削除されません。iPadの「設定」アプリのiCloud設定から、ご自身で削除してください。App Storeのサブスクリプションはアカウント削除だけでは解約されないため、App Storeで別途管理してください。</p>

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
  if (url.pathname === "/googlea95d7e8605a2e940.html") {
    return new Response("google-site-verification: googlea95d7e8605a2e940.html", {
      status: 200,
      headers: securityHeaders({ "content-type": "text/plain; charset=utf-8" }),
    });
  }
  if (url.pathname === "/" || url.pathname === "/index.html") {
    return new Response(homePageHTML(), {
      status: 200,
      headers: securityHeaders({
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      }),
    });
  }
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
  if (url.pathname === "/terms") {
    return new Response(termsOfUseHTML(), {
      status: 200,
      headers: securityHeaders({
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      }),
    });
  }
  return null;
}
