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
  assert.match(body, /Google Gemini/);
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
  assert.match(body, /現在の送信先はGoogleのみ/);
  assert.match(body, /保存期間/);
  assert.match(body, /本文・画像の閲覧には管理者ログインが必要/);
  assert.match(body, /ノートやチャットの本文は含めません/);
  assert.match(body, /いつでも停止できます/);
});
