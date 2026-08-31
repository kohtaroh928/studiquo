import assert from "node:assert/strict";
import test from "node:test";
import { associationFile, handlePasskeys } from "./passkeys.js";

function environment() {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
  };
}

test("serves the Apple web-credentials association", async () => {
  const response = associationFile();
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.deepEqual(payload.webcredentials.apps, ["972G4VGUA6.com.yabuko.studiquo"]);
});

test("creates bounded, user-verified passkey registration options", async () => {
  const request = new Request("https://example.test/api/passkeys/register/options", {
      method: "POST",
      headers: { authorization: `Bearer ${"a".repeat(64)}`, "content-type": "application/json" },
      body: JSON.stringify({ email: "student@example.com" }),
    });
  const response = await handlePasskeys(new URL(request.url), request, environment());
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.options.rp.id, "studiquo-mcp.studiquo-mcp-server.workers.dev");
  assert.equal(payload.options.authenticatorSelection.userVerification, "required");
  assert.ok(payload.transaction);
  assert.ok(payload.options.challenge);
});
