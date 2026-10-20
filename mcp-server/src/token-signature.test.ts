// Signed tokens: an invented token is refused WITHOUT a KV read, a real one still
// works, and nothing changes until a signing key is configured.
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import test from "node:test";
import worker from "./app.ts";
import { mintSession } from "./session.ts";
import { sessionTokenAcceptable, accessTokenAcceptable, signSessionToken, signAccessToken } from "./token-signature.ts";
import { partialCtx, partialEnv } from "./test-env.ts";

const hash = value => createHash("sha256").update(value).digest("hex");
const noopCtx = partialCtx({ waitUntil() {} });
const newKey = () => randomBytes(32).toString("base64");
const DAY = 24 * 60 * 60 * 1000;
const nowSeconds = () => Math.floor(Date.now() / 1000);
const SIGNED_SESSION = /^\d{9,12}\.[A-Za-z0-9_-]{16,200}\.[A-Za-z0-9_-]{43}$/;

// A KV double that counts how often it is read.
function environment(extra = {}) {
  const values = new Map();
  const env = partialEnv({
    reads: 0,
    values,
    STUDIQUO_DATA: {
      async get(key, type) { env.reads += 1; const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return { keys: [], list_complete: true }; },
    },
    RATE_COUNTER: { getByName() { return { async bump() { return true; } }; } },
    ...extra,
  });
  return env;
}

const call = (env, path, { method = "GET", token, body, headers = {} }: { method?: string; token?: string; body?: BodyInit; headers?: Record<string, string> } = {}) => worker.fetch(new Request(`https://example.test${path}`, {
  method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body,
}), env, noopCtx);

// ---- The check itself ---------------------------------------------------------

test("with no key configured every token passes the check and nothing is signed", async () => {
  const env = partialEnv({});
  assert.equal(await sessionTokenAcceptable(env, `${nowSeconds()}.${"r".repeat(40)}`), true);
  assert.equal(await sessionTokenAcceptable(env, `${nowSeconds()}.${"r".repeat(40)}.${"A".repeat(43)}`), true);
  assert.equal(await signSessionToken(env, "123456789.abc"), "123456789.abc");
  assert.equal(await accessTokenAcceptable(env, "mcp_anything"), true);
  assert.equal(await signAccessToken(env, `mcp_${"a".repeat(64)}`), `mcp_${"a".repeat(64)}`);
});

test("a token signed with the key passes; a changed part, a wrong key or a forged signature does not", async () => {
  const env = partialEnv({ TOKEN_SIGNING_KEY: newKey() });
  const payload = `${nowSeconds()}.${"r".repeat(40)}`;
  const token = await signSessionToken(env, payload);
  assert.match(token, SIGNED_SESSION);
  assert.equal(await sessionTokenAcceptable(env, token), true);

  const [epoch, random, mac] = token.split(".");
  assert.equal(await sessionTokenAcceptable(env, `${Number(epoch) + 1}.${random}.${mac}`), false, "issue time changed");
  assert.equal(await sessionTokenAcceptable(env, `${epoch}.${"s".repeat(40)}.${mac}`), false, "random part changed");
  const flipped = mac.slice(0, 20) + (mac[20] === "A" ? "B" : "A") + mac.slice(21);
  assert.equal(await sessionTokenAcceptable(env, `${epoch}.${random}.${flipped}`), false, "signature changed");
  assert.equal(await sessionTokenAcceptable(env, `${epoch}.${random}.${"A".repeat(43)}`), false, "invented signature");
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey() }), token), false, "another key");
});

test("a legacy token (no signature) is accepted until REQUIRE_SIGNED_TOKENS is on", async () => {
  const legacy = `${nowSeconds()}.${"r".repeat(40)}`;
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey() }), legacy), true);
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey(), REQUIRE_SIGNED_TOKENS: "true" }), legacy), false);
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey(), REQUIRE_SIGNED_TOKENS: "false" }), legacy), true);
});

test("without a key, REQUIRE_SIGNED_TOKENS cannot lock anyone out", async () => {
  assert.equal(await sessionTokenAcceptable(partialEnv({ REQUIRE_SIGNED_TOKENS: "true" }), `${nowSeconds()}.${"r".repeat(40)}`), true);
});

test("during a key rotation a token signed with the old key still passes, and one from a stranger key does not", async () => {
  const oldKey = newKey();
  const token = await signSessionToken(partialEnv({ TOKEN_SIGNING_KEY: oldKey }), `${nowSeconds()}.${"r".repeat(40)}`);
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey(), TOKEN_SIGNING_KEY_OLD: oldKey }), token), true);
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: newKey(), TOKEN_SIGNING_KEY_OLD: newKey() }), token), false);
  // New tokens are signed with the new key only.
  const fresh = await signSessionToken(partialEnv({ TOKEN_SIGNING_KEY: newKey(), TOKEN_SIGNING_KEY_OLD: oldKey }), `${nowSeconds()}.${"r".repeat(40)}`);
  assert.equal(await sessionTokenAcceptable(partialEnv({ TOKEN_SIGNING_KEY: oldKey }), fresh), false);
});

test("a session signature is not valid as an MCP access signature, or the other way round", async () => {
  const env = partialEnv({ TOKEN_SIGNING_KEY: newKey() });
  const access = await signAccessToken(env, `mcp_${"a".repeat(64)}`);
  assert.match(access, /^mcp_[0-9a-f]{64}\.[A-Za-z0-9_-]{43}$/);
  assert.equal(await accessTokenAcceptable(env, access), true);
  const session = await signSessionToken(env, `${nowSeconds()}.${"a".repeat(64)}`);
  const sessionMac = session.slice(session.lastIndexOf(".") + 1);
  assert.equal(await accessTokenAcceptable(env, `mcp_${"a".repeat(64)}.${sessionMac}`), false);
});

test("a key that is too short is refused instead of used", async () => {
  await assert.rejects(signSessionToken(partialEnv({ TOKEN_SIGNING_KEY: Buffer.from("short").toString("base64") }), "123456789.abc"));
});

// ---- Through the Worker: no KV read for an invented token ---------------------

const forged = () => `${nowSeconds()}.${"r".repeat(40)}.${"A".repeat(43)}`;

test("an invented signed-looking token is refused with no KV read at all", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  for (const path of ["/api/actions", "/api/plan", "/api/chat/inbox", "/api/document/rooms/" + "a".repeat(64) + "/state"]) {
    const response = await call(env, path, { token: forged() });
    assert.equal(response.status, 401, path);
  }
  assert.equal(env.reads, 0, "the flood never reached KV");
});

test("a flood of invented tokens, each different, still costs no KV read", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  for (let i = 0; i < 300; i += 1) {
    const token = `${nowSeconds()}.${randomBytes(20).toString("hex")}.${randomBytes(32).toString("base64url")}`;
    assert.equal((await call(env, "/api/actions", { token })).status, 401);
  }
  assert.equal(env.reads, 0);
});

test("without a key an invented token still reads KV, exactly as before (the check is off)", async () => {
  const env = environment();
  const response = await call(env, "/api/actions", { token: `${nowSeconds()}.${"r".repeat(40)}` });
  assert.equal(response.status, 401);
  assert.ok(env.reads > 0);
});

test("a real signed login works end to end", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  const token = await mintSession(env, "person", "r".repeat(40));
  assert.match(token, SIGNED_SESSION);
  assert.ok(token.length <= 256);
  const stored = JSON.parse(env.values.get(`session:${hash(token)}`));
  assert.equal(stored.sub, "person");
  const response = await call(env, "/api/actions", { token });
  assert.equal(response.status, 200);
});

test("a signed token with one character changed is refused with no KV read", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  const token = await mintSession(env, "person", "r".repeat(40));
  env.reads = 0;
  const mac = token.slice(token.lastIndexOf(".") + 1);
  const tampered = token.slice(0, -1) + (mac.endsWith("A") ? "B" : "A");
  assert.equal((await call(env, "/api/actions", { token: tampered })).status, 401);
  assert.equal(env.reads, 0);
});

test("a login made before signing keeps working, until signatures are required", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  const legacy = `${nowSeconds()}.${"l".repeat(40)}`;
  env.values.set(`session:${hash(legacy)}`, JSON.stringify({ sub: "old", issuedAt: nowSeconds(), issuedAtMs: Date.now() }));
  assert.equal((await call(env, "/api/actions", { token: legacy })).status, 200);

  const strict = environment({ TOKEN_SIGNING_KEY: newKey(), REQUIRE_SIGNED_TOKENS: "true" });
  strict.values.set(`session:${hash(legacy)}`, JSON.stringify({ sub: "old", issuedAt: nowSeconds(), issuedAtMs: Date.now() }));
  assert.equal((await call(strict, "/api/actions", { token: legacy })).status, 401);
  assert.equal(strict.reads, 0, "refused before KV");
});

test("renewing a login hands back a signed token", async () => {
  const env = environment({ TOKEN_SIGNING_KEY: newKey() });
  const issuedAtMs = Date.now() - 10 * DAY;
  const legacy = `${Math.floor(issuedAtMs / 1000)}.${"t".repeat(40)}`;
  env.values.set(`session:${hash(legacy)}`, JSON.stringify({ sub: "person", issuedAt: Math.floor(issuedAtMs / 1000), issuedAtMs, originIssuedAtMs: issuedAtMs }));
  const response = await call(env, "/api/session/refresh", {
    method: "POST", token: legacy, headers: { "content-type": "application/json" }, body: JSON.stringify({ randomValue: "n".repeat(40) }),
  });
  const result = await response.json();
  assert.equal(result.refreshed, true);
  assert.match(result.token, SIGNED_SESSION);
  assert.equal((await call(env, "/api/actions", { token: result.token })).status, 200);
});

// ---- MCP access tokens ------------------------------------------------------------

function oauthEnvironment(extra = {}) {
  const env = environment({
    RATE_LIMIT_MCP_TOKEN: { async limit() { return { success: true }; } },
    MCP_INBOX: { getByName() { const used = new Set(); return { async consumeOnce(id) { if (used.has(id)) return false; used.add(id); return true; } }; } },
    ...extra,
  });
  return env;
}

test("an MCP access token is signed when a key is set, works, and a made-up one is refused with no KV read", async () => {
  const env = oauthEnvironment({ TOKEN_SIGNING_KEY: newKey() });
  const sub = "apple:owner";
  const clientId = "studiquo_" + "d".repeat(32);
  env.values.set(`mcp:client:${clientId}`, JSON.stringify({ clientName: "App", redirectUris: ["https://client.example/callback"] }));
  env.values.set(`mcp:grant:${hash(sub)}:${hash(clientId)}`, JSON.stringify({ clientName: "App", createdAt: 1, nonce: "n" }));
  const refreshToken = "mcp_refresh_" + "2".repeat(64);
  env.values.set(`mcp:refresh:${hash(refreshToken)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read", grantId: "n" }));
  const exchanged = await call(env, "/oauth/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: refreshToken }).toString(),
  });
  assert.equal(exchanged.status, 200);
  const { access_token: access } = await exchanged.json();
  assert.match(access, /^mcp_[0-9a-f]{64}\.[A-Za-z0-9_-]{43}$/);
  const mcp = token => call(env, "/mcp", { method: "POST", token, headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) });
  assert.notEqual((await mcp(access)).status, 401, "the real token works");

  env.reads = 0;
  const madeUp = `mcp_${"c".repeat(64)}.${"B".repeat(43)}`;
  assert.equal((await mcp(madeUp)).status, 401);
  assert.equal(env.reads, 0, "an invented signed-looking access token never reached KV");

  // An unsigned (legacy) access token is still looked up until signatures are required.
  const unsigned = `mcp_${"c".repeat(64)}`;
  assert.equal((await mcp(unsigned)).status, 401);
  assert.ok(env.reads > 0);

  const strict = oauthEnvironment({ TOKEN_SIGNING_KEY: newKey(), REQUIRE_SIGNED_TOKENS: "true" });
  const strictCall = token => call(strict, "/mcp", { method: "POST", token, headers: { "content-type": "application/json" }, body: "{}" });
  assert.equal((await strictCall(unsigned)).status, 401);
  assert.equal(strict.reads, 0, "with signatures required, an unsigned access token is refused before KV");
});
