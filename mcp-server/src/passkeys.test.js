import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { associationFile, handlePasskeys } from "./passkeys.js";
import { revoke } from "./revocation.js";

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

// Tokens are "<issued-at epoch seconds>.<random secret>"; freshToken() mints
// one that was "just issued" so tests aren't tripped up by the expiry check.
function freshToken(suffix) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(64)}`;
}

// Mirrors the real Cloudflare Rate Limiting binding's shape: an object with
// a `limit({ key })` method resolving to `{ success: boolean }`.
function fakeCloudflareLimiter(limit = 5) {
  const counts = new Map();
  return {
    async limit({ key }) {
      const count = (counts.get(key) ?? 0) + 1;
      counts.set(key, count);
      return { success: count <= limit };
    },
  };
}

function environment() {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        let value = values.get(key) ?? null;
        // These tests aren't exercising session-authenticity enforcement
        // itself (see app.test.js's "requireRealSession" tests) — treat any
        // well-formed bearer token as if it came from a real sign-in, so
        // freshToken()'s many call sites don't each need to seed one by hand.
        if (value === null && key.startsWith("session:")) {
          value = JSON.stringify({ sub: "test", issuedAt: Math.floor(Date.now() / 1000) });
        }
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
    RATE_LIMIT_PASSKEY_LOGIN_OPTIONS: fakeCloudflareLimiter(),
    RATE_LIMIT_PASSKEY_LOGIN_VERIFY: fakeCloudflareLimiter(),
    RATE_LIMIT_PASSKEY_REGISTER_OPTIONS: fakeCloudflareLimiter(),
    RATE_LIMIT_PASSKEY_REGISTER_VERIFY: fakeCloudflareLimiter(),
  };
}

function registerOptionsRequest(token) {
  return new Request("https://example.test/api/passkeys/register/options", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ email: "student@example.com" }),
  });
}

function registerVerifyRequest(token) {
  return new Request("https://example.test/api/passkeys/register/verify", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ transaction: "does-not-exist", credential: { id: "does-not-exist" } }),
  });
}

function loginOptionsRequest(ip = "203.0.113.1") {
  return new Request("https://example.test/api/passkeys/login/options", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({}),
  });
}

function loginVerifyRequest(ip = "203.0.113.1") {
  return new Request("https://example.test/api/passkeys/login/verify", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ transaction: "does-not-exist", credential: { id: "does-not-exist" } }),
  });
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
      headers: { authorization: `Bearer ${freshToken("a")}`, "content-type": "application/json" },
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

test("rejects registration options for a revoked token", async () => {
  const token = freshToken("b");
  const env = environment();
  await revoke(env, sha256Hex(token));
  const request = new Request("https://example.test/api/passkeys/register/options", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ email: "student@example.com" }),
  });
  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 401);
});

test("rejects registration options for a token older than 90 days", async () => {
  const ninetyOneDaysAgo = Math.floor(Date.now() / 1000) - 91 * 24 * 60 * 60;
  const token = `${ninetyOneDaysAgo}.${"c".repeat(64)}`;
  const request = new Request("https://example.test/api/passkeys/register/options", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ email: "student@example.com" }),
  });
  const response = await handlePasskeys(new URL(request.url), request, environment());
  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /expired/i);
});

// MARK: - Rate limiting: /api/passkeys/login/options and /login/verify are
// callable with no bearer token at all, so they're gated by rate-limit.js's
// two-layer (Cloudflare binding + KV) check instead.

test("POST /api/passkeys/login/options: allows up to the limit, then 429s", async () => {
  const env = environment();
  for (let i = 0; i < 5; i++) {
    const response = await handlePasskeys(new URL(loginOptionsRequest().url), loginOptionsRequest(), env);
    assert.equal(response.status, 200);
  }
  const sixth = await handlePasskeys(new URL(loginOptionsRequest().url), loginOptionsRequest(), env);
  assert.equal(sixth.status, 429);
});

test("POST /api/passkeys/login/options: a different client IP is not affected by another IP's limit", async () => {
  const env = environment();
  for (let i = 0; i < 5; i++) {
    const request = loginOptionsRequest("203.0.113.1");
    assert.equal((await handlePasskeys(new URL(request.url), request, env)).status, 200);
  }
  const blocked = loginOptionsRequest("203.0.113.1");
  assert.equal((await handlePasskeys(new URL(blocked.url), blocked, env)).status, 429);

  const otherIP = loginOptionsRequest("198.51.100.1");
  assert.equal((await handlePasskeys(new URL(otherIP.url), otherIP, env)).status, 200);
});

test("POST /api/passkeys/login/verify: allows up to the limit, then 429s", async () => {
  const env = environment();
  for (let i = 0; i < 5; i++) {
    const request = loginVerifyRequest();
    const response = await handlePasskeys(new URL(request.url), request, env);
    // No matching challenge/credential exists, so this is a 400 either way —
    // the point is that it's not yet rate-limited.
    assert.equal(response.status, 400);
  }
  const sixth = loginVerifyRequest();
  const response = await handlePasskeys(new URL(sixth.url), sixth, env);
  assert.equal(response.status, 429);
});

// MARK: - Rate limiting: /api/passkeys/register/options and /register/verify
// already require a valid bearer token, so — unlike the login endpoints
// above — these are keyed by userKey (the token's hash) rather than IP.

test("POST /api/passkeys/register/options: allows up to the limit, then 429s", async () => {
  const env = environment();
  const token = freshToken("d");
  for (let i = 0; i < 5; i++) {
    const request = registerOptionsRequest(token);
    assert.equal((await handlePasskeys(new URL(request.url), request, env)).status, 200);
  }
  const sixth = registerOptionsRequest(token);
  assert.equal((await handlePasskeys(new URL(sixth.url), sixth, env)).status, 429);
});

test("POST /api/passkeys/register/options: a different token (userKey) is not affected by another token's limit", async () => {
  const env = environment();
  const token = freshToken("e");
  for (let i = 0; i < 5; i++) {
    const request = registerOptionsRequest(token);
    assert.equal((await handlePasskeys(new URL(request.url), request, env)).status, 200);
  }
  const blocked = registerOptionsRequest(token);
  assert.equal((await handlePasskeys(new URL(blocked.url), blocked, env)).status, 429);

  const otherToken = registerOptionsRequest(freshToken("f"));
  assert.equal((await handlePasskeys(new URL(otherToken.url), otherToken, env)).status, 200);
});

test("POST /api/passkeys/register/verify: allows up to the limit, then 429s", async () => {
  const env = environment();
  const token = freshToken("g");
  for (let i = 0; i < 5; i++) {
    const request = registerVerifyRequest(token);
    const response = await handlePasskeys(new URL(request.url), request, env);
    // No matching challenge exists, so this is a 400 either way — the point
    // is that it's not yet rate-limited.
    assert.equal(response.status, 400);
  }
  const sixth = registerVerifyRequest(token);
  const response = await handlePasskeys(new URL(sixth.url), sixth, env);
  assert.equal(response.status, 429);
});
