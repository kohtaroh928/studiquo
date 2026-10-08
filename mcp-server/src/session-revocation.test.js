import assert from "node:assert/strict";
import test, { mock } from "node:test";
import { sha256Hex } from "./auth.js";
import { externalSession, revokeAllConnections } from "./mcp-oauth.js";
import { mintSession, realSession, revokeSessionsIssuedBefore } from "./session.js";

function environment() {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key, type) { const value = values.get(key) ?? null; return value && type === "json" ? JSON.parse(value) : value; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) { return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true }; },
    },
    _values: values,
  };
}

const RANDOM = "r".repeat(40);
const stateKey = async identity => `account-deletion:${await sha256Hex(identity)}`;
const cutoffKey = async identity => `session-valid-from:${await sha256Hex(identity)}`;
const T0 = Date.UTC(2026, 9, 8, 12, 0, 0);

test("sessions issued before a password was set are signed out; the new one is not", async t => {
  t.after(() => mock.timers.reset());
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const env = environment();
  const identity = "email:person@example.com";
  const oldSession = await mintSession(env, identity, RANDOM + "old");
  assert.ok(await realSession(env, oldSession));

  mock.timers.tick(10_000);
  await revokeSessionsIssuedBefore(env, identity);
  const newSession = await mintSession(env, identity, RANDOM + "new");

  assert.equal(await realSession(env, oldSession), null, "whoever held the old password is signed out");
  assert.ok(await realSession(env, newSession), "the person who set the new password stays signed in");
});

test("the same second: a session minted before the change is cut off, one minted after it is kept", async t => {
  t.after(() => mock.timers.reset());
  mock.timers.enable({ apis: ["Date"], now: T0 + 100 });
  const env = environment();
  const identity = "email:same-second@example.com";
  const before = await mintSession(env, identity, RANDOM + "before");
  mock.timers.tick(400); // still inside the same wall-clock second
  await revokeSessionsIssuedBefore(env, identity);
  const after = await mintSession(env, identity, RANDOM + "after");
  assert.equal(await realSession(env, before), null, "even within the same second");
  assert.ok(await realSession(env, after));
});

test("another account's sessions are not affected", async t => {
  t.after(() => mock.timers.reset());
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const env = environment();
  const other = await mintSession(env, "email:someone-else@example.com", RANDOM + "other");
  mock.timers.tick(10_000);
  await revokeSessionsIssuedBefore(env, "email:person@example.com");
  assert.ok(await realSession(env, other));
});

test("sessions follow the canonical account, whichever identity they were minted for", async t => {
  t.after(() => mock.timers.reset());
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const env = environment();
  const canonical = "apple:owner", alias = "email:owner@example.com";
  env._values.set(`identity-canonical:${alias}`, canonical);
  const viaAlias = await mintSession(env, alias, RANDOM + "alias");
  const viaCanonical = await mintSession(env, canonical, RANDOM + "canonical");
  mock.timers.tick(10_000);
  await revokeSessionsIssuedBefore(env, canonical);
  assert.equal(await realSession(env, viaAlias), null);
  assert.equal(await realSession(env, viaCanonical), null);
});

test("an account that is being deleted, or is deleted, gets no cut-off recorded", async () => {
  const env = environment();
  for (const status of ["deleting", "deleted"]) {
    const identity = `apple:${status}`;
    env._values.set(await stateKey(identity), JSON.stringify({ status, deletionKeys: [] }));
    await revokeSessionsIssuedBefore(env, identity);
    assert.equal(env._values.has(await cutoffKey(identity)), false, status);
  }
});

test("M-1/M-2: the cut-off lives apart from the account's state, which it never touches", async () => {
  const env = environment();
  const identity = "apple:returned";
  const state = JSON.stringify({ status: "active", reregisteredAt: 1234, pendingCustomerClear: ["h"] });
  env._values.set(await stateKey(identity), state);
  await revokeSessionsIssuedBefore(env, identity, 99_000);
  assert.equal(env._values.get(await stateKey(identity)), state, "state is byte-for-byte unchanged");
  assert.equal(env._values.get(await cutoffKey(identity)), "99000");
});

test("M-1: signing in again with a clean-up still pending keeps the cut-off in force", async t => {
  t.after(() => mock.timers.reset());
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const env = environment();
  const identity = "apple:pending-and-reset";
  const old = await mintSession(env, identity, RANDOM + "old");
  env._values.set(await stateKey(identity), JSON.stringify({ status: "active", reregisteredAt: T0 - 1000, pendingCustomerClear: [] }));
  mock.timers.tick(10_000);
  await revokeSessionsIssuedBefore(env, identity);
  const fresh = await mintSession(env, identity, RANDOM + "fresh"); // rewrites the state record
  assert.equal(await realSession(env, old), null, "the old session does not come back");
  assert.ok(await realSession(env, fresh));
});

test("sessions that cannot show when they were issued are cut off", async () => {
  const env = environment();
  const identity = "email:legacy@example.com";
  await revokeSessionsIssuedBefore(env, identity, T0);
  env._values.set(`session:${await sha256Hex("legacy-token")}`, JSON.stringify({ sub: identity }));
  assert.equal(await realSession(env, "legacy-token"), null);
});

test("a record with whole seconds only is judged by the whole second", async () => {
  const env = environment();
  const identity = "email:seconds@example.com";
  const second = Math.floor(T0 / 1000);
  env._values.set(`session:${await sha256Hex("older")}`, JSON.stringify({ sub: identity, issuedAt: second - 5 }));
  env._values.set(`session:${await sha256Hex("same")}`, JSON.stringify({ sub: identity, issuedAt: second }));
  await revokeSessionsIssuedBefore(env, identity, T0 + 500);
  assert.equal(await realSession(env, "older"), null);
  assert.ok(await realSession(env, "same"), "a whole-second record from the same second is kept");
});

test("the cut-off expires once no session old enough to be affected can exist", async () => {
  const env = environment();
  let ttl;
  const realPut = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value, options) => { if (key === await cutoffKey("email:ttl@example.com")) ttl = options?.expirationTtl; return realPut(key, value, options); };
  await revokeSessionsIssuedBefore(env, "email:ttl@example.com");
  assert.ok(ttl >= 90 * 86_400, `ttl ${ttl}`);
});

// --- H-1: connected apps (MCP) ---

const sha = value => sha256Hex(value);
async function connectApp(env, sub, clientId, accessToken) {
  await env._values.set(`mcp:grant:${await sha(sub)}:${await sha(clientId)}`, JSON.stringify({ clientName: "Test app", createdAt: Date.now() }));
  await env._values.set(`mcp:access:${await sha(accessToken)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read" }));
  await env._values.set(`mcp:refresh:${await sha("refresh-" + accessToken)}`, JSON.stringify({ sub, clientId, scope: "studiquo.read" }));
}
const mcpRequest = token => new Request("https://example.test/mcp", { headers: { authorization: `Bearer ${token}` } });

test("H-1: disconnecting all of an account's apps stops their access tokens, and only that account's", async () => {
  const env = environment();
  await connectApp(env, "email:victim@example.com", "client-a", "mcp_attacker_token_" + "x".repeat(40));
  await connectApp(env, "email:victim@example.com", "client-b", "mcp_other_token_" + "x".repeat(40));
  await connectApp(env, "email:bystander@example.com", "client-a", "mcp_bystander_token_" + "x".repeat(40));
  assert.ok(await externalSession(env, mcpRequest("mcp_attacker_token_" + "x".repeat(40))));

  await revokeAllConnections(env, "email:victim@example.com");

  assert.equal(await externalSession(env, mcpRequest("mcp_attacker_token_" + "x".repeat(40))), null);
  assert.equal(await externalSession(env, mcpRequest("mcp_other_token_" + "x".repeat(40))), null);
  assert.ok(await externalSession(env, mcpRequest("mcp_bystander_token_" + "x".repeat(40))), "another account's app stays connected");
  const victimPrefix = `mcp:grant:${await sha("email:victim@example.com")}:`;
  const grants = [...env._values.keys()].filter(key => key.startsWith(victimPrefix));
  assert.equal(grants.length, 0, "with no grant, a refresh token has nothing to exchange against either");
});

test("H-1: an app approved under a linked identity is disconnected too when every identity is passed", async () => {
  const env = environment();
  await connectApp(env, "google:alias-owner", "client-a", "mcp_alias_token_" + "x".repeat(40));
  await connectApp(env, "email:alias-owner@example.com", "client-b", "mcp_canonical_token_" + "x".repeat(40));
  await connectApp(env, "email:bystander2@example.com", "client-a", "mcp_bystander2_token_" + "x".repeat(40));

  await revokeAllConnections(env, ["email:alias-owner@example.com", "google:alias-owner"]);

  assert.equal(await externalSession(env, mcpRequest("mcp_alias_token_" + "x".repeat(40))), null, "an app approved before linking must not survive a reset");
  assert.equal(await externalSession(env, mcpRequest("mcp_canonical_token_" + "x".repeat(40))), null);
  assert.ok(await externalSession(env, mcpRequest("mcp_bystander2_token_" + "x".repeat(40))));
});

test("H-1: disconnecting reads every page of grants, not just the first", async () => {
  const env = environment();
  const sub = "email:many-apps@example.com";
  for (let index = 0; index < 5; index += 1) await connectApp(env, sub, `client-${index}`, `mcp_many_${index}_` + "x".repeat(40));
  const realList = env.STUDIQUO_DATA.list;
  env.STUDIQUO_DATA.list = async ({ prefix, cursor }) => {
    const all = (await realList({ prefix })).keys;
    const start = cursor ? Number(cursor) : 0;
    const keys = all.slice(start, start + 2);
    const next = start + 2;
    return next < all.length ? { keys, list_complete: false, cursor: String(next) } : { keys, list_complete: true };
  };

  await revokeAllConnections(env, sub);

  for (let index = 0; index < 5; index += 1) {
    assert.equal(await externalSession(env, mcpRequest(`mcp_many_${index}_` + "x".repeat(40))), null, `app ${index} stays connected`);
  }
});
