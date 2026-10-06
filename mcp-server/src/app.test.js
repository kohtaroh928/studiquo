import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import worker from "./app.js";
import { realSession } from "./session.js";
import { reserveAttempt, refundAttempt, trustPair } from "./login-throttle.js";
import { touchSeenContext } from "./login-monitor.js";
import { accountGenerationMethods } from "./test-account-generations.js";
import { ACCESS_ENV, ACCESS_HEADERS } from "./test-access.js";

// Regression coverage for "logging out doesn't revoke the cloud sync token":
// once a token is revoked, it must be rejected everywhere it used to work,
// while an unrelated token (a different device) must keep working normally.

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

// Mirrors RateCounter.bump's contract: true while under `limit`, false once spent.
function fakeRateCounterBinding(getData) {
  const counts = new Map();
  const generations = new Map();
  const logins = new Map();
  const seen = new Map();
  return {
    getByName(name) {
      return {
        async bump(limit) {
          const used = (counts.get(name) ?? 0) + 1;
          if (used > limit) return false;
          counts.set(name, used);
          return true;
        },
        // Same pure transitions the real RateCounter applies; these methods
        // contain no await between read and write, so like the real object
        // each call is atomic with respect to the others.
        async loginReserve(policy, options) {
          const result = reserveAttempt(logins.get(name), Date.now(), policy, options);
          if (result.waitSeconds === 0 && !result.captchaRequired) logins.set(name, result.state);
          return { waitSeconds: result.waitSeconds, trusted: result.trusted, captchaRequired: result.captchaRequired };
        },
        async loginRefund(policy) { if (logins.has(name)) logins.set(name, refundAttempt(logins.get(name), policy)); },
        ...accountGenerationMethods(name, generations, getData),
        async seenContext(key, { maxEntries, ttlSeconds }) {
          const result = touchSeenContext(seen.get(name), key, Date.now(), maxEntries, ttlSeconds);
          seen.set(name, result.state);
          return { isNew: result.isNew, wasEmpty: result.wasEmpty };
        },
        async loginTrust() { logins.set(name, trustPair(logins.get(name), Date.now())); },
      };
    },
  };
}

function environment({ strictSessions = false } = {}) {
  const values = new Map();
  const env = {
    STUDIQUO_DATA: {
      async get(key, type) {
        let value = values.get(key) ?? null;
        // These tests aren't exercising session-authenticity enforcement
        // itself (see "requireRealSession" tests below, which pass
        // `strictSessions: true` to opt out of this) — treat any
        // well-formed bearer token as if it came from a real sign-in, so
        // freshToken()'s many call sites don't each need to seed one by hand.
        if (value === null && !strictSessions && key.startsWith("session:")) {
          value = JSON.stringify({ sub: "test", issuedAt: Math.floor(Date.now() / 1000) });
        }
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) {
        return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true };
      },
    },
    CHAT_ROOM: { getByName() { throw new Error("not used in these tests"); } },
    RATE_LIMIT_APPLE_AUTH: fakeCloudflareLimiter(),
    RATE_LIMIT_GOOGLE_AUTH: fakeCloudflareLimiter(),
    RATE_LIMIT_EMAIL_VERIFY_SEND: fakeCloudflareLimiter(),
    RATE_LIMIT_EMAIL_VERIFY_CONFIRM: fakeCloudflareLimiter(),
    RATE_LIMIT_LOCAL_LOGIN: fakeCloudflareLimiter(),
    RATE_LIMIT_ISSUE_REPORT: fakeCloudflareLimiter(),
    RATE_COUNTER: fakeRateCounterBinding(() => env.STUDIQUO_DATA),
    // Never reach the real HIBP from tests: by default nothing is breached.
    PWNED_PASSWORDS_FETCH: async () => new Response("", { status: 200 }),
    RESEND_API_KEY: "test-key",
  };
  return env;
}

const noopCtx = { waitUntil() {} };

// Tokens are "<issued-at epoch seconds>.<random secret>"; freshToken() mints
// one that was "just issued" so tests aren't tripped up by the expiry check.
function freshToken(suffix) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;
}

function request(path, { method = "GET", token, body, ip } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  if (ip) headers["cf-connecting-ip"] = ip;
  return new Request(`https://example.test${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

// Sign in with Apple test fixtures: a throwaway RSA keypair standing in for
// Apple's own signing key, same approach as apple-auth.test.js.
async function makeAppleSigningKey() {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  jwk.kid = "test-key-1";
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { privateKey, jwk };
}

async function seedAppleJWKS(env, jwk) {
  await env.STUDIQUO_DATA.put("apple:jwks", JSON.stringify({ keys: [jwk] }));
}

function signAppleIdentityToken(privateKey, kid, { sub, email, isPrivateEmail, emailVerified } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub };
  if (email !== undefined) claims.email = email;
  if (isPrivateEmail !== undefined) claims.is_private_email = isPrivateEmail;
  if (emailVerified !== undefined) claims.email_verified = emailVerified;
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer("https://appleid.apple.com")
    .setAudience("com.yabuko.studiquo")
    .setIssuedAt(now)
    .setExpirationTime(now + 600)
    .sign(privateKey);
}

// Google Sign-In test fixtures, mirroring the Apple ones above.
async function makeGoogleSigningKey() {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  jwk.kid = "test-key-1";
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { privateKey, jwk };
}

async function seedGoogleJWKS(env, jwk) {
  await env.STUDIQUO_DATA.put("google:jwks", JSON.stringify({ keys: [jwk] }));
}

function signGoogleIdentityToken(privateKey, kid, { sub, email, emailVerified } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub };
  if (email !== undefined) claims.email = email;
  if (emailVerified !== undefined) claims.email_verified = emailVerified;
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer("https://accounts.google.com")
    .setAudience("812858933445-q6j9uih0o702884hemnk2okiet26gv1j.apps.googleusercontent.com")
    .setIssuedAt(now)
    .setExpirationTime(now + 600)
    .sign(privateKey);
}

async function revokeToken(env, token) {
  const response = await worker.fetch(request("/api/session/revoke", { method: "POST", token }), env, noopCtx);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { revoked: true });
}

test("a previously issued token is rejected by /api/* endpoints after logout revokes it", async () => {
  const env = environment();
  const token = freshToken("a");

  // Works before logout.
  const before = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(before.status, 200);

  await revokeToken(env, token);

  // Rejected after logout, on an endpoint that has nothing to do with revocation itself.
  const after = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(after.status, 401);
  assert.match((await after.json()).error, /revoked/i);
});

test("POST /api/session/revoke is the endpoint logout calls, and it actually revokes the caller's own token", async () => {
  const env = environment();
  const token = freshToken("b");

  const response = await worker.fetch(request("/api/session/revoke", { method: "POST", token }), env, noopCtx);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { revoked: true });

  const reused = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(reused.status, 401);
});

test("DELETE /api/account removes every linked login identity and invalidates all sessions", async () => {
  const env = environment({ strictSessions: true });
  const appleToken = freshToken("da");
  const googleToken = freshToken("dg");
  const appleHash = sha256Hex(appleToken);
  const googleHash = sha256Hex(googleToken);
  const canonical = "apple-delete-sub";
  await env.STUDIQUO_DATA.put(`session:${appleHash}`, JSON.stringify({ sub: canonical }));
  await env.STUDIQUO_DATA.put(`session:${googleHash}`, JSON.stringify({ sub: "google:delete-sub" }));
  await env.STUDIQUO_DATA.put("identity-canonical:apple-delete-sub", canonical);
  await env.STUDIQUO_DATA.put("identity-canonical:google:delete-sub", canonical);
  await env.STUDIQUO_DATA.put("email-account-owner:delete@example.com", canonical);
  await env.STUDIQUO_DATA.put("email-accounts:delete@example.com", JSON.stringify([
    { provider: "apple", sub: "apple-delete-sub" },
    { provider: "google", sub: "delete-sub" },
    { provider: "email", sub: "delete@example.com" },
  ]));
  await env.STUDIQUO_DATA.put("account:apple-delete-sub", "{}");
  await env.STUDIQUO_DATA.put("account:google:delete-sub", "{}");
  await env.STUDIQUO_DATA.put("account:local:delete@example.com", "{}");

  const response = await worker.fetch(request("/api/account", {
    method: "DELETE", token: googleToken, body: { confirmation: "DELETE" },
  }), env, noopCtx);

  assert.equal(response.status, 202);
  assert.deepEqual(await response.json(), { deleted: true, externalDeletionPending: true });
  for (const key of [
    `session:${appleHash}`, `session:${googleHash}`,
    "identity-canonical:apple-delete-sub", "identity-canonical:google:delete-sub",
    "email-account-owner:delete@example.com", "email-accounts:delete@example.com",
    "account:apple-delete-sub", "account:google:delete-sub", "account:local:delete@example.com",
  ]) assert.equal(await env.STUDIQUO_DATA.get(key), null, `${key} should be deleted`);
  assert.equal((await worker.fetch(request("/api/actions", { token: appleToken }), env, noopCtx)).status, 401);
  assert.equal((await worker.fetch(request("/api/actions", { token: googleToken }), env, noopCtx)).status, 401);

  const google = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, google.jwk);
  const idToken = await signGoogleIdentityToken(google.privateKey, google.jwk.kid, {
    sub: "delete-sub", email: "delete@example.com", emailVerified: true,
  });
  const recreated = await worker.fetch(request("/api/auth/google", {
    method: "POST", body: { idToken, randomValue: "n".repeat(40) },
  }), env, noopCtx);
  assert.equal(recreated.status, 200);
  const recreatedToken = (await recreated.json()).token;
  assert.equal((await realSession(env, recreatedToken)).sub, "google:delete-sub");
  assert.deepEqual(await env.STUDIQUO_DATA.get("email-accounts:delete@example.com", "json"), [
    { provider: "google", sub: "delete-sub" },
  ]);
});

test("7. confirmationが未指定またはDELETE以外なら何も削除されない", async () => {
  const env = environment({ strictSessions: true });
  const token = freshToken("dc");
  await env.STUDIQUO_DATA.put(`session:${sha256Hex(token)}`, JSON.stringify({ sub: "account-1" }));
  const response = await worker.fetch(request("/api/account", {
    method: "DELETE", token, body: { confirmation: "wrong" },
  }), env, noopCtx);
  assert.equal(response.status, 400);
  assert.notEqual(await env.STUDIQUO_DATA.get(`session:${sha256Hex(token)}`), null);
});

test("8. 未認証・期限切れ・失効済みセッションではアカウントを削除できない", async () => {
  const env = environment({ strictSessions: true });
  const activeToken = freshToken("dx");
  const activeKey = `session:${sha256Hex(activeToken)}`;
  await env.STUDIQUO_DATA.put(activeKey, JSON.stringify({ sub: "protected-account" }));
  await env.STUDIQUO_DATA.put("account:protected-account", "{}");

  const unauthenticated = await worker.fetch(request("/api/account", {
    method: "DELETE", body: { confirmation: "DELETE" },
  }), env, noopCtx);
  assert.equal(unauthenticated.status, 401);

  const expiredToken = `${Math.floor(Date.now() / 1000) - 91 * 24 * 60 * 60}.${"e".repeat(40)}`;
  await env.STUDIQUO_DATA.put(`session:${sha256Hex(expiredToken)}`, JSON.stringify({ sub: "protected-account" }));
  const expired = await worker.fetch(request("/api/account", {
    method: "DELETE", token: expiredToken, body: { confirmation: "DELETE" },
  }), env, noopCtx);
  assert.equal(expired.status, 401);

  await revokeToken(env, activeToken);
  const revoked = await worker.fetch(request("/api/account", {
    method: "DELETE", token: activeToken, body: { confirmation: "DELETE" },
  }), env, noopCtx);
  assert.equal(revoked.status, 401);
  assert.notEqual(await env.STUDIQUO_DATA.get("account:protected-account"), null);
});

test("a revoked token can no longer reach synced cloud data via /mcp, even though it could before", async () => {
  const env = environment();
  const token = freshToken("c");

  const upload = await worker.fetch(
    request("/api/snapshot", { method: "PUT", token, body: { version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" } }),
    env,
    noopCtx
  );
  assert.equal(upload.status, 200);

  await revokeToken(env, token);

  const mcpAfterLogout = await worker.fetch(request("/mcp", { method: "POST", token }), env, noopCtx);
  assert.equal(mcpAfterLogout.status, 401);
  assert.match((await mcpAfterLogout.json()).error, /revoked/i);
});

test("revoking one device's token does not affect a different device's token", async () => {
  const env = environment();
  const deviceA = freshToken("d");
  const deviceB = freshToken("e");

  await revokeToken(env, deviceA);

  const stillWorks = await worker.fetch(request("/api/actions", { token: deviceB }), env, noopCtx);
  assert.equal(stillWorks.status, 200);
  assert.deepEqual(await stillWorks.json(), []);
});

test("a token older than 90 days is rejected by /api/* endpoints", async () => {
  const env = environment();
  const ninetyOneDaysAgo = Math.floor(Date.now() / 1000) - 91 * 24 * 60 * 60;
  const token = `${ninetyOneDaysAgo}.${"f".repeat(40)}`;

  const response = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /expired/i);
});

// Regression coverage for a real gap: unlike every other route in this
// Worker, /mcp handed the raw request straight to the MCP SDK's transport,
// which reads the body with no size limit of its own. Reachable only with a
// real, synced session — but there's no reason this route alone should skip
// the same body-size defense every other one gets.
test("a POST to /mcp with an oversized body is rejected with 413 instead of being handed unbounded to the MCP SDK", async () => {
  const env = environment();
  const token = freshToken("mcp1");

  const upload = await worker.fetch(
    request("/api/snapshot", { method: "PUT", token, body: { version: 1, notebooks: [], exportedAt: "2026-01-01T00:00:00Z" } }),
    env,
    noopCtx
  );
  assert.equal(upload.status, 200);

  const oversized = new Request("https://example.test/mcp", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: "x".repeat(9_000_000),
  });
  const response = await worker.fetch(oversized, env, noopCtx);
  assert.equal(response.status, 413);
});

test("a token older than 90 days is rejected by /mcp, even with a synced snapshot", async () => {
  const env = environment();
  const ninetyOneDaysAgo = Math.floor(Date.now() / 1000) - 91 * 24 * 60 * 60;
  const token = `${ninetyOneDaysAgo}.${"g".repeat(40)}`;

  const response = await worker.fetch(request("/mcp", { method: "POST", token }), env, noopCtx);
  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /expired/i);
});

test("a token just under 90 days old is still accepted", async () => {
  const env = environment();
  const eightyNineDaysAgo = Math.floor(Date.now() / 1000) - 89 * 24 * 60 * 60;
  const token = `${eightyNineDaysAgo}.${"h".repeat(40)}`;

  const response = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(response.status, 200);
});

test("POST /api/auth/apple: first sign-in creates the account and a matching session", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk);
  const identityToken = await signAppleIdentityToken(privateKey, jwk.kid, {
    sub: "000123.apple-sub.4567",
    email: "hidden@privaterelay.appleid.com",
    isPrivateEmail: true,
  });
  const randomValue = "r".repeat(40);
  const beforeRequest = Math.floor(Date.now() / 1000);

  const response = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken, randomValue } }),
    env,
    noopCtx
  );

  assert.equal(response.status, 200);
  const { token } = await response.json();
  assert.match(token, /^\d+\.r{40}$/);
  const issuedAt = Number(token.split(".")[0]);
  assert.ok(issuedAt >= beforeRequest);

  const account = await env.STUDIQUO_DATA.get("account:000123.apple-sub.4567", "json");
  assert.equal(account.sub, "000123.apple-sub.4567");
  assert.equal(account.email, "hidden@privaterelay.appleid.com");
  assert.equal(account.emailIsPrivateRelay, true);
  assert.ok(account.createdAt);

  const session = await env.STUDIQUO_DATA.get(`session:${sha256Hex(token)}`, "json");
  assert.deepEqual(session, { sub: "000123.apple-sub.4567", issuedAt });
});

test("POST /api/auth/apple: a later sign-in does not overwrite the account's stored email", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk);
  const sub = "000123.apple-sub.9999";

  const firstToken = await signAppleIdentityToken(privateKey, jwk.kid, {
    sub,
    email: "hidden@privaterelay.appleid.com",
    isPrivateEmail: true,
  });
  const first = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: firstToken, randomValue: "a".repeat(40) } }),
    env,
    noopCtx
  );
  assert.equal(first.status, 200);

  // Subsequent Apple sign-ins omit `email`/`is_private_email` entirely, as
  // Apple itself does after the first authorization.
  const secondToken = await signAppleIdentityToken(privateKey, jwk.kid, { sub });
  const second = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: secondToken, randomValue: "b".repeat(40) } }),
    env,
    noopCtx
  );
  assert.equal(second.status, 200);

  const account = await env.STUDIQUO_DATA.get(`account:${sub}`, "json");
  assert.equal(account.email, "hidden@privaterelay.appleid.com");
  assert.equal(account.emailIsPrivateRelay, true);
});

test("POST /api/auth/apple: an invalid identityToken is rejected with 401", async () => {
  const env = environment();
  const { jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk);

  const response = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: "not-a-real-jwt", randomValue: "c".repeat(40) } }),
    env,
    noopCtx
  );

  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /invalid/i);
  assert.equal(await env.STUDIQUO_DATA.get("account:not-a-real-jwt"), null);
});

// MARK: - Rate limiting: /api/auth/apple is callable with no bearer token at
// all (it's what mints one), so it's gated by rate-limit.js's two-layer
// (Cloudflare binding + KV) check instead.

test("POST /api/auth/apple: allows up to the limit, then 429s, even against invalid tokens", async () => {
  const env = environment();
  const { jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk); // avoids a real network fetch to Apple for every garbage-token attempt below
  const attempt = () => worker.fetch(
    request("/api/auth/apple", { method: "POST", ip: "203.0.113.1", body: { identityToken: "garbage", randomValue: "d".repeat(40) } }),
    env,
    noopCtx
  );

  for (let i = 0; i < 5; i++) {
    assert.equal((await attempt()).status, 401);
  }
  const sixth = await attempt();
  assert.equal(sixth.status, 429);
});

test("POST /api/auth/apple: a different client IP is not affected by another IP's limit", async () => {
  const env = environment();
  const { jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk);
  const attempt = ip => worker.fetch(
    request("/api/auth/apple", { method: "POST", ip, body: { identityToken: "garbage", randomValue: "e".repeat(40) } }),
    env,
    noopCtx
  );

  for (let i = 0; i < 5; i++) {
    assert.equal((await attempt("203.0.113.1")).status, 401);
  }
  assert.equal((await attempt("203.0.113.1")).status, 429);

  assert.equal((await attempt("198.51.100.1")).status, 401);
});

// MARK: - Google Sign-In

test("POST /api/auth/google: first sign-in creates the account and a matching session", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, jwk);
  const idToken = await signGoogleIdentityToken(privateKey, jwk.kid, {
    sub: "108234567890123456789",
    email: "person@example.com",
    emailVerified: true,
  });
  const randomValue = "r".repeat(40);
  const beforeRequest = Math.floor(Date.now() / 1000);

  const response = await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken, randomValue } }),
    env,
    noopCtx
  );

  assert.equal(response.status, 200);
  const { token } = await response.json();
  assert.match(token, /^\d+\.r{40}$/);
  const issuedAt = Number(token.split(".")[0]);
  assert.ok(issuedAt >= beforeRequest);

  const account = await env.STUDIQUO_DATA.get("account:google:108234567890123456789", "json");
  assert.equal(account.sub, "108234567890123456789");
  assert.equal(account.email, "person@example.com");
  assert.equal(account.emailVerified, true);
  assert.ok(account.createdAt);

  const session = await env.STUDIQUO_DATA.get(`session:${sha256Hex(token)}`, "json");
  assert.deepEqual(session, { sub: "google:108234567890123456789", issuedAt });
});

test("POST /api/auth/google: an invalid idToken is rejected with 401", async () => {
  const env = environment();
  const { jwk } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, jwk);

  const response = await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken: "not-a-real-jwt", randomValue: "c".repeat(40) } }),
    env,
    noopCtx
  );

  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /invalid/i);
});

test("POST /api/auth/google: allows up to the limit, then 429s, even against invalid tokens", async () => {
  const env = environment();
  const { jwk } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, jwk);
  const attempt = () => worker.fetch(
    request("/api/auth/google", { method: "POST", ip: "203.0.113.1", body: { idToken: "garbage", randomValue: "d".repeat(40) } }),
    env,
    noopCtx
  );

  for (let i = 0; i < 5; i++) {
    assert.equal((await attempt()).status, 401);
  }
  const sixth = await attempt();
  assert.equal(sixth.status, 429);
});

// MARK: - Cross-provider account linking by verified email

test("Apple and Google sign-ins with the same verified email authenticate as one canonical account", async () => {
  const env = environment();
  const { privateKey: applePrivateKey, jwk: appleJWK } = await makeAppleSigningKey();
  await seedAppleJWKS(env, appleJWK);
  const appleToken = await signAppleIdentityToken(applePrivateKey, appleJWK.kid, {
    sub: "000123.apple-sub.4567",
    email: "person@example.com",
    isPrivateEmail: false,
    emailVerified: true,
  });
  const appleResponse = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: appleToken, randomValue: "a".repeat(40) } }),
    env,
    noopCtx
  );
  const { token: appleSessionToken } = await appleResponse.json();

  const { privateKey: googlePrivateKey, jwk: googleJWK } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, googleJWK);
  const googleToken = await signGoogleIdentityToken(googlePrivateKey, googleJWK.kid, {
    sub: "108234567890123456789",
    email: "person@example.com",
    emailVerified: true,
  });
  const googleResponse = await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken: googleToken, randomValue: "b".repeat(40) } }),
    env,
    noopCtx
  );
  const { token: googleSessionToken } = await googleResponse.json();

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.deepEqual(linked, [
    { provider: "apple", sub: "000123.apple-sub.4567" },
    { provider: "google", sub: "108234567890123456789" },
  ]);
  assert.equal((await realSession(env, appleSessionToken)).sub, "000123.apple-sub.4567");
  assert.equal(
    (await realSession(env, googleSessionToken)).sub,
    "000123.apple-sub.4567",
    "same verified email must authenticate both providers as one account"
  );
});

test("an Apple sign-in whose token omits email_verified does not create a link", async () => {
  const env = environment();
  const { privateKey: applePrivateKey, jwk: appleJWK } = await makeAppleSigningKey();
  await seedAppleJWKS(env, appleJWK);
  // No `emailVerified` passed here, so the signed token has no
  // email_verified claim at all — linkVerifiedEmail must treat that the
  // same as "not verified" rather than assuming the best.
  const appleToken = await signAppleIdentityToken(applePrivateKey, appleJWK.kid, {
    sub: "000123.apple-sub.4567",
    email: "person@example.com",
    isPrivateEmail: false,
  });
  await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: appleToken, randomValue: "a".repeat(40) } }),
    env,
    noopCtx
  );

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.equal(linked, null);
  // The account record itself is still created as normal — only the
  // cross-provider link is skipped.
  const account = await env.STUDIQUO_DATA.get("account:000123.apple-sub.4567", "json");
  assert.equal(account.email, "person@example.com");
});

// MARK: - Local email/password verification

function stubResendCapturingCode() {
  let capturedCode = null;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    const match = /確認コード: (\d{6})/.exec(JSON.parse(init.body).text);
    capturedCode = match[1];
    return new Response("{}", { status: 200 });
  };
  return { restore: () => { globalThis.fetch = originalFetch; }, code: () => capturedCode };
}

test("POST /api/auth/email/send-code then /confirm-code links the email under provider \"email\"", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();

  const sendResponse = await worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );
  stub.restore();
  assert.equal(sendResponse.status, 200);
  assert.deepEqual(await sendResponse.json(), { sent: true });

  const confirmResponse = await worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email: "person@example.com", code: stub.code(), password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );
  assert.equal(confirmResponse.status, 200);
  const { verified, token } = await confirmResponse.json();
  assert.equal(verified, true);
  assert.match(token, /^\d+\.r{40}$/);

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.deepEqual(linked, [{ provider: "email", sub: "person@example.com" }]);
});

test("POST /api/auth/email/confirm-code: a wrong code is rejected with 401 and does not link anything", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();
  await worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );
  stub.restore();

  const response = await worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email: "person@example.com", code: "000000", password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );

  assert.equal(response.status, 401);
  const payload = await response.json();
  assert.match(payload.error, /incorrect or expired/i);
  assert.equal(payload.attemptsRemaining, 4);
  assert.equal(await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json"), null);
});

test("POST /api/auth/email/send-code: rejects a missing email with 400 rather than calling Resend", async () => {
  const env = environment();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error("should not call Resend"); };
  try {
    const response = await worker.fetch(
      request("/api/auth/email/send-code", { method: "POST", body: {} }),
      env,
      noopCtx
    );
    assert.equal(response.status, 400);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("POST /api/auth/email/send-code: allows up to the limit, then 429s", async () => {
  const env = environment();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("{}", { status: 200 });
  const attempt = () => worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", ip: "203.0.113.5", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );

  try {
    for (let i = 0; i < 5; i++) {
      assert.equal((await attempt()).status, 200);
    }
    assert.equal((await attempt()).status, 429);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("POST /api/auth/email/send-code: per-email limit holds across different IPs", async () => {
  const env = environment();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("{}", { status: 200 });
  const attempt = (ip, email = "person@example.com") => worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", ip, body: { email } }),
    env,
    noopCtx
  );

  try {
    for (let i = 0; i < 5; i++) {
      assert.equal((await attempt(`203.0.113.${i + 1}`)).status, 200);
    }
    // A sixth, from an IP that has sent nothing yet, is still refused.
    assert.equal((await attempt("198.51.100.77")).status, 429);
    // Case and whitespace don't make it a different address.
    assert.equal((await attempt("198.51.100.78", "  Person@Example.com ")).status, 429);
    // Another mailbox is unaffected.
    assert.equal((await attempt("198.51.100.79", "other@example.com")).status, 200);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("POST /api/auth/email/confirm-code: per-email attempts persist across resends and refuse even the right code", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();
  const send = () => worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );
  const confirm = (ip, code) => worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      ip,
      body: { email: "person@example.com", code, password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );

  try {
    // 10 wrong guesses spread over several IPs and two resends: each resend
    // resets the code's own attempt count, but not the per-email budget.
    await send();
    for (let i = 0; i < 4; i++) assert.equal((await confirm(`203.0.113.${i + 1}`, "000000")).status, 401);
    await send();
    for (let i = 0; i < 4; i++) assert.equal((await confirm(`203.0.113.${i + 10}`, "000000")).status, 401);
    await send();
    for (let i = 0; i < 2; i++) assert.equal((await confirm(`203.0.113.${i + 20}`, "000000")).status, 401);

    // Budget spent: the genuine code is refused too, from a fresh IP.
    const response = await confirm("198.51.100.5", stub.code());
    assert.equal(response.status, 429);
    assert.equal(await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json"), null);
  } finally {
    stub.restore();
  }
});

test("email-code budgets: send and confirm are counted separately, per address, and confirm normalizes the address", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();
  // Each call comes from its own IP so only the per-email budget is in play.
  let ipCounter = 0;
  const nextIp = () => `203.0.113.${++ipCounter}`;
  const send = (email) => worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", ip: nextIp(), body: { email } }),
    env,
    noopCtx
  );
  const confirm = (email, code) => worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      ip: nextIp(),
      body: { email, code, password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );

  try {
    // Exhaust person@'s send budget; its confirm budget and other@'s are untouched.
    for (let i = 0; i < 5; i++) assert.equal((await send("person@example.com")).status, 200);
    assert.equal((await send("person@example.com")).status, 429);
    assert.equal((await send("person+alias@example.com")).status, 200);
    assert.notEqual((await confirm("person@example.com", "000000")).status, 429);

    // Exhaust person@'s confirm budget through a differently cased spelling.
    for (let i = 0; i < 9; i++) await confirm("  PERSON@Example.com ", "000000");
    assert.equal((await confirm("person@example.com", "000000")).status, 429);
    assert.notEqual((await confirm("other@example.com", "000000")).status, 429);
  } finally {
    stub.restore();
  }
});

test("POST /api/auth/email/confirm-code: a breached password is refused and the emailed code stays usable", async () => {
  const env = environment();
  // SHA-1("breached-password-1") is looked up by prefix; answer as if its suffix were in the corpus.
  const hibpCalls = [];
  env.PWNED_PASSWORDS_FETCH = async (url) => {
    hibpCalls.push(url);
    const digest = createHash("sha1").update("breached-password-1").digest("hex").toUpperCase();
    return new Response(url.endsWith(digest.slice(0, 5)) ? `${digest.slice(5)}:42\r\n` : "", { status: 200 });
  };
  const stub = stubResendCapturingCode();
  await worker.fetch(request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }), env, noopCtx);
  stub.restore();
  const confirm = (password) => worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email: "person@example.com", code: stub.code(), password, randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );

  const refused = await confirm("breached-password-1");
  assert.equal(refused.status, 400);
  const refusedBody = await refused.json();
  assert.equal(refusedBody.code, "password_breached");
  assert.equal(await env.STUDIQUO_DATA.get("account:local:person@example.com"), null);
  assert.ok(hibpCalls.every(url => /\/range\/[0-9A-F]{5}$/.test(url)));

  // The code wasn't spent or counted: a different password with the same code works.
  const accepted = await confirm("a-different-long-password");
  assert.equal(accepted.status, 200);
});

test("POST /api/auth/email/confirm-code: if HIBP is unreachable the password is accepted", async () => {
  const env = environment();
  env.PWNED_PASSWORDS_FETCH = async () => { throw new Error("network down"); };
  const originalError = console.error;
  console.error = () => {};
  const stub = stubResendCapturingCode();
  try {
    await worker.fetch(request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }), env, noopCtx);
    stub.restore();
    const response = await worker.fetch(
      request("/api/auth/email/confirm-code", {
        method: "POST",
        body: { email: "person@example.com", code: stub.code(), password: "correct-horse-battery", randomValue: "r".repeat(40) },
      }),
      env,
      noopCtx
    );
    assert.equal(response.status, 200);
  } finally {
    console.error = originalError;
  }
});

test("local and Google sign-ins with the same verified email authenticate as one canonical account", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();
  await worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );
  stub.restore();
  const localResponse = await worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email: "person@example.com", code: stub.code(), password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );
  const { token: localSessionToken } = await localResponse.json();

  const { privateKey, jwk } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, jwk);
  const idToken = await signGoogleIdentityToken(privateKey, jwk.kid, {
    sub: "108234567890123456789",
    email: "person@example.com",
    emailVerified: true,
  });
  const googleResponse = await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken, randomValue: "g".repeat(40) } }),
    env,
    noopCtx
  );
  const { token: googleSessionToken } = await googleResponse.json();

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.deepEqual(linked, [
    { provider: "email", sub: "person@example.com" },
    { provider: "google", sub: "108234567890123456789" },
  ]);
  assert.equal((await realSession(env, localSessionToken)).sub, "email:person@example.com");
  assert.equal((await realSession(env, googleSessionToken)).sub, "email:person@example.com");
});

// MARK: - Local email/password login

async function createLocalAccount(env, email, password) {
  const stub = stubResendCapturingCode();
  await worker.fetch(request("/api/auth/email/send-code", { method: "POST", body: { email } }), env, noopCtx);
  stub.restore();
  const response = await worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email, code: stub.code(), password, randomValue: "s".repeat(40) },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 200);
  return response.json();
}

async function signInAppleForTest(env, privateKey, kid, claims, randomValue = "a".repeat(40)) {
  const identityToken = await signAppleIdentityToken(privateKey, kid, claims);
  const response = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken, randomValue } }), env, noopCtx
  );
  assert.equal(response.status, 200);
  return response.json();
}

async function signInGoogleForTest(env, privateKey, kid, claims, randomValue = "g".repeat(40)) {
  const idToken = await signGoogleIdentityToken(privateKey, kid, claims);
  const response = await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken, randomValue } }), env, noopCtx
  );
  assert.equal(response.status, 200);
  return response.json();
}

async function localLoginForTest(env, email, password, randomValue = "l".repeat(40)) {
  const response = await worker.fetch(
    request("/api/auth/local/login", { method: "POST", body: { email, password, randomValue } }), env, noopCtx
  );
  assert.equal(response.status, 200);
  return response.json();
}

test("Google remains the canonical account when Apple and local sign-ins are added later", async () => {
  const env = environment();
  const google = await makeGoogleSigningKey();
  const apple = await makeAppleSigningKey();
  await seedGoogleJWKS(env, google.jwk);
  await seedAppleJWKS(env, apple.jwk);

  const googleLogin = await signInGoogleForTest(env, google.privateKey, google.jwk.kid, {
    sub: "google-first", email: "person@example.com", emailVerified: true,
  });
  const appleLogin = await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-second", email: "person@example.com", isPrivateEmail: false, emailVerified: true,
  });
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  const localLogin = await localLoginForTest(env, "person@example.com", "correct-horse-battery");

  for (const login of [googleLogin, appleLogin, localLogin]) {
    assert.equal((await realSession(env, login.token)).sub, "google:google-first");
  }
});

test("Apple, Google, and local sign-ins with one verified email share one account", async () => {
  const env = environment();
  const apple = await makeAppleSigningKey();
  const google = await makeGoogleSigningKey();
  await seedAppleJWKS(env, apple.jwk);
  await seedGoogleJWKS(env, google.jwk);

  const appleLogin = await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-owner", email: "all@example.com", isPrivateEmail: false, emailVerified: true,
  });
  const googleLogin = await signInGoogleForTest(env, google.privateKey, google.jwk.kid, {
    sub: "google-linked", email: "all@example.com", emailVerified: true,
  });
  const localLogin = await createLocalAccount(env, "all@example.com", "correct-horse-battery");

  const subjects = await Promise.all([appleLogin, googleLogin, localLogin].map(async login =>
    (await realSession(env, login.token)).sub
  ));
  assert.deepEqual(subjects, ["apple-owner", "apple-owner", "apple-owner"]);
});

test("different verified emails are not merged", async () => {
  const env = environment();
  const apple = await makeAppleSigningKey();
  const google = await makeGoogleSigningKey();
  await seedAppleJWKS(env, apple.jwk);
  await seedGoogleJWKS(env, google.jwk);

  const appleLogin = await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-distinct", email: "apple@example.com", isPrivateEmail: false, emailVerified: true,
  });
  const googleLogin = await signInGoogleForTest(env, google.privateKey, google.jwk.kid, {
    sub: "google-distinct", email: "google@example.com", emailVerified: true,
  });

  assert.equal((await realSession(env, appleLogin.token)).sub, "apple-distinct");
  assert.equal((await realSession(env, googleLogin.token)).sub, "google:google-distinct");
});

test("Apple private relay email is not merged with Google or local accounts", async () => {
  const env = environment();
  const apple = await makeAppleSigningKey();
  const google = await makeGoogleSigningKey();
  await seedAppleJWKS(env, apple.jwk);
  await seedGoogleJWKS(env, google.jwk);

  const appleLogin = await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-relay", email: "relay@privaterelay.appleid.com", isPrivateEmail: true, emailVerified: true,
  });
  const googleLogin = await signInGoogleForTest(env, google.privateKey, google.jwk.kid, {
    sub: "google-real", email: "person@example.com", emailVerified: true,
  });
  const localLogin = await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  assert.equal((await realSession(env, appleLogin.token)).sub, "apple-relay");
  assert.equal((await realSession(env, googleLogin.token)).sub, "google:google-real");
  assert.equal((await realSession(env, localLogin.token)).sub, "google:google-real");
  assert.equal(await env.STUDIQUO_DATA.get("email-accounts:relay@privaterelay.appleid.com"), null);
});

test("a later Apple login without email restores the shared account from the saved email", async () => {
  const env = environment();
  const apple = await makeAppleSigningKey();
  const google = await makeGoogleSigningKey();
  await seedAppleJWKS(env, apple.jwk);
  await seedGoogleJWKS(env, google.jwk);
  await signInGoogleForTest(env, google.privateKey, google.jwk.kid, {
    sub: "google-owner", email: "person@example.com", emailVerified: true,
  });
  await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-repeat", email: "person@example.com", isPrivateEmail: false, emailVerified: true,
  });

  const repeated = await signInAppleForTest(env, apple.privateKey, apple.jwk.kid, {
    sub: "apple-repeat",
  }, "z".repeat(40));

  assert.equal((await realSession(env, repeated.token)).sub, "google:google-owner");
});

test("POST /api/auth/local/login: the correct password mints a working token", async () => {
  const env = environment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  const response = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "person@example.com", password: "correct-horse-battery", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );

  assert.equal(response.status, 200);
  const { token } = await response.json();
  assert.match(token, /^\d+\.l{40}$/);

  // The minted token actually works against an ordinary gated endpoint.
  const actions = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(actions.status, 200);
});

test("POST /api/auth/local/login: the wrong password is rejected with 401", async () => {
  const env = environment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  const response = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "person@example.com", password: "wrong-password", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );

  assert.equal(response.status, 401);
});

test("POST /api/auth/local/login: an email with no account is rejected with 401, not 500", async () => {
  const env = environment();

  const response = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "nobody@example.com", password: "whatever-password", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );

  assert.equal(response.status, 401);
});

test("POST /api/auth/local/login: resetting the password (via confirm-code again) invalidates the old one", async () => {
  const env = environment();
  await createLocalAccount(env, "person@example.com", "first-password");
  await createLocalAccount(env, "person@example.com", "second-password");

  const withOldPassword = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "person@example.com", password: "first-password", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );
  assert.equal(withOldPassword.status, 401);

  const withNewPassword = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "person@example.com", password: "second-password", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );
  assert.equal(withNewPassword.status, 200);
});

test("POST /api/auth/local/login: allows up to the limit, then 429s", async () => {
  const env = environment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  const attempt = () => worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      ip: "203.0.113.9",
      body: { email: "person@example.com", password: "wrong-password", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );

  // The fake Cloudflare rate-limit binding below defaults to a cap of 5
  // (see fakeCloudflareLimiter's default), same as every other endpoint's
  // rate-limit test in this file, even though RATE_LIMIT_LOCAL_LOGIN's own
  // configured limit in wrangler.jsonc is 10 — this test only exercises the
  // fake, not the real config.
  for (let i = 0; i < 5; i++) {
    assert.equal((await attempt()).status, 401);
  }
  assert.equal((await attempt()).status, 429);
});

// MARK: - local login: distributed credential stuffing

// The per-IP Cloudflare limiter (5/min in these fakes) would answer before
// the throttle under test ever runs; lift it so only the throttle is in play.
function throttleEnvironment() {
  const env = environment();
  env.RATE_LIMIT_LOCAL_LOGIN = fakeCloudflareLimiter(10_000);
  return env;
}

function loginAttempt(env, { email = "person@example.com", password = "wrong-password", ip, asn } = {}) {
  const req = request("/api/auth/local/login", {
    method: "POST",
    ip,
    body: { email, password, randomValue: "l".repeat(40) },
  });
  if (asn !== undefined) Object.defineProperty(req, "cf", { value: { asn } });
  return worker.fetch(req, env, noopCtx);
}

test("local login: one client failing repeatedly against one account gets an escalating wait, even with the right password", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  // 5 failures are free; the 6th starts the wait.
  for (let i = 0; i < 6; i++) assert.equal((await loginAttempt(env, { ip: "203.0.113.1" })).status, 401);

  const blocked = await loginAttempt(env, { ip: "203.0.113.1", password: "correct-horse-battery" });
  assert.equal(blocked.status, 429);
  assert.ok(Number(blocked.headers.get("retry-after")) > 0);
  assert.equal((await blocked.json()).error, "Too many attempts. Please try again later.");
});

test("local login: rotating IPs doesn't escape the per-account wait, and it ends in a wait rather than a lock", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  // 11 failures (10 are free), each from a different IP: no single IP+account streak trips.
  for (let i = 0; i < 11; i++) assert.equal((await loginAttempt(env, { ip: `198.51.100.${i + 1}` })).status, 401);

  // The next try, from yet another IP and with the correct password, is held.
  const held = await loginAttempt(env, { ip: "198.51.100.200", password: "correct-horse-battery" });
  assert.equal(held.status, 429);
  const retryAfter = Number(held.headers.get("retry-after"));
  assert.ok(retryAfter > 0 && retryAfter <= 900);

  // Another account is untouched.
  await createLocalAccount(env, "other@example.com", "another-long-password");
  const other = await loginAttempt(env, { email: "other@example.com", ip: "198.51.100.201", password: "another-long-password" });
  assert.equal(other.status, 200);
});

test("local login: an address with no account is throttled exactly like a real one", async () => {
  const env = throttleEnvironment();
  for (let i = 0; i < 6; i++) assert.equal((await loginAttempt(env, { email: "nobody@example.com", ip: "203.0.113.2" })).status, 401);
  assert.equal((await loginAttempt(env, { email: "nobody@example.com", ip: "203.0.113.2" })).status, 429);
});

test("local login: a success clears this client's streak and does not count as a failure", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  for (let i = 0; i < 4; i++) await loginAttempt(env, { ip: "203.0.113.3" });
  assert.equal((await loginAttempt(env, { ip: "203.0.113.3", password: "correct-horse-battery" })).status, 200);
  // Streak was cleared, so four more failures are still within the allowance.
  for (let i = 0; i < 4; i++) assert.equal((await loginAttempt(env, { ip: "203.0.113.3" })).status, 401);
});

test("local login: many failures from one ASN slow that ASN, but not a different one", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  // 101 failures (100 are free) against throwaway addresses, each from its own IP, so only the ASN key accumulates.
  for (let i = 0; i < 101; i++) {
    const response = await loginAttempt(env, { email: `n${i}@example.com`, ip: `10.1.${Math.floor(i / 200)}.${i % 200 + 1}`, asn: 64500 });
    assert.equal(response.status, 401);
  }
  const held = await loginAttempt(env, { ip: "10.9.9.9", asn: 64500, password: "correct-horse-battery" });
  assert.equal(held.status, 429);

  const elsewhere = await loginAttempt(env, { ip: "10.9.9.10", asn: 64501, password: "correct-horse-battery" });
  assert.equal(elsewhere.status, 200);
});

test("local login: parallel guesses can't all slip past a wait that hasn't been recorded yet", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  // 40 simultaneous wrong guesses, each from its own IP, against one account.
  const responses = await Promise.all(
    Array.from({ length: 40 }, (_, i) => loginAttempt(env, { ip: `198.51.100.${i + 1}` }))
  );
  const verified = responses.filter(response => response.status === 401).length;
  // Account key: 10 free attempts, plus the one that starts the wait.
  assert.equal(verified, 11);
  assert.equal(responses.filter(response => response.status === 429).length, 29);
});

test("local login: a blocked try is not itself counted as a failure", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  for (let i = 0; i < 6; i++) await loginAttempt(env, { ip: "203.0.113.4" });

  const first = await loginAttempt(env, { ip: "203.0.113.4" });
  const second = await loginAttempt(env, { ip: "203.0.113.4" });
  assert.equal(first.status, 429);
  assert.equal(second.status, 429);
  // Hammering while blocked must not push the wait further out.
  assert.ok(Number(second.headers.get("retry-after")) <= Number(first.headers.get("retry-after")));
});

test("local login: addresses differing only in case or whitespace share one throttle", async () => {
  const env = throttleEnvironment();
  for (let i = 0; i < 6; i++) {
    const email = i % 2 ? "  PERSON@Example.com " : "person@example.com";
    assert.equal((await loginAttempt(env, { email, ip: "203.0.113.5" })).status, 401);
  }
  assert.equal((await loginAttempt(env, { email: "Person@example.COM", ip: "203.0.113.5" })).status, 429);
});

test("local login: an IP that already signed in keeps working while strangers hammer the account", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  // The owner signs in from home once.
  assert.equal((await loginAttempt(env, { ip: "203.0.113.50", password: "correct-horse-battery" })).status, 200);

  // A botnet drives the account into its wait.
  for (let i = 0; i < 11; i++) await loginAttempt(env, { ip: `198.51.100.${i + 1}` });
  assert.equal((await loginAttempt(env, { ip: "198.51.100.99", password: "correct-horse-battery" })).status, 429);

  // The owner, from the IP they've used before, still gets in...
  assert.equal((await loginAttempt(env, { ip: "203.0.113.50", password: "correct-horse-battery" })).status, 200);
  // ...but a trusted IP isn't a free pass to guess: its own streak still escalates.
  for (let i = 0; i < 6; i++) await loginAttempt(env, { ip: "203.0.113.50" });
  assert.equal((await loginAttempt(env, { ip: "203.0.113.50", password: "correct-horse-battery" })).status, 429);
});

test("local login: failures from a trusted IP still count toward the shared account limit", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  assert.equal((await loginAttempt(env, { ip: "203.0.113.60", password: "correct-horse-battery" })).status, 200);

  // 3 wrong guesses from the trusted IP are never refused...
  for (let i = 0; i < 3; i++) assert.equal((await loginAttempt(env, { ip: "203.0.113.60" })).status, 401);
  // ...but they used up part of the account's 10 free attempts: 7 more from
  // strangers still pass, and the one after that (the 11th failure overall)
  // starts the wait, so the following attempt is held.
  for (let i = 0; i < 8; i++) assert.equal((await loginAttempt(env, { ip: `198.51.100.${i + 1}` })).status, 401);
  assert.equal((await loginAttempt(env, { ip: "198.51.100.90" })).status, 429);
});

test("local login: an over-long email is refused without creating throttle state", async () => {
  const env = throttleEnvironment();
  const response = await loginAttempt(env, { email: `${"a".repeat(300)}@example.com`, ip: "203.0.113.6" });
  assert.equal(response.status, 401);
});

// MARK: - local login: metrics and new-context notice

// A ctx that remembers what was handed to waitUntil, so a test can wait for
// the background monitoring to finish before asserting on it.
function collectingCtx() {
  const pending = [];
  return { waitUntil(promise) { pending.push(promise); }, flush: () => Promise.all(pending) };
}

function geoRequest(path, { cf, ip, body }) {
  const req = request(path, { method: "POST", ip, body });
  return Object.defineProperty(req, "cf", { value: cf });
}

test("local login: a sign-in from a new country+network emails the owner; the baseline and repeats don't", async () => {
  const env = throttleEnvironment();
  const home = { country: "JP", asn: 2516, region: "Tokyo", asOrganization: "KDDI" };
  const abroad = { country: "RO", asn: 9050, region: "Bucharest", asOrganization: "Some Hosting" };

  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const mails = [];
  const logs = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (body.text?.includes("確認コード")) mails.push({ kind: "code", body });
    else if (body.subject?.includes("新しい環境")) mails.push({ kind: "notice", body });
    const match = /確認コード: (\d{6})/.exec(body.text ?? "");
    globalThis.__code = match ? match[1] : globalThis.__code;
    return new Response("{}", { status: 200 });
  };
  console.log = line => logs.push(String(line));
  try {
    // Sign-up from home: baseline, no notice.
    let ctx = collectingCtx();
    await worker.fetch(geoRequest("/api/auth/email/send-code", { cf: home, ip: "203.0.113.70", body: { email: "person@example.com" } }), env, ctx);
    await worker.fetch(geoRequest("/api/auth/email/confirm-code", {
      cf: home, ip: "203.0.113.70",
      body: { email: "person@example.com", code: globalThis.__code, password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }), env, ctx);
    await ctx.flush();

    const login = async (cf, ip) => {
      const c = collectingCtx();
      const response = await worker.fetch(geoRequest("/api/auth/local/login", {
        cf, ip, body: { email: "person@example.com", password: "correct-horse-battery", randomValue: "l".repeat(40) },
      }), env, c);
      await c.flush();
      return response.status;
    };

    assert.equal(await login(home, "203.0.113.71"), 200);
    assert.equal(mails.filter(mail => mail.kind === "notice").length, 0);

    assert.equal(await login(abroad, "198.51.100.80"), 200);
    const notices = mails.filter(mail => mail.kind === "notice");
    assert.equal(notices.length, 1);
    assert.equal(notices[0].body.to, "person@example.com");
    assert.ok(!notices[0].body.text.includes("198.51.100.80"));

    assert.equal(await login(abroad, "198.51.100.81"), 200);
    assert.equal(mails.filter(mail => mail.kind === "notice").length, 1);

    const outcomes = logs.map(line => { try { return JSON.parse(line); } catch { return null; } }).filter(event => event?.event === "local_login");
    assert.deepEqual(outcomes.map(event => [event.outcome, event.newContext]), [["success", false], ["success", true], ["success", false]]);
    assert.ok(!logs.join("").includes("person@example.com"));
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    delete globalThis.__code;
  }
});

test("local login: failures and throttled tries are logged as outcomes, and a broken mail provider never breaks sign-in", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  const cf = { country: "US", asn: 7922 };

  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const originalError = console.error;
  const logs = [];
  globalThis.fetch = async () => new Response("no", { status: 500 });
  console.log = line => logs.push(String(line));
  console.error = () => {};
  try {
    const attempt = async (password, ip) => {
      const c = collectingCtx();
      const response = await worker.fetch(geoRequest("/api/auth/local/login", {
        cf, ip, body: { email: "person@example.com", password, randomValue: "l".repeat(40) },
      }), env, c);
      await c.flush();
      return response.status;
    };
    for (let i = 0; i < 6; i++) assert.equal(await attempt("wrong-password", "203.0.113.90"), 401);
    assert.equal(await attempt("wrong-password", "203.0.113.90"), 429);
    // A different IP, right password: the mail call fails (500) but sign-in succeeds.
    assert.equal(await attempt("correct-horse-battery", "203.0.113.91"), 200);

    const outcomes = logs.map(line => { try { return JSON.parse(line); } catch { return null; } })
      .filter(event => event?.event === "local_login").map(event => event.outcome);
    assert.deepEqual(outcomes, ["failure", "failure", "failure", "failure", "failure", "failure", "throttled", "success"]);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    console.error = originalError;
  }
});

// MARK: - CAPTCHA (Cloudflare Turnstile)

// A Turnstile that answers by token: "ok:<action>" is a solved challenge for
// that action, "down" simulates Cloudflare being unreachable, anything else is
// an invalid token.
//
// Turns CAPTCHA on for `env`. Call it AFTER any createLocalAccount(): that
// helper signs up through send-code, which would then want a CAPTCHA itself.
function enableCaptcha(env) {
  env.TURNSTILE_SECRET = "test-secret";
  env.TURNSTILE_SITE_KEY = "test-site-key";
  env.TURNSTILE_FETCH = async (_url, init) => {
    const token = init.body.get("response");
    if (token === "down") throw new Error("network down");
    const match = /^ok:(.+)$/.exec(token);
    return new Response(JSON.stringify(match ? { success: true, action: match[1] } : { success: false }), { status: 200 });
  };
  return env;
}

function captchaEnvironment() {
  return enableCaptcha(throttleEnvironment());
}

function loginWithCaptcha(env, { email = "person@example.com", password = "wrong-password", ip, captchaToken } = {}) {
  return worker.fetch(
    request("/api/auth/local/login", { method: "POST", ip, body: { email, password, randomValue: "l".repeat(40), captchaToken } }),
    env,
    noopCtx
  );
}

test("CAPTCHA login: after 3 failures from one client the next attempt needs a solved CAPTCHA, and isn't counted without one", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  enableCaptcha(env);
  for (let i = 0; i < 3; i++) assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.1" })).status, 401);

  const refused = await loginWithCaptcha(env, { ip: "203.0.113.1", password: "correct-horse-battery" });
  assert.equal(refused.status, 403);
  const body = await refused.json();
  assert.equal(body.code, "captcha_required");
  assert.equal(body.siteKey, "test-site-key");
  assert.ok(!JSON.stringify(body).includes("test-secret"));

  // Repeating it without a token never moves the failure count along...
  for (let i = 0; i < 10; i++) assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.1" })).status, 403);
  // ...so with a solved CAPTCHA the very next try is the 4th, not the 14th.
  assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.1", captchaToken: "ok:login", password: "correct-horse-battery" })).status, 200);
});

test("CAPTCHA login: a wrong, wrong-action or unreachable CAPTCHA is refused and nothing is counted", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  enableCaptcha(env);
  for (let i = 0; i < 3; i++) await loginWithCaptcha(env, { ip: "203.0.113.2" });

  const bad = await loginWithCaptcha(env, { ip: "203.0.113.2", captchaToken: "nope" });
  assert.equal(bad.status, 403);
  assert.equal((await bad.json()).code, "captcha_failed");

  const wrongAction = await loginWithCaptcha(env, { ip: "203.0.113.2", captchaToken: "ok:send-code" });
  assert.equal(wrongAction.status, 403);
  assert.equal((await wrongAction.json()).code, "captcha_failed");

  const originalError = console.error;
  console.error = () => {};
  try {
    const down = await loginWithCaptcha(env, { ip: "203.0.113.2", captchaToken: "down" });
    assert.equal(down.status, 503);
    assert.equal((await down.json()).code, "captcha_unavailable");
  } finally {
    console.error = originalError;
  }
  // Still exactly 3 failures on record: one valid-token attempt is the 4th.
  assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.2", captchaToken: "ok:login" })).status, 401);
});

test("CAPTCHA login: a solved CAPTCHA never shortens a wait", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  enableCaptcha(env);
  // Failures 1-3 pass freely; 4-6 each need (and have) a CAPTCHA; the 6th starts the wait.
  for (let i = 0; i < 3; i++) await loginWithCaptcha(env, { ip: "203.0.113.3" });
  for (let i = 0; i < 3; i++) assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.3", captchaToken: "ok:login" })).status, 401);

  const waiting = await loginWithCaptcha(env, { ip: "203.0.113.3", captchaToken: "ok:login", password: "correct-horse-battery" });
  assert.equal(waiting.status, 429);
  assert.ok(Number(waiting.headers.get("retry-after")) > 0);
});

test("CAPTCHA login: failures spread over many IPs trip the account-level CAPTCHA for everyone else", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  await createLocalAccount(env, "other@example.com", "another-long-password");
  enableCaptcha(env);
  for (let i = 0; i < 5; i++) assert.equal((await loginWithCaptcha(env, { ip: `198.51.100.${i + 1}` })).status, 401);

  // A sixth, brand-new IP has no failures of its own, but the account has 5.
  const fresh = await loginWithCaptcha(env, { ip: "198.51.100.99" });
  assert.equal(fresh.status, 403);
  assert.equal((await fresh.json()).code, "captcha_required");
  // Another account is unaffected.
  assert.equal((await loginWithCaptcha(env, { email: "other@example.com", ip: "198.51.100.99", password: "another-long-password" })).status, 200);
});

test("CAPTCHA login: it asks for a CAPTCHA for an unregistered address exactly as for a real one", async () => {
  const env = captchaEnvironment();
  for (let i = 0; i < 3; i++) assert.equal((await loginWithCaptcha(env, { email: "nobody@example.com", ip: "203.0.113.4" })).status, 401);
  assert.equal((await loginWithCaptcha(env, { email: "nobody@example.com", ip: "203.0.113.4" })).status, 403);
});

test("CAPTCHA login: with Turnstile unconfigured nothing is ever asked for", async () => {
  const env = throttleEnvironment();
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");
  for (let i = 0; i < 5; i++) assert.equal((await loginWithCaptcha(env, { ip: "203.0.113.5" })).status, 401);
});

test("CAPTCHA send-code: required when configured, and a refusal neither sends mail nor uses the address's allowance", async () => {
  const env = captchaEnvironment();
  env.RATE_LIMIT_EMAIL_VERIFY_SEND = fakeCloudflareLimiter(10_000);
  const originalFetch = globalThis.fetch;
  let sent = 0;
  globalThis.fetch = async () => { sent += 1; return new Response("{}", { status: 200 }); };
  const send = (captchaToken, ip = "203.0.113.6") => worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", ip, body: { email: "person@example.com", captchaToken } }),
    env,
    noopCtx
  );
  try {
    for (let i = 0; i < 20; i++) {
      const response = await send(undefined, `198.51.100.${i + 1}`);
      assert.equal(response.status, 403);
      assert.equal((await response.json()).code, "captcha_required");
    }
    assert.equal((await send("ok:login")).status, 403, "a login CAPTCHA can't be spent here");
    assert.equal(sent, 0);

    // 20 refused tries didn't burn the 5/hour per-address allowance.
    for (let i = 0; i < 5; i++) assert.equal((await send("ok:send-code")).status, 200);
    assert.equal((await send("ok:send-code")).status, 429);
    assert.equal(sent, 5);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("CAPTCHA: with only one of the two settings present nothing is asked for", async () => {
  const originalError = console.error;
  console.error = () => {};
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("{}", { status: 200 });
  try {
    for (const partial of [{ TURNSTILE_SECRET: "only-secret" }, { TURNSTILE_SITE_KEY: "only-key" }]) {
      const env = Object.assign(environment(), partial);
      const response = await worker.fetch(
        request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }), env, noopCtx
      );
      assert.equal(response.status, 200);
    }
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalError;
  }
});

test("CAPTCHA send-code: with Turnstile unconfigured it behaves as before", async () => {
  const env = environment();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("{}", { status: 200 });
  try {
    const response = await worker.fetch(
      request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }), env, noopCtx
    );
    assert.equal(response.status, 200);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// MARK: - requireRealSession: a client-fabricated token must not work

test("a client-fabricated token (never minted by this server) is rejected on an ordinary /api/* endpoint", async () => {
  const env = environment({ strictSessions: true });
  const token = freshToken("z");

  const response = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(response.status, 401);
});

test("a client-fabricated token is rejected by /mcp too", async () => {
  const env = environment({ strictSessions: true });
  const token = freshToken("z");

  const response = await worker.fetch(request("/mcp", { method: "POST", token }), env, noopCtx);
  assert.equal(response.status, 401);
});

test("a token that /api/auth/local/login actually minted works even with strictSessions on", async () => {
  const env = environment({ strictSessions: true });
  await createLocalAccount(env, "person@example.com", "correct-horse-battery");

  const login = await worker.fetch(
    request("/api/auth/local/login", {
      method: "POST",
      body: { email: "person@example.com", password: "correct-horse-battery", randomValue: "l".repeat(40) },
    }),
    env,
    noopCtx
  );
  const { token } = await login.json();

  const actions = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(actions.status, 200);
});

function stubFetch(handler) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => handler(url, init);
  return () => { globalThis.fetch = originalFetch; };
}

test("POST /api/issue-reports stores the report and posts it to Slack when a webhook is configured", async () => {
  const env = environment();
  env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.slack.test/services/xyz";
  const token = freshToken("p");

  let slackCall = null;
  const restore = stubFetch(async (url, init) => {
    slackCall = { url, body: JSON.parse(init.body) };
    return new Response("ok", { status: 200 });
  });
  try {
    const response = await worker.fetch(
      request("/api/issue-reports", {
        method: "POST",
        token,
        body: { description: "カレンダーが真っ白になる", appVersion: "1.4.0", osVersion: "18.1", deviceModel: "iPad Pro", language: "ja" },
      }),
      env,
      noopCtx
    );
    assert.equal(response.status, 200);
    const parsed = await response.json();
    assert.equal(parsed.reported, true);
    assert.match(parsed.id, /^[0-9a-f-]{36}$/);

    assert.equal(slackCall.url, "https://hooks.slack.test/services/xyz");
    const text = JSON.stringify(slackCall.body);
    assert.doesNotMatch(text, /カレンダーが真っ白になる/);
    assert.match(text, new RegExp(parsed.id));
    assert.match(text, /1\.4\.0/);
  } finally {
    restore();
  }
});

test("report screenshots require verified Access and are not sent to Slack", async () => {
  const env = environment();
  Object.assign(env, ACCESS_ENV);
  env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.slack.test/services/xyz";
  const token = freshToken("q");
  const pngBytes = Buffer.from("89504e470d0a1a0a", "hex");

  let sentImageURL = null;
  const restore = stubFetch(async (_url, init) => {
    const body = JSON.parse(init.body);
    sentImageURL = body.blocks.find(block => block.type === "image")?.image_url ?? null;
    return new Response("ok", { status: 200 });
  });
  let response;
  try {
    response = await worker.fetch(
      request("/api/issue-reports", {
        method: "POST",
        token,
        body: {
          description: "ノートが保存されない",
          screenshot: { contentType: "image/png", data: pngBytes.toString("base64") },
        },
      }),
      env,
      noopCtx
    );
  } finally {
    restore();
  }
  assert.equal(response.status, 200);
  assert.equal(sentImageURL, null);
  const { id } = await response.json();
  const imageURL = `https://example.test/api/issue-reports/${id}/screenshot`;
  assert.equal((await worker.fetch(new Request(imageURL), env, noopCtx)).status, 401);

  const screenshotResponse = await worker.fetch(new Request(imageURL, { headers: ACCESS_HEADERS }), env, noopCtx);
  assert.equal(screenshotResponse.status, 200);
  assert.equal(screenshotResponse.headers.get("content-type"), "image/png");
  const returnedBytes = Buffer.from(await screenshotResponse.arrayBuffer());
  assert.deepEqual(returnedBytes, pngBytes);
});

test("a report submitted with a screenshot is flagged hasScreenshot:true, with the image stored under its own KV key", async () => {
  const env = environment();
  const token = freshToken("w11");
  const pngBytes = Buffer.from("89504e470d0a1a0a", "hex");

  const response = await worker.fetch(
    request("/api/issue-reports", {
      method: "POST",
      token,
      body: { description: "test", screenshot: { contentType: "image/png", data: pngBytes.toString("base64") } },
    }),
    env,
    noopCtx
  );
  const { id } = await response.json();

  const report = await env.STUDIQUO_DATA.get(`issue-report:${id}`, "json");
  assert.equal(report.hasScreenshot, true);
  assert.ok(!("screenshot" in report), "the report record itself should not carry the image data");

  const screenshot = await env.STUDIQUO_DATA.get(`issue-report-screenshot:${id}`, "json");
  assert.equal(screenshot.contentType, "image/png");
  assert.equal(screenshot.data, pngBytes.toString("base64"));
});

test("a report submitted without a screenshot is flagged hasScreenshot:false, with no screenshot KV entry created", async () => {
  const env = environment();
  const token = freshToken("w12");

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  const { id } = await response.json();

  const report = await env.STUDIQUO_DATA.get(`issue-report:${id}`, "json");
  assert.equal(report.hasScreenshot, false);
  assert.equal(await env.STUDIQUO_DATA.get(`issue-report-screenshot:${id}`), null);
});

test("a downloaded issue-report screenshot is cached only privately and only briefly", async () => {
  const env = environment();
  Object.assign(env, ACCESS_ENV);
  env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.slack.test/services/xyz";
  const token = freshToken("w9");

  let sentImageURL = null;
  const restore = stubFetch(async (_url, init) => {
    const body = JSON.parse(init.body);
    sentImageURL = body.blocks.find(block => block.type === "image")?.image_url ?? null;
    return new Response("ok", { status: 200 });
  });
  try {
    const submitted = await worker.fetch(
      request("/api/issue-reports", {
        method: "POST",
        token,
        body: { description: "test", screenshot: { contentType: "image/png", data: Buffer.from("x").toString("base64") } },
      }),
      env,
      noopCtx
    );
    const { id } = await submitted.json();
    sentImageURL = `https://example.test/api/issue-reports/${id}/screenshot`;
  } finally {
    restore();
  }

  const screenshotResponse = await worker.fetch(new Request(sentImageURL, { headers: ACCESS_HEADERS }), env, noopCtx);
  assert.equal(screenshotResponse.headers.get("cache-control"), "private, max-age=300");
});

test("GET /api/issue-reports/:id/screenshot for an id that was never submitted returns 404", async () => {
  const env = environment();
  Object.assign(env, ACCESS_ENV);

  const response = await worker.fetch(
    new Request("https://example.test/api/issue-reports/00000000-0000-0000-0000-000000000000/screenshot", { headers: ACCESS_HEADERS }),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
});

test("GET /api/issue-reports/:id/screenshot for a report that has no screenshot returns 404", async () => {
  const env = environment();
  Object.assign(env, ACCESS_ENV);
  const token = freshToken("w10");

  const submitted = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  const { id } = await submitted.json();

  const response = await worker.fetch(
    new Request(`https://example.test/api/issue-reports/${id}/screenshot`, { headers: ACCESS_HEADERS }),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
});

test("POST /api/issue-reports rejects an empty description with 400", async () => {
  const env = environment();
  const token = freshToken("r");

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "   " } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports without a bearer token is rejected with 401", async () => {
  const env = environment();

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", body: { description: "test" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 401);
});

test("POST /api/issue-reports allows up to the limit, then 429s", async () => {
  const env = environment();
  const token = freshToken("s");

  let last;
  for (let i = 0; i < 6; i++) {
    last = await worker.fetch(
      request("/api/issue-reports", { method: "POST", token, body: { description: `report ${i}` } }),
      env,
      noopCtx
    );
  }
  assert.equal(last.status, 429);
});

test("POST /api/issue-reports with an expired token is rejected with 401", async () => {
  const env = environment();
  const ninetyOneDaysAgo = Math.floor(Date.now() / 1000) - 91 * 24 * 60 * 60;
  const token = `${ninetyOneDaysAgo}.${"t".repeat(40)}`;

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /expired/i);
});

test("POST /api/issue-reports with a token this server never minted is rejected with 401", async () => {
  const env = environment({ strictSessions: true });
  const token = freshToken("u");

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 401);
});

test("POST /api/issue-reports with a revoked token is rejected with 401", async () => {
  const env = environment();
  const token = freshToken("v");

  await revokeToken(env, token);

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 401);
  assert.match((await response.json()).error, /revoked/i);
});

test("POST /api/issue-reports with no description key at all is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w1");

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { appVersion: "1.0" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports with malformed JSON in the body is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w2");

  const response = await worker.fetch(
    new Request("https://example.test/api/issue-reports", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: "{not valid json",
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports with a request body over the size limit is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w3");

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "x".repeat(4_300_000) } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports truncates an overlong description to 2,000 characters rather than rejecting it", async () => {
  const env = environment();
  const token = freshToken("w4");
  const longDescription = "あ".repeat(2_500);

  const response = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: longDescription } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 200);
  const { id } = await response.json();
  const stored = await env.STUDIQUO_DATA.get(`issue-report:${id}`, "json");
  assert.equal(stored.description.length, 2_000);
  assert.equal(stored.description, longDescription.slice(0, 2_000));
});

test("POST /api/issue-reports truncates overlong device-info fields rather than rejecting them", async () => {
  const env = environment();
  const token = freshToken("w5");

  const response = await worker.fetch(
    request("/api/issue-reports", {
      method: "POST",
      token,
      body: {
        description: "test",
        appVersion: "v".repeat(60),
        osVersion: "o".repeat(60),
        deviceModel: "d".repeat(80),
        language: "l".repeat(40),
      },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 200);
  const { id } = await response.json();
  const stored = await env.STUDIQUO_DATA.get(`issue-report:${id}`, "json");
  assert.equal(stored.appVersion.length, 40);
  assert.equal(stored.osVersion.length, 40);
  assert.equal(stored.deviceModel.length, 60);
  assert.equal(stored.language.length, 20);
});

test("POST /api/issue-reports with a screenshot content type outside image/jpeg and image/png is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w6");

  const response = await worker.fetch(
    request("/api/issue-reports", {
      method: "POST",
      token,
      body: { description: "test", screenshot: { contentType: "image/gif", data: Buffer.from("fake gif").toString("base64") } },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports with an empty screenshot data string is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w7");

  const response = await worker.fetch(
    request("/api/issue-reports", {
      method: "POST",
      token,
      body: { description: "test", screenshot: { contentType: "image/png", data: "" } },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("POST /api/issue-reports with a screenshot decoding to over 3MB is rejected with 400", async () => {
  const env = environment();
  const token = freshToken("w8");

  // 3,000,001 raw bytes — one over MAX_SCREENSHOT_BYTES — base64-encoded,
  // while the whole request body still fits comfortably under the
  // separate, much larger MAX_UPLOAD_BODY cap.
  const oversizedScreenshot = Buffer.alloc(3_000_001, 9).toString("base64");
  const response = await worker.fetch(
    request("/api/issue-reports", {
      method: "POST",
      token,
      body: { description: "test", screenshot: { contentType: "image/png", data: oversizedScreenshot } },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("a token /api/auth/apple actually minted works even with strictSessions on", async () => {
  const env = environment({ strictSessions: true });
  const { privateKey, jwk } = await makeAppleSigningKey();
  await seedAppleJWKS(env, jwk);
  const identityToken = await signAppleIdentityToken(privateKey, jwk.kid, { sub: "apple-sub-strict" });

  const signIn = await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken, randomValue: "a".repeat(40) } }),
    env,
    noopCtx
  );
  const { token } = await signIn.json();

  const actions = await worker.fetch(request("/api/actions", { token }), env, noopCtx);
  assert.equal(actions.status, 200);
});
