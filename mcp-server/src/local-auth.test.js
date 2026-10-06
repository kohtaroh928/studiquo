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

// Counts real PBKDF2 derivations so the tests can assert on work done rather
// than on wall-clock time, which would be flaky.
async function countingDerivations(run) {
  const original = crypto.subtle.deriveBits.bind(crypto.subtle);
  let count = 0;
  crypto.subtle.deriveBits = (...args) => { count += 1; return original(...args); };
  try {
    await run();
  } finally {
    crypto.subtle.deriveBits = original;
  }
  return count;
}

test("an unknown email costs the same PBKDF2 work as a wrong password on a real account", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");

  const wrongPassword = await countingDerivations(() => verifyLocalAccount(env, "person@example.com", "wrong-password"));
  const unknownEmail = await countingDerivations(() => verifyLocalAccount(env, "nobody@example.com", "wrong-password"));
  assert.equal(wrongPassword, 1);
  assert.equal(unknownEmail, wrongPassword);
});

test("a malformed address or a damaged record also does the dummy hash and still returns false", async () => {
  const env = environment();
  assert.equal(await countingDerivations(async () => {
    assert.equal(await verifyLocalAccount(env, "not-an-email", "wrong-password"), false);
  }), 1);

  await env.STUDIQUO_DATA.put("account:local:broken@example.com", JSON.stringify({ email: "broken@example.com", salt: "!!!", passwordHash: "!!!", iterations: 100000 }));
  assert.equal(await countingDerivations(async () => {
    assert.equal(await verifyLocalAccount(env, "broken@example.com", "wrong-password"), false);
  }), 1);
});

test("the dummy path never accepts anything, whatever the password", async () => {
  const env = environment();
  for (const password of ["", "x", "a".repeat(1_024), "\u0000"]) {
    assert.equal(await verifyLocalAccount(env, "nobody@example.com", password), false);
  }
});
