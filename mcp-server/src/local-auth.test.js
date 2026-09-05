import assert from "node:assert/strict";
import test from "node:test";
import { upsertLocalAccount, verifyLocalAccount } from "./local-auth.js";

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

test("a freshly created account verifies with its own password", async () => {
  const env = environment();
  await upsertLocalAccount(env, "Person@Example.com", "correct-horse-battery");

  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
});

test("the wrong password is rejected", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");

  assert.equal(await verifyLocalAccount(env, "person@example.com", "wrong-password"), false);
});

test("an unknown email is rejected rather than throwing", async () => {
  const env = environment();

  assert.equal(await verifyLocalAccount(env, "nobody@example.com", "anything"), false);
});

test("the stored record never contains the plaintext password", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");

  const record = await env.STUDIQUO_DATA.get("account:local:person@example.com", "json");
  assert.equal(JSON.stringify(record).includes("correct-horse-battery"), false);
  assert.ok(record.passwordHash);
  assert.ok(record.salt);
});

test("upsertLocalAccount overwrites the previous password (used for both signup and reset)", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "first-password");
  await upsertLocalAccount(env, "person@example.com", "second-password");

  assert.equal(await verifyLocalAccount(env, "person@example.com", "first-password"), false);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "second-password"), true);
});

test("two accounts with the same password get different salts and different stored hashes", async () => {
  const env = environment();
  await upsertLocalAccount(env, "a@example.com", "shared-password-123");
  await upsertLocalAccount(env, "b@example.com", "shared-password-123");

  const a = await env.STUDIQUO_DATA.get("account:local:a@example.com", "json");
  const b = await env.STUDIQUO_DATA.get("account:local:b@example.com", "json");
  assert.notEqual(a.salt, b.salt);
  assert.notEqual(a.passwordHash, b.passwordHash);
});

test("upsertLocalAccount rejects a too-short password", async () => {
  const env = environment();
  await assert.rejects(() => upsertLocalAccount(env, "person@example.com", "short"));
});

test("email matching is case- and whitespace-insensitive", async () => {
  const env = environment();
  await upsertLocalAccount(env, "  Person@Example.com  ", "correct-horse-battery");

  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
});
