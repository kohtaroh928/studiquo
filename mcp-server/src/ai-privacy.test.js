import assert from "node:assert/strict";
import test from "node:test";
import { aiPrivacyRejection, AI_CONSENT_VERSION } from "./ai-privacy.js";

const APPROVED = { AI_PROVIDER_APPROVED: "true" };

function request(body = {}, consent = AI_CONSENT_VERSION, path = "chat", age = "adult") {
  const headers = { "Content-Type": "application/json", "X-Studiquo-AI-Consent": consent };
  if (age) headers["X-Studiquo-Age"] = age;
  return new Request(`https://example.test/api/ai/${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}
test("approval is opt-in and an old consent cannot enable requests", async () => {
  assert.equal((await aiPrivacyRejection(request(), {})).status, 503);
  assert.equal((await aiPrivacyRejection(request(), { AI_PROVIDER_APPROVED: true })).status, 503);
  assert.equal((await aiPrivacyRejection(request({}, ""), APPROVED)).status, 403);
  assert.equal((await aiPrivacyRejection(request({}, "google-v2"), APPROVED)).status, 403);
});
test("a request without a confirmed age band is refused; adult and teen pass", async () => {
  assert.equal((await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", ""), APPROVED)).status, 403);
  assert.equal((await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "child"), APPROVED)).status, 403);
  assert.equal(await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "teen"), APPROVED), null);
  assert.equal(await aiPrivacyRejection(request({}, AI_CONSENT_VERSION, "chat", "adult"), APPROVED), null);
});
test("all AI functions reject unlisted providers and invalid JSON", async () => {
  for (const path of ["chat", "rubric", "grade", "review"]) {
    assert.equal((await aiPrivacyRejection(request({ model: "gemini-3.5-flash-lite" }, AI_CONSENT_VERSION, path), APPROVED)).status, 403);
    assert.equal((await aiPrivacyRejection(request({ model: "claude-sonnet-5-5" }, AI_CONSENT_VERSION, path), APPROVED)).status, 403);
  }
  assert.equal((await aiPrivacyRejection(request([]), APPROVED)).status, 400);
});
test("approved OpenAI requests remain readable by the actual handler", async () => {
  const input = request({ model: "openai-luna", messages: [{ role: "user", text: "test" }] });
  assert.equal(await aiPrivacyRejection(input, APPROVED), null);
  assert.equal((await input.json()).messages[0].text, "test");
});
