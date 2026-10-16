import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { associationFile, handlePasskeys, mintPasskeySession } from "./passkeys.js";
import { linkVerifiedEmail } from "./oauth-links.js";
import { realSession } from "./session.js";
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

test("passkey login resolves to the same canonical account as another verified login method", async () => {
  const env = environment();
  await linkVerifiedEmail(env, {
    provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: true,
  });

  const token = await mintPasskeySession(env, "person@example.com", "p".repeat(40));

  assert.equal((await realSession(env, token)).sub, "google:google-sub-1");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:email:person@example.com"), "google:google-sub-1");
});

test("17. 削除済みのパスキーCredentialではログインできない", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("passkeys:challenge:deleted-login", JSON.stringify({
    kind: "authentication", challenge: "challenge-value",
  }));
  const request = new Request("https://example.test/api/passkeys/login/verify", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.77" },
    body: JSON.stringify({
      transaction: "deleted-login",
      randomValue: "p".repeat(40),
      credential: { id: "deleted-credential" },
    }),
  });

  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /expired/i);
});

test("creates bounded, user-verified passkey registration options", async () => {
  const request = new Request("https://example.test/api/passkeys/register/options", {
      method: "POST",
      headers: { authorization: `Bearer ${freshToken("a")}`, "content-type": "application/json" },
      body: JSON.stringify({ email: "student@example.com" }),
    });
  const env = environment();
  await env.STUDIQUO_DATA.put("email-account-owner:student@example.com", "test"); // the default test session's account
  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.options.rp.id, "api.studiquo.app");
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
  await env.STUDIQUO_DATA.put("email-account-owner:student@example.com", "test");
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
  await env.STUDIQUO_DATA.put("email-account-owner:student@example.com", "test");
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

// --- A passkey can only be registered for an e-mail the signed-in account already owns ---

function registerFor(token, email) {
  return new Request("https://example.test/api/passkeys/register/options", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });
}

test("a session for one account cannot register a passkey for another account's e-mail", async () => {
  const env = environment(); // the default test session belongs to the account "test"
  await env.STUDIQUO_DATA.put("email-account-owner:victim@example.com", "google:victim-sub");
  const request = registerFor(freshToken("v"), "victim@example.com");
  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 403);
});

test("an e-mail that no account owns yet cannot be claimed ahead of its owner", async () => {
  const env = environment();
  const request = registerFor(freshToken("u"), "not-signed-up-yet@example.com");
  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 403);
});

test("the owner of an e-mail can register a passkey for it, including through a linked identity", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("email-account-owner:me@example.com", "apple:my-canonical");
  // The session was minted for a linked identity; it resolves to the canonical account.
  const token = freshToken("m");
  await env.STUDIQUO_DATA.put(`session:${sha256Hex(token)}`, JSON.stringify({ sub: "email:me@example.com", issuedAt: Math.floor(Date.now() / 1000) }));
  await env.STUDIQUO_DATA.put("identity-canonical:email:me@example.com", "apple:my-canonical");
  const request = registerFor(token, "ME@Example.com ");
  const response = await handlePasskeys(new URL(request.url), request, env);
  assert.equal(response.status, 200, "case and surrounding spaces do not matter");
});

test("the e-mail check happens before anything is stored for the attempt", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("email-account-owner:victim@example.com", "google:victim-sub");
  const stored = [];
  const realPut = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value, options) => { stored.push(key); return realPut(key, value, options); };
  const request = registerFor(freshToken("w"), "victim@example.com");
  await handlePasskeys(new URL(request.url), request, env);
  assert.deepEqual(stored.filter(key => key.startsWith("passkeys:")), [], "no challenge or credential is left behind");
});

// --- reauthentication with a passkey -------------------------------------
import { generateKeyPairSync, createSign } from "node:crypto";
import { indexAccountPasskey, requireRecentPasskey } from "./passkey-policy.js";

const RP_ID = "api.studiquo.app";
const b64url = buffer => Buffer.from(buffer).toString("base64url");

function newPasskey() {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  const x = Buffer.from(jwk.x, "base64url");
  const y = Buffer.from(jwk.y, "base64url");
  // COSE_Key (EC2, ES256, P-256) as the CBOR bytes the server stores.
  const cose = Buffer.concat([
    Buffer.from([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]), x,
    Buffer.from([0x22, 0x58, 0x20]), y,
  ]);
  return { privateKey, cose };
}

function assertionFor({ privateKey }, challenge, id) {
  const clientDataJSON = Buffer.from(JSON.stringify({
    type: "webauthn.get", challenge, origin: `https://${RP_ID}`, crossOrigin: false,
  }));
  const counter = Buffer.alloc(4); counter.writeUInt32BE(5);
  const authenticatorData = Buffer.concat([createHash("sha256").update(RP_ID).digest(), Buffer.from([0x05]), counter]);
  const signer = createSign("SHA256");
  signer.update(Buffer.concat([authenticatorData, createHash("sha256").update(clientDataJSON).digest()]));
  return {
    id, rawId: id, type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "platform",
    response: {
      clientDataJSON: b64url(clientDataJSON),
      authenticatorData: b64url(authenticatorData),
      signature: b64url(signer.sign(privateKey)),
      userHandle: b64url("user"),
    },
  };
}

async function reauthOptions(env, token) {
  const request = new Request("https://example.test/api/passkeys/reauth/options", {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ action: "delete-account" }),
  });
  return handlePasskeys(new URL(request.url), request, env);
}

async function reauthVerify(env, token, transaction, credential) {
  const request = new Request("https://example.test/api/passkeys/reauth/verify", {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ transaction, credential }),
  });
  return handlePasskeys(new URL(request.url), request, env);
}

async function seedPasskey(env, passkey, id, account = "test") {
  await env.STUDIQUO_DATA.put(`passkeys:credential:${id}`, JSON.stringify({
    id, publicKey: Array.from(passkey.cose), counter: 0, transports: ["internal"], email: "student@example.com",
  }));
  await indexAccountPasskey(env, account, null, id);
}

test("reauth: using the account's own passkey marks this session as freshly verified", async () => {
  const env = environment();
  const token = freshToken("a");
  const passkey = newPasskey();
  await seedPasskey(env, passkey, "cred-own");
  assert.equal((await requireRecentPasskey(env, token, { sub: "test" }, "delete-account")).status, 403);

  const options = await (await reauthOptions(env, token)).json();
  assert.deepEqual(options.options.allowCredentials.map(item => item.id), ["cred-own"]);
  const response = await reauthVerify(env, token, options.transaction, assertionFor(passkey, options.options.challenge, "cred-own"));
  assert.equal(response.status, 200);
  assert.equal(await requireRecentPasskey(env, token, { sub: "test" }, "delete-account"), null);
});

test("reauth: another account's passkey, a wrong signature and another session's challenge do not count", async () => {
  const env = environment();
  const token = freshToken("b");
  const other = freshToken("c");
  const mine = newPasskey();
  const theirs = newPasskey();
  await seedPasskey(env, mine, "cred-mine");
  await seedPasskey(env, theirs, "cred-theirs", "another-account");

  // A valid assertion from a passkey that belongs to someone else.
  let options = await (await reauthOptions(env, token)).json();
  let response = await reauthVerify(env, token, options.transaction, assertionFor(theirs, options.options.challenge, "cred-theirs"));
  assert.equal(response.status, 401);

  // Signed by the wrong key.
  options = await (await reauthOptions(env, token)).json();
  response = await reauthVerify(env, token, options.transaction, assertionFor(theirs, options.options.challenge, "cred-mine"));
  assert.equal(response.status, 401);

  // A challenge issued to one session cannot be answered by another.
  options = await (await reauthOptions(env, token)).json();
  response = await reauthVerify(env, other, options.transaction, assertionFor(mine, options.options.challenge, "cred-mine"));
  assert.equal(response.status, 400);

  assert.equal((await requireRecentPasskey(env, token, { sub: "test" }, "delete-account")).status, 403);
});

test("reauth: an account with no passkey gets 404 for options, and a missing token 401", async () => {
  const env = environment();
  assert.equal((await reauthOptions(env, freshToken("d"))).status, 404);
  const request = new Request("https://example.test/api/passkeys/reauth/options", { method: "POST", body: "{}" });
  assert.equal((await handlePasskeys(new URL(request.url), request, env)).status, 401);
});

test("status: reports whether the signed-in account has a passkey", async () => {
  const env = environment();
  const token = freshToken("e");
  const ask = () => handlePasskeys(new URL("https://example.test/api/passkeys/status"), new Request("https://example.test/api/passkeys/status", { headers: { authorization: `Bearer ${token}` } }), env);
  assert.deepEqual(await (await ask()).json(), { registered: false, count: 0 });
  await seedPasskey(env, newPasskey(), "cred-status");
  assert.deepEqual(await (await ask()).json(), { registered: true, count: 1 });
});

test("adding another passkey needs a recent passkey check once the account has one", async () => {
  const env = environment();
  const token = freshToken("f");
  await env.STUDIQUO_DATA.put("email-account-owner:student@example.com", "test");
  // The first passkey needs nothing.
  assert.equal((await handlePasskeys(new URL(registerOptionsRequest(token).url), registerOptionsRequest(token), env)).status, 200);

  await seedPasskey(env, newPasskey(), "cred-first");
  const refused = await handlePasskeys(new URL(registerOptionsRequest(token).url), registerOptionsRequest(token), env);
  assert.equal(refused.status, 403);
  assert.equal((await refused.json()).code, "reauth_required");

  const { markRecentPasskey } = await import("./passkey-policy.js");
  await markRecentPasskey(env, sha256Hex(token));
  assert.equal((await handlePasskeys(new URL(registerOptionsRequest(token).url), registerOptionsRequest(token), env)).status, 200);
});

test("remove-all: needs the passkey's check when one is established, but not while every passkey is still new", async () => {
  const env = environment();
  const token = freshToken("g");
  const removeAll = () => handlePasskeys(
    new URL("https://example.test/api/passkeys/remove-all"),
    new Request("https://example.test/api/passkeys/remove-all", { method: "POST", headers: { authorization: `Bearer ${token}` } }),
    env
  );
  // Only a passkey added a moment ago (say, by a thief with a stolen session): the owner can undo it.
  await seedPasskey(env, newPasskey(), "cred-new");
  const record = await env.STUDIQUO_DATA.get("passkeys:credential:cred-new", "json");
  await env.STUDIQUO_DATA.put("passkeys:credential:cred-new", JSON.stringify({ ...record, createdAt: Date.now() }));
  assert.equal((await removeAll()).status, 200);
  assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:cred-new"), null);

  // An established one has to be used first.
  await seedPasskey(env, newPasskey(), "cred-old");
  const refused = await removeAll();
  assert.equal(refused.status, 403);
  assert.equal((await refused.json()).action, "remove-passkeys");
  assert.notEqual(await env.STUDIQUO_DATA.get("passkeys:credential:cred-old"), null);
});

test("reauth: a passkey that is still new cannot vouch for the session", async () => {
  const env = environment();
  const token = freshToken("h");
  const passkey = newPasskey();
  await seedPasskey(env, passkey, "cred-fresh");
  const record = await env.STUDIQUO_DATA.get("passkeys:credential:cred-fresh", "json");
  await env.STUDIQUO_DATA.put("passkeys:credential:cred-fresh", JSON.stringify({ ...record, createdAt: Date.now() }));
  assert.equal((await reauthOptions(env, token)).status, 404, "no established passkey to ask for");
});

test("reauth: an unknown action is refused", async () => {
  const env = environment();
  const token = freshToken("i");
  await seedPasskey(env, newPasskey(), "cred-x");
  const request = new Request("https://example.test/api/passkeys/reauth/options", {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ action: "anything" }),
  });
  assert.equal((await handlePasskeys(new URL(request.url), request, env)).status, 400);
});
