import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import worker from "./app.js";

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
    },
    CHAT_ROOM: { getByName() { throw new Error("not used in these tests"); } },
    RATE_LIMIT_APPLE_AUTH: fakeCloudflareLimiter(),
    RATE_LIMIT_GOOGLE_AUTH: fakeCloudflareLimiter(),
    RATE_LIMIT_EMAIL_VERIFY_SEND: fakeCloudflareLimiter(),
    RATE_LIMIT_EMAIL_VERIFY_CONFIRM: fakeCloudflareLimiter(),
    RATE_LIMIT_LOCAL_LOGIN: fakeCloudflareLimiter(),
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

test("signing in with Google using the same verified email as an existing Apple account links the two", async () => {
  const env = environment();
  const { privateKey: applePrivateKey, jwk: appleJWK } = await makeAppleSigningKey();
  await seedAppleJWKS(env, appleJWK);
  const appleToken = await signAppleIdentityToken(applePrivateKey, appleJWK.kid, {
    sub: "000123.apple-sub.4567",
    email: "person@example.com",
    isPrivateEmail: false,
    emailVerified: true,
  });
  await worker.fetch(
    request("/api/auth/apple", { method: "POST", body: { identityToken: appleToken, randomValue: "a".repeat(40) } }),
    env,
    noopCtx
  );

  const { privateKey: googlePrivateKey, jwk: googleJWK } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, googleJWK);
  const googleToken = await signGoogleIdentityToken(googlePrivateKey, googleJWK.kid, {
    sub: "108234567890123456789",
    email: "person@example.com",
    emailVerified: true,
  });
  await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken: googleToken, randomValue: "b".repeat(40) } }),
    env,
    noopCtx
  );

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.deepEqual(linked, [
    { provider: "apple", sub: "000123.apple-sub.4567" },
    { provider: "google", sub: "108234567890123456789" },
  ]);
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

test("email verification, then a Google sign-in with the same address, links both under one email", async () => {
  const env = environment();
  const stub = stubResendCapturingCode();
  await worker.fetch(
    request("/api/auth/email/send-code", { method: "POST", body: { email: "person@example.com" } }),
    env,
    noopCtx
  );
  stub.restore();
  await worker.fetch(
    request("/api/auth/email/confirm-code", {
      method: "POST",
      body: { email: "person@example.com", code: stub.code(), password: "correct-horse-battery", randomValue: "r".repeat(40) },
    }),
    env,
    noopCtx
  );

  const { privateKey, jwk } = await makeGoogleSigningKey();
  await seedGoogleJWKS(env, jwk);
  const idToken = await signGoogleIdentityToken(privateKey, jwk.kid, {
    sub: "108234567890123456789",
    email: "person@example.com",
    emailVerified: true,
  });
  await worker.fetch(
    request("/api/auth/google", { method: "POST", body: { idToken, randomValue: "g".repeat(40) } }),
    env,
    noopCtx
  );

  const linked = await env.STUDIQUO_DATA.get("email-accounts:person@example.com", "json");
  assert.deepEqual(linked, [
    { provider: "email", sub: "person@example.com" },
    { provider: "google", sub: "108234567890123456789" },
  ]);
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
  // rate-limit test in this file — checkRateLimit() only allows a request
  // both layers agree on, so that default caps the effective limit here
  // even though RATE_LIMIT_LOCAL_LOGIN's own KV-counter limit is 10.
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
