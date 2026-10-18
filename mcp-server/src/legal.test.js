import assert from "node:assert/strict";
import test from "node:test";
import worker from "./app.js";

const noopCtx = { waitUntil() {} };

test("GET / serves the public Studiquo home page", async () => {
  const response = await worker.fetch(new Request("https://example.test/"), {}, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /text\/html/);
  const body = await response.text();
  assert.match(body, /studiquo/);
  assert.match(body, /Googleカレンダー連携/);
  assert.match(body, /href="\/privacy"/);
  assert.match(body, /href="\/terms"/);
});

test("GET Search Console verification file proves site ownership", async () => {
  const response = await worker.fetch(
    new Request("https://example.test/googlea95d7e8605a2e940.html"),
    {},
    noopCtx,
  );
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "google-site-verification: googlea95d7e8605a2e940.html");
});

test("GET /privacy serves the privacy policy without a bearer token", async () => {
  const response = await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /text\/html/);
  const body = await response.text();
  assert.match(body, /プライバシーポリシー/);
  assert.match(body, /OpenAI/);
  assert.match(body, /Google Calendar API/);
  assert.match(body, /yabukohtaroh@gmail\.com/);
  assert.doesNotMatch(body, /【/);
});

test("GET /terms serves the terms of use without a bearer token", async () => {
  const response = await worker.fetch(new Request("https://example.test/terms"), {}, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /text\/html/);
  const body = await response.text();
  assert.match(body, /利用規約/);
  assert.match(body, /自動的に更新/);
  assert.match(body, /App Store/);
  assert.match(body, /yabukohtaroh@gmail\.com/);
  assert.doesNotMatch(body, /【/);
});

// App Store Review Guideline 3.1.2: an auto-renewable subscription's terms
// must disclose the renewal/cancellation mechanics, not just that it
// renews. These phrases are what SubscriptionPlansView's purchase screen
// links out to — losing any of them silently would still pass the plain
// "renders a page" check above.
test("GET /terms discloses the auto-renewal cancellation window and how to cancel", async () => {
  const response = await worker.fetch(new Request("https://example.test/terms"), {}, noopCtx);
  const body = await response.text();
  assert.match(body, /24時間/);
  assert.match(body, /解約/);
  assert.match(body, /プライバシーポリシー/);
});

// The iCloud sync switch is off by default for new installs, and the app never
// deletes what is already in the student's iCloud. Both are promises the
// policy has to keep stating, and the terms must not mention a sync capacity
// limit that no longer exists.
test("GET /privacy describes the optional iCloud sync and that iCloud data outlives account deletion", async () => {
  const response = await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx);
  const body = await response.text();
  assert.match(body, /iCloudで同期する/);
  assert.match(body, /初期状態でオフ/);
  assert.match(body, /アカウントの削除では削除されません/);
  assert.doesNotMatch(body, /一部のデータは、CloudKit/);
});

test("GET /terms no longer mentions a cloud sync capacity limit", async () => {
  const response = await worker.fetch(new Request("https://example.test/terms"), {}, noopCtx);
  const body = await response.text();
  assert.doesNotMatch(body, /クラウド同期容量/);
  assert.match(body, /AIクレジットの上限/);
});

// The CSP that keeps these static, un-templated legal pages from running
// injected scripts (see privacyPolicyHTML's own doc comment) must cover
// /terms too — it is easy to add a new route under handleLegal and forget
// the header options that make its inline <style> block render correctly.
test("/privacy and /terms both ship the inline-style-only CSP", async () => {
  for (const path of ["/privacy", "/terms"]) {
    const response = await worker.fetch(new Request(`https://example.test${path}`), {}, noopCtx);
    assert.equal(
      response.headers.get("content-security-policy"),
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      `${path} should ship the inline-style CSP`,
    );
  }
});

test("a request to an unrelated path is not intercepted by the legal router", async () => {
  const response = await worker.fetch(new Request("https://example.test/health"), {}, noopCtx);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
});

test("the privacy policy discloses the automatic diagnostic reports and how to turn them off", async () => {
  const response = await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx);
  const body = await response.text();
  assert.match(body, /任意の診断情報/);
  assert.match(body, /初期状態では送信しません/);
  assert.match(body, /現在の送信先はOpenAIのみ/);
  assert.match(body, /保存期間/);
  assert.match(body, /本文・画像の閲覧には管理者ログインが必要/);
  assert.match(body, /ノートやチャットの本文は含めません/);
  assert.match(body, /いつでも停止できます/);
});

// The policy must name every outside party the Worker really talks to, and every
// kind of data it really keeps about a request. This list is built from the
// Worker's source on purpose: a new host added to the code without a line in the
// policy fails here. A host that is deliberately NOT in the policy is listed
// below with the reason, so that leaving it out is a decision and not an accident.
//
// What this scan can and cannot see: it finds hosts written as a literal
// `https://host` in the source. The APNs host (built in push.js) and the Slack
// webhook (a secret URL) are not literals, so they are named by hand in the
// MUST_NAME list below instead.
import { readdirSync, readFileSync } from "node:fs";

const HOST_TO_POLICY_TERM = {
  "api.openai.com": "OpenAI",
  "api.resend.com": "Resend",
  "api.revenuecat.com": "RevenueCat",
  "api.pwnedpasswords.com": "Pwned Passwords",
  "appleid.apple.com": "Sign in with Apple",
  "accounts.google.com": "Google Sign-In",
  "www.googleapis.com": "Google Sign-In",
};
const HOSTS_DELIBERATELY_NOT_IN_THE_POLICY = {
  // Wired in handleChat but listed for no plan (ai.js PLAN_MODELS), so no student data goes there.
  // Add it to the policy together with the plan entry (docs/releases/ai-credit-plans.md).
  "api.anthropic.com": "no plan uses it",
  // Links shown in pages and docs, and the MCP clients' own origins; the Worker sends them nothing.
  "claude.ai": "an allowed OAuth redirect origin, not a destination",
  "chatgpt.com": "an allowed OAuth redirect origin, not a destination",
  "apps.apple.com": "a link",
  "community.cloudflare.com": "a link in a comment",
};

test("every outside host the Worker contacts is named in the privacy policy, or left out on purpose", async () => {
  const sources = readdirSync(new URL(".", import.meta.url)).filter(name => name.endsWith(".js") && !name.endsWith(".test.js"));
  const hosts = new Set();
  for (const name of sources) {
    for (const match of readFileSync(new URL(name, import.meta.url), "utf8").matchAll(/https:\/\/([a-z0-9.-]+\.[a-z]{2,})/g)) hosts.add(match[1]);
  }
  const body = await (await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx)).text();
  const unaccounted = [...hosts].filter(host =>
    !(host in HOST_TO_POLICY_TERM) && !(host in HOSTS_DELIBERATELY_NOT_IN_THE_POLICY)
    && !/(^|\.)(example|test|evil\.example|invalid)(\.[a-z]+)?$/.test(host) && !host.endsWith("w3.org"));
  assert.deepEqual(unaccounted, [], "a host the code contacts is neither in the policy nor listed as left out on purpose");
  for (const [host, term] of Object.entries(HOST_TO_POLICY_TERM)) {
    if (hosts.has(host)) assert.ok(body.includes(term), `${host} is contacted, so the policy must mention ${term}`);
  }
  // Destinations the scan cannot see (see the comment above).
  const MUST_NAME = ["Apple Push Notification service", "Slack", "RevenueCat", "Cloudflare", "Resend", "OpenAI"];
  for (const term of MUST_NAME) assert.ok(body.includes(term), `the policy must name ${term}`);
});

test("the privacy policy states what is kept about a request, a device and an email", async () => {
  const body = await (await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx)).text();
  // Provider-side facts of the code in login-throttle.js, login-monitor.js, devices.js, push.js.
  assert.match(body, /IPアドレス/);
  assert.match(body, /ハッシュ値/);
  assert.match(body, /国・地域・ネットワーク/);
  assert.match(body, /最大20件を90日間/);
  assert.match(body, /プッシュ通知トークン/);
  assert.match(body, /インストールID/);
  assert.match(body, /端末名/);
  assert.match(body, /Apple Push Notification service/);
  assert.match(body, /最大120文字/);
  assert.match(body, /ハッシュ値の先頭5文字だけ/);
  assert.match(body, /アプリを開いた日時を、利用者数の集計/);
  assert.match(body, /MCP連携/);
  assert.match(body, /90日で自動的に削除/);
  // What the MCP copy really holds (makeMCPSnapshotData in ContentView.swift).
  assert.match(body, /文書の題名と本文/);
  assert.match(body, /学習記録/);
  assert.match(body, /Googleカレンダーから取り込んだ予定を含みます/);
  assert.match(body, /取り込んだ予定は、MCP連携の「今すぐ同期」を行った場合に限り/);
  // RevenueCat gets the account identifier, which is the email address for email accounts.
  assert.match(body, /メールアドレスそのもの/);
  // The hashes are pseudonymous, and the policy says so.
  assert.match(body, /仮名化であり、匿名化ではありません/);
});

test("the policy and the terms say the same thing about age", async () => {
  const privacy = await (await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx)).text();
  const terms = await (await worker.fetch(new Request("https://example.test/terms"), {}, noopCtx)).text();
  for (const body of [privacy, terms]) {
    assert.match(body, /登録時に年齢を確認する仕組みはありません/);
    assert.match(body, /AI機能に限り、初回の送信前に年齢区分を確認/);
    assert.match(body, /13歳未満の方にはAI機能を提供せず/);
    assert.doesNotMatch(body, /現時点で年齢確認の仕組みはありません/);
  }
});

test("the policy does not yet claim what the legal review has not settled", async () => {
  // Cross-border transfer, the outside-transmission rule and the commerce-law notice
  // wait for a legal check (Notion: 法務確認). Nothing here pretends they are done.
  const body = await (await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx)).text();
  assert.doesNotMatch(body, /越境|外国にある第三者|特定商取引/);
});
