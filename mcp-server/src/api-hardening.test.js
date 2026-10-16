// Request-budget, ordering and header checks for routes that go through the
// Worker's front door (app.js): /mcp, /api/snapshot, /api/ai/*, the connection
// list and the HTML pages.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import worker from "./app.js";

const hash = value => createHash("sha256").update(value).digest("hex");
const noopCtx = { waitUntil() {} };
const freshToken = suffix => `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;

// A RateCounter double that counts like the real one (true while under the
// limit), per name.
function countingRateCounter() {
  const counts = new Map();
  const asked = [];
  return {
    asked,
    getByName(name) {
      return {
        async bump(limit, windowSeconds) {
          asked.push({ name, limit, windowSeconds });
          const used = (counts.get(name) ?? 0) + 1;
          if (used > limit) return false;
          counts.set(name, used);
          return true;
        },
        async take(limit, windowSeconds, amount = 1) {
          const used = (counts.get(name) ?? 0) + amount;
          if (used > limit) return { ok: false };
          counts.set(name, used);
          return { ok: true, windowEndsAt: Date.now() + windowSeconds * 1000 };
        },
        async give() {},
      };
    },
  };
}

function environment(extra = {}) {
  const values = new Map();
  return {
    raw: values,
    STUDIQUO_DATA: {
      async get(key, type) {
        let value = values.get(key) ?? null;
        // A well-formed bearer token counts as a real sign-in unless the test
        // seeded its own session.
        if (value === null && key.startsWith("session:")) {
          value = JSON.stringify({ sub: "someone", issuedAt: Math.floor(Date.now() / 1000) });
        }
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix = "" } = {}) {
        return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true };
      },
    },
    RATE_COUNTER: countingRateCounter(),
    ...extra,
  };
}

// A D1 with no subscriber or legacy rows in it.
const noRows = { prepare() { return { bind() { return { async all() { return { results: [] }; } }; } }; } };

function call(env, path, { method = "GET", token, headers = {}, body } = {}) {
  const all = { ...headers };
  if (token) all.authorization = `Bearer ${token}`;
  return worker.fetch(new Request(`https://example.test${path}`, { method, headers: all, body }), env, noopCtx);
}

// ---- /mcp ------------------------------------------------------------------

test("/mcp refuses a credential that calls more than 120 times a minute", async () => {
  const env = environment();
  const token = freshToken("m");
  let last;
  for (let i = 0; i < 120; i += 1) {
    last = await call(env, "/mcp", { token });
    assert.notEqual(last.status, 429, `call ${i + 1}`);
  }
  last = await call(env, "/mcp", { token });
  assert.equal(last.status, 429);
  assert.equal(last.headers.get("retry-after"), "60");
});

test("the /mcp budget is per credential, not shared", async () => {
  const env = environment();
  for (let i = 0; i < 121; i += 1) await call(env, "/mcp", { token: freshToken("a") });
  assert.notEqual((await call(env, "/mcp", { token: freshToken("b") })).status, 429);
});

// ---- /api/snapshot ---------------------------------------------------------

test("snapshot uploads are limited to 30 an hour per token", async () => {
  const env = environment();
  const token = freshToken("s");
  const body = JSON.stringify({ version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" });
  for (let i = 0; i < 30; i += 1) {
    const response = await call(env, "/api/snapshot", { method: "PUT", token, headers: { "content-type": "application/json" }, body });
    assert.equal(response.status, 200, `upload ${i + 1}`);
  }
  const refused = await call(env, "/api/snapshot", { method: "PUT", token, headers: { "content-type": "application/json" }, body });
  assert.equal(refused.status, 429);
  assert.equal(refused.headers.get("retry-after"), "600");
});

// ---- /api/ai/* -------------------------------------------------------------

test("AI requests are limited to 60 a minute per account before any body is read", async () => {
  const env = environment({ ADMIN_DB: noRows });
  const token = freshToken("i");
  // AI is not approved in this environment, so an admitted request is a 503.
  for (let i = 0; i < 60; i += 1) {
    const response = await call(env, "/api/ai/chat", { method: "POST", token, headers: { "content-type": "application/json" }, body: "{}" });
    assert.equal(response.status, 503, `request ${i + 1}`);
  }
  const refused = await call(env, "/api/ai/chat", { method: "POST", token, headers: { "content-type": "application/json" }, body: "{}" });
  assert.equal(refused.status, 429);
});

test("an account with no plan is refused with 402 without its body being read", async () => {
  const env = environment({ PAYWALL_ENABLED: "true", AI_PROVIDER_APPROVED: "true", ADMIN_DB: noRows });
  const response = await call(env, "/api/ai/chat", {
    method: "POST", token: freshToken("f"),
    // Neither the consent headers nor valid JSON: the 402 comes before both.
    headers: { "content-type": "application/json" }, body: "{{ not json",
  });
  assert.equal(response.status, 402);
  assert.equal((await response.json()).code, "subscription_required");
});

// ---- Connected apps --------------------------------------------------------

test("the list of connected apps shows only what the app displays", async () => {
  const env = environment();
  const token = freshToken("c");
  await env.STUDIQUO_DATA.put(`session:${hash(token)}`, JSON.stringify({ sub: "owner-sub", issuedAt: Math.floor(Date.now() / 1000) }));
  const clientId = "studiquo_" + "a".repeat(32);
  await env.STUDIQUO_DATA.put(`mcp:grant:${hash("owner-sub")}:${hash(clientId)}`, JSON.stringify({ clientName: "Claude", createdAt: 1234, nonce: "secret-nonce" }));
  const response = await call(env, "/api/mcp/connections", { token });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), [{ id: hash(clientId), clientName: "Claude", createdAt: 1234 }]);
});

// ---- HTML pages ------------------------------------------------------------

function assertFrameless(response) {
  const policy = response.headers.get("content-security-policy");
  assert.match(policy, /frame-ancestors 'none'/);
  assert.match(policy, /base-uri 'none'/);
  assert.match(policy, /form-action 'none'/);
  assert.match(policy, /default-src 'none'/);
  assert.equal(response.headers.get("x-frame-options"), "DENY");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(response.headers.get("referrer-policy"), "no-referrer");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(response.headers.get("content-type"), /^text\/html/);
}

test("the invite page cannot be framed and calls no other origin", async () => {
  const response = await call(environment(), "/invite?token=ABCDEF12");
  assert.equal(response.status, 200);
  assertFrameless(response);
  assert.doesNotMatch(response.headers.get("content-security-policy"), /connect-src/);
});

test("the admin pages cannot be framed and may call only their own origin", async () => {
  for (const path of ["/admin", "/admin/announcements"]) {
    const response = await call(environment(), path);
    assert.equal(response.status, 200, path);
    assertFrameless(response);
    assert.match(response.headers.get("content-security-policy"), /connect-src 'self'/);
  }
});
