import assert from "node:assert/strict";
import test from "node:test";
import worker from "./app.js";

const noopCtx = { waitUntil() {} };

test("GET /privacy serves the privacy policy without a bearer token", async () => {
  const response = await worker.fetch(new Request("https://example.test/privacy"), {}, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /text\/html/);
  const body = await response.text();
  assert.match(body, /プライバシーポリシー/);
  assert.match(body, /Google Gemini/);
});

test("a request to an unrelated path is not intercepted by the legal router", async () => {
  const response = await worker.fetch(new Request("https://example.test/health"), {}, noopCtx);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
});
