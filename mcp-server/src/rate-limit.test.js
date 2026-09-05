import assert from "node:assert/strict";
import test from "node:test";
import { checkRateLimit, clientKey } from "./rate-limit.js";

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

function alwaysAllow() {
  return { async limit() { return { success: true }; } };
}

function alwaysDeny() {
  return { async limit() { return { success: false }; } };
}

test("clientKey reads cf-connecting-ip and never trusts a missing header as a fixed value", () => {
  const withIP = new Request("https://example.test/x", { headers: { "cf-connecting-ip": "203.0.113.5" } });
  assert.equal(clientKey(withIP), "203.0.113.5");

  const withoutIP = new Request("https://example.test/x");
  assert.equal(clientKey(withoutIP), "unknown");
});

test("allows requests under the limit on both layers", async () => {
  const env = environment();
  const binding = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), true);
  }
});

test("rejects once the Cloudflare binding layer alone reports over limit", async () => {
  const env = environment();
  const binding = alwaysDeny();
  assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), false);
});

test("rejects once the KV layer alone reports over limit, even if the Cloudflare binding allows", async () => {
  const env = environment();
  const binding = alwaysAllow();
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), true);
  }
  // A 6th call must be rejected by the KV counter alone, since the fake
  // Cloudflare binding always says yes.
  assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), false);
});

test("a different key is not affected by another key's exhausted limit", async () => {
  const env = environment();
  const binding = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), true);
  }
  assert.equal(await checkRateLimit(env, binding, "test-endpoint", "1.2.3.4", 5), false);

  assert.equal(await checkRateLimit(env, binding, "test-endpoint", "5.6.7.8", 5), true);
});

test("a different kvPrefix (a different endpoint) is not affected by another endpoint's exhausted limit", async () => {
  const env = environment();
  const bindingA = fakeCloudflareLimiter(5);
  const bindingB = fakeCloudflareLimiter(5);
  for (let i = 0; i < 5; i++) {
    assert.equal(await checkRateLimit(env, bindingA, "endpoint-a", "1.2.3.4", 5), true);
  }
  assert.equal(await checkRateLimit(env, bindingA, "endpoint-a", "1.2.3.4", 5), false);

  assert.equal(await checkRateLimit(env, bindingB, "endpoint-b", "1.2.3.4", 5), true);
});
