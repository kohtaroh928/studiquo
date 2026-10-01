import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import worker from "./app.js";
import { realSession } from "./session.js";

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

function environment({ strictSessions = false } = {}) {
  const values = new Map();
  return {
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
    RESEND_API_KEY: "test-key",
  };
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

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deleted: true });
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
    assert.match(text, /カレンダーが真っ白になる/);
    assert.match(text, /1\.4\.0/);
  } finally {
    restore();
  }
});

test("POST /api/issue-reports with a screenshot serves it back unauthenticated so Slack's preview fetch can reach it", async () => {
  const env = environment();
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
  assert.ok(sentImageURL, "expected the Slack message to include an image block");

  const screenshotResponse = await worker.fetch(new Request(sentImageURL), env, noopCtx);
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
  env.SLACK_ISSUE_REPORT_WEBHOOK_URL = "https://hooks.slack.test/services/xyz";
  const token = freshToken("w9");

  let sentImageURL = null;
  const restore = stubFetch(async (_url, init) => {
    const body = JSON.parse(init.body);
    sentImageURL = body.blocks.find(block => block.type === "image")?.image_url ?? null;
    return new Response("ok", { status: 200 });
  });
  try {
    await worker.fetch(
      request("/api/issue-reports", {
        method: "POST",
        token,
        body: { description: "test", screenshot: { contentType: "image/png", data: Buffer.from("x").toString("base64") } },
      }),
      env,
      noopCtx
    );
  } finally {
    restore();
  }

  const screenshotResponse = await worker.fetch(new Request(sentImageURL), env, noopCtx);
  assert.equal(screenshotResponse.headers.get("cache-control"), "private, max-age=300");
});

test("GET /api/issue-reports/:id/screenshot for an id that was never submitted returns 404", async () => {
  const env = environment();

  const response = await worker.fetch(
    new Request("https://example.test/api/issue-reports/00000000-0000-0000-0000-000000000000/screenshot"),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
});

test("GET /api/issue-reports/:id/screenshot for a report that has no screenshot returns 404", async () => {
  const env = environment();
  const token = freshToken("w10");

  const submitted = await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "test" } }),
    env,
    noopCtx
  );
  const { id } = await submitted.json();

  const response = await worker.fetch(
    new Request(`https://example.test/api/issue-reports/${id}/screenshot`),
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
