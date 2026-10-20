import assert from "node:assert/strict";
import test from "node:test";
import { revokePasskeysForAccount } from "./passkeys.ts";
import { partialEnv, type LooseEnv } from "./test-env.ts";
import {
  indexAccountPasskey, listAccountPasskeys, passkeyRevokedByReset,
} from "./passkey-policy.ts";

function kv() {
  const values = new Map();
  const lists: any[] = [];
  return {
    values, lists,
    async get(key: string, type?: string | undefined) { const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
    async put(key: string, value: string) { values.set(key, value); },
    async delete(key: string) { values.delete(key); },
    async list({ prefix, cursor }) {
      lists.push(prefix);
      return { keys: [...values.keys()].filter(name => name.startsWith(prefix)).map(name => ({ name })), list_complete: true, cursor };
    },
  };
}

async function register(env, { email, id, userKey, account, createdAt }) {
  const record = { id, publicKey: [1], counter: 0, transports: ["internal"], email, userKey, createdAt };
  await env.STUDIQUO_DATA.put(`passkeys:credential:${id}`, JSON.stringify(record));
  const existing = await env.STUDIQUO_DATA.get(`passkeys:user:${userKey}`, "json") ?? [];
  await env.STUDIQUO_DATA.put(`passkeys:user:${userKey}`, JSON.stringify([...existing, record]));
  await indexAccountPasskey(env, account, email, id);
  return record;
}

test("a reset removes the account's passkeys by its own list, without reading everyone else's", async () => {
  const env = { STUDIQUO_DATA: kv() };
  await register(env, { email: "a@example.com", id: "mine", userKey: "dev-a", account: "email:a@example.com", createdAt: 100 });
  for (let i = 0; i < 30; i++) {
    await register(env, { email: `other${i}@example.com`, id: `other-${i}`, userKey: `dev-${i}`, account: `email:other${i}@example.com`, createdAt: 100 });
  }
  // The first look at the list files passkeys from before it existed (one listing, once).
  await listAccountPasskeys(partialEnv(env), "email:a@example.com", "a@example.com");
  env.STUDIQUO_DATA.lists.length = 0;

  const result = await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });

  assert.equal(result.removed, 1);
  assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:mine"), null);
  assert.notEqual(await env.STUDIQUO_DATA.get("passkeys:credential:other-7"), null, "nobody else's is touched");
  assert.deepEqual(env.STUDIQUO_DATA.lists, [], "no listing of all passkeys");
});

test("a passkey the sweep missed is still cut off, because it was registered before the reset", async () => {
  const env = { STUDIQUO_DATA: kv() };
  const before = Date.now() - 1000;
  // Registered just as the reset ran: the record exists but is not in the list the sweep read.
  const missed = { id: "missed", email: "a@example.com", createdAt: before };
  assert.equal(await passkeyRevokedByReset(partialEnv(env), missed), false, "fine until a reset");
  await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });
  assert.equal(await passkeyRevokedByReset(partialEnv(env), missed), true, "cut off by the time of the reset");
  assert.equal(await passkeyRevokedByReset(partialEnv(env), { ...missed, createdAt: Date.now() + 1000 }), false, "one registered afterwards counts");
  assert.equal(await passkeyRevokedByReset(partialEnv(env), { id: "old", email: "a@example.com" }), true, "a record with no time predates any reset");
  assert.equal(await passkeyRevokedByReset(partialEnv(env), { ...missed, email: "b@example.com" }), false, "another address is not affected");
});

test("a missed passkey does not count as the account's passkey either", async () => {
  const env = { STUDIQUO_DATA: kv() };
  await register(env, { email: "a@example.com", id: "missed", userKey: "dev-a", account: "email:a@example.com", createdAt: Date.now() - 1000 });
  assert.deepEqual(await listAccountPasskeys(partialEnv(env), "email:a@example.com", "a@example.com"), ["missed"]);
  // Simulate the sweep missing it: only the reset time is written.
  const { setPasskeyValidFrom } = await import("./passkey-policy.ts");
  await setPasskeyValidFrom(partialEnv(env), ["email:a@example.com"]);
  assert.deepEqual(await listAccountPasskeys(partialEnv(env), "email:a@example.com", "a@example.com"), []);
});

test("while the list does not yet cover older passkeys, the reset still finds them by the full scan", async () => {
  const env = { STUDIQUO_DATA: kv() };
  // No list entry, and the catch-up has not finished.
  const record = { id: "legacy", publicKey: [1], counter: 0, email: "a@example.com", userKey: "dev-a" };
  await env.STUDIQUO_DATA.put("passkeys:credential:legacy", JSON.stringify(record));
  await env.STUDIQUO_DATA.put("passkeys:user:dev-a", JSON.stringify([record]));
  const realList = env.STUDIQUO_DATA.list;
  let calls = 0;
  env.STUDIQUO_DATA.list = async options => {
    // The catch-up reads one page and stops short of finishing.
    if (options.prefix === "passkeys:credential:" && calls++ === 0) return { keys: [], list_complete: false, cursor: "c" };
    return realList.call(env.STUDIQUO_DATA, options);
  };
  const result = await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });
  assert.equal(result.removed, 1);
  assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:legacy"), null);
  assert.equal(await env.STUDIQUO_DATA.get("passkeys:user:dev-a"), null);
});

test("a passkey of an address the account owns but never linked is cut off too (no canonical mapping needed)", async () => {
  const env = { STUDIQUO_DATA: kv() };
  await env.STUDIQUO_DATA.put("email-account-owner:b@example.com", "email:a@example.com");
  const record = { id: "b-passkey", email: "b@example.com", createdAt: Date.now() - 1000 };
  await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });
  assert.equal(await passkeyRevokedByReset(partialEnv(env), record), true);
  assert.equal(await passkeyRevokedByReset(partialEnv(env), { ...record, email: "c@example.com" }), false, "an address nobody here owns is not");
});

test("when the account's list is full, the reset scans instead of trusting a list that dropped old ids", async () => {
  const env = { STUDIQUO_DATA: kv() };
  // Twelve registered; the list kept the last ten, so the first two are only found by scanning.
  for (let i = 0; i < 12; i++) {
    await register(env, { email: "a@example.com", id: `p${i}`, userKey: `dev-${i}`, account: "email:a@example.com", createdAt: 100 });
  }
  const result = await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });
  assert.equal(result.removed, 12);
  assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:p0"), null, "the oldest is gone too");
});

test("the reset time is written again after the sweep", async () => {
  const env = { STUDIQUO_DATA: kv() };
  const writes = [];
  const put = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value) => { if (key.startsWith("passkey-valid-from:")) writes.push(key); return put.call(env.STUDIQUO_DATA, key, value); };
  await revokePasskeysForAccount(partialEnv(env), { accountKey: "email:a@example.com", emails: ["a@example.com"] });
  assert.ok(writes.length >= 2 && new Set(writes).size < writes.length, "each key written at the start and again at the end");
});
