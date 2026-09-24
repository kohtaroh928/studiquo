import assert from "node:assert/strict";
import test from "node:test";
import { checkRateLimit, clientKey } from "./rate-limit.js";

// Mirrors the real Cloudflare Rate Limiting binding's shape: an object with
// a `limit({ key })` method resolving to `{ success: boolean }`.
function fakeCloudflareLimiter(limit) {
  const counts = new Map();
  return {
    async limit({ key }) {
      const count = (counts.get(key) ?? 0) + 1;
      counts.set(key, count);
      return { success: count <= limit };
    },
  };
}

test("clientKey reads cf-connecting-ip and never trusts a missing header as a fixed value", () => {
  const withIP = new Request("https://example.test/x", { headers: { "cf-connecting-ip": "203.0.113.5" } });
  assert.equal(clientKey(withIP), "203.0.113.5");

  const withoutIP = new Request("https://example.test/x");
  assert.equal(clientKey(withoutIP), "unknown");
});

test("allows requests under the binding's limit", async () => {
  const binding = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(binding, "1.2.3.4"), true);
  }
});

test("rejects once the binding reports over limit", async () => {
  const binding = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(binding, "1.2.3.4"), true);
  }
  assert.equal(await checkRateLimit(binding, "1.2.3.4"), false);
});

test("a different key is not affected by another key's exhausted limit", async () => {
  const binding = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(binding, "1.2.3.4"), true);
  }
  assert.equal(await checkRateLimit(binding, "1.2.3.4"), false);

  assert.equal(await checkRateLimit(binding, "5.6.7.8"), true);
});

test("a different binding (a different endpoint) is not affected by another endpoint's exhausted limit", async () => {
  const bindingA = fakeCloudflareLimiter(5);
  const bindingB = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(bindingA, "1.2.3.4"), true);
  }
  assert.equal(await checkRateLimit(bindingA, "1.2.3.4"), false);

  assert.equal(await checkRateLimit(bindingB, "1.2.3.4"), true);
});
