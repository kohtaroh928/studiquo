import assert from "node:assert/strict";
import test from "node:test";
import { aiPrivacyRejection, AI_CONSENT_VERSION } from "./ai-privacy.js";

function request(body = {}, consent = AI_CONSENT_VERSION, path = "chat") {
  return new Request(`https://example.test/api/ai/${path}`, {
    method: "POST", headers: { "Content-Type": "application/json", "X-Studiquo-AI-Consent": consent },
    body: JSON.stringify(body),
  });
}
test("approval is opt-in and an old consent cannot enable requests", async () => {
  assert.equal((await aiPrivacyRejection(request(), {})).status, 503);
  assert.equal((await aiPrivacyRejection(request(), { AI_PROVIDER_APPROVED: true })).status, 503);
  assert.equal((await aiPrivacyRejection(request({}, ""), { AI_PROVIDER_APPROVED: "true" })).status, 403);
  assert.equal((await aiPrivacyRejection(request({}, "google-v1"), { AI_PROVIDER_APPROVED: "true" })).status, 403);
});
test("all AI functions reject other providers and invalid JSON", async () => {
  for (const path of ["chat", "rubric", "grade", "review"]) {
    assert.equal((await aiPrivacyRejection(request({ model: "openai-mid" }, AI_CONSENT_VERSION, path), { AI_PROVIDER_APPROVED: "true" })).status, 403);
    assert.equal((await aiPrivacyRejection(request({ model: "claude-sonnet-5" }, AI_CONSENT_VERSION, path), { AI_PROVIDER_APPROVED: "true" })).status, 403);
  }
  assert.equal((await aiPrivacyRejection(request([]), { AI_PROVIDER_APPROVED: "true" })).status, 400);
});
test("approved Google requests remain readable by the actual handler", async () => {
  const input = request({ model: "gemini-3.5-flash-lite", messages: [{ role: "user", text: "test" }] });
  assert.equal(await aiPrivacyRejection(input, { AI_PROVIDER_APPROVED: "true" }), null);
  assert.equal((await input.json()).messages[0].text, "test");
});
