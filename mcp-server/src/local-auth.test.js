import assert from "node:assert/strict";
import test from "node:test";
import { sha256Hex } from "./auth.js";
import { accountGenerationMethods } from "./test-account-generations.js";
import { Argon2BusyError, argon2QueueState, engine, hashers, upsertLocalAccount, verifyLocalAccount } from "./local-auth.js";

function environment({ argon2Write = true } = {}) {
  const values = new Map();
  const generations = new Map();
  const env = {
    ...(argon2Write ? { ARGON2_WRITE: "true" } : {}),
    RATE_COUNTER: {
      getByName: name => accountGenerationMethods(name, generations, () => env.STUDIQUO_DATA),
    },
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
  };
  return env;
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

// MARK: - Argon2id and the PBKDF2 migration

function storedRecord(env, email) {
  return env.STUDIQUO_DATA.get(`account:local:${email}`, "json");
}

// A pre-migration account, written exactly as the old code did.
async function seedLegacyAccount(env, email, password, { iterations = 100_000 } = {}) {
  const salt = crypto.getRandomValues(new Uint8Array(24));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, key, 256);
  await env.STUDIQUO_DATA.put(`account:local:${email}`, JSON.stringify({
    email,
    salt: btoa(String.fromCharCode(...salt)),
    passwordHash: btoa(String.fromCharCode(...new Uint8Array(bits))),
    iterations,
    updatedAt: "2026-01-01T00:00:00.000Z",
  }));
}

// Runs `run` while counting every call into each primitive.
async function countingWork(run) {
  const original = { ...hashers };
  const calls = { pbkdf2: 0, argon2id: 0 };
  hashers.pbkdf2 = (...args) => { calls.pbkdf2 += 1; return original.pbkdf2(...args); };
  hashers.argon2id = (...args) => { calls.argon2id += 1; return original.argon2id(...args); };
  try {
    await run();
  } finally {
    Object.assign(hashers, original);
  }
  return calls;
}

test("new accounts are stored as Argon2id at OWASP's minimum cost", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");
  const record = await storedRecord(env, "person@example.com");
  assert.equal(record.algo, "argon2id");
  assert.deepEqual([record.m, record.t, record.p], [19_456, 2, 1]);
  assert.equal(record.iterations, undefined);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "wrong-password"), false);
});

test("a legacy PBKDF2 account still signs in, and is upgraded to Argon2id on that sign-in", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "correct-horse-battery");
  assert.equal((await storedRecord(env, "person@example.com")).algo, undefined);

  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  const upgraded = await storedRecord(env, "person@example.com");
  assert.equal(upgraded.algo, "argon2id");
  assert.equal(upgraded.iterations, undefined);

  // The upgraded record verifies with the same password, and only that one.
  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "wrong-password"), false);
});

test("a wrong password never upgrades or alters a legacy record", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "correct-horse-battery");
  const before = JSON.stringify(await storedRecord(env, "person@example.com"));
  assert.equal(await verifyLocalAccount(env, "person@example.com", "wrong-password"), false);
  assert.equal(JSON.stringify(await storedRecord(env, "person@example.com")), before);
});

test("an upgrade doesn't overwrite a password reset that landed during the sign-in", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "old-password-1");

  const original = hashers.pbkdf2;
  // While the old password is being verified, the owner resets it.
  hashers.pbkdf2 = async (...args) => {
    const result = await original(...args);
    await upsertLocalAccount(env, "person@example.com", "brand-new-password");
    return result;
  };
  try {
    assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), true);
  } finally {
    hashers.pbkdf2 = original;
  }
  assert.equal(await verifyLocalAccount(env, "person@example.com", "brand-new-password"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), false);
});

test("resetting the password replaces a legacy record with Argon2id", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "old-password-1");
  await upsertLocalAccount(env, "person@example.com", "brand-new-password");
  assert.equal((await storedRecord(env, "person@example.com")).algo, "argon2id");
  assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), false);
});

test("every rejecting path does exactly one PBKDF2 run and one Argon2id run, whatever the account", async () => {
  const env = environment();
  await upsertLocalAccount(env, "modern@example.com", "correct-horse-battery");
  await seedLegacyAccount(env, "legacy@example.com", "correct-horse-battery");
  await env.STUDIQUO_DATA.put("account:local:broken@example.com", JSON.stringify({ email: "broken@example.com", salt: "!!!", passwordHash: "!!!", iterations: 100000 }));
  await env.STUDIQUO_DATA.put("account:local:wild@example.com", JSON.stringify({ email: "wild@example.com", algo: "argon2id", m: 4_000_000, t: 2, p: 1, salt: "AAAA", passwordHash: "AAAA" }));

  for (const email of ["modern@example.com", "legacy@example.com", "nobody@example.com", "broken@example.com", "wild@example.com", "not-an-email"]) {
    const calls = await countingWork(async () => {
      assert.equal(await verifyLocalAccount(env, email, "wrong-password"), false);
    });
    assert.deepEqual(calls, { pbkdf2: 1, argon2id: 1 }, email);
  }
});

test("a correct sign-in does the same work as a wrong one, plus one Argon2id run only for the legacy upgrade", async () => {
  const env = environment();
  await upsertLocalAccount(env, "modern@example.com", "correct-horse-battery");
  await seedLegacyAccount(env, "legacy@example.com", "correct-horse-battery");

  assert.deepEqual(await countingWork(() => verifyLocalAccount(env, "modern@example.com", "correct-horse-battery")), { pbkdf2: 1, argon2id: 1 });
  assert.deepEqual(await countingWork(() => verifyLocalAccount(env, "legacy@example.com", "correct-horse-battery")), { pbkdf2: 1, argon2id: 2 });
  // Next time it's an ordinary Argon2id account.
  assert.deepEqual(await countingWork(() => verifyLocalAccount(env, "legacy@example.com", "correct-horse-battery")), { pbkdf2: 1, argon2id: 1 });
});

test("a burst of sign-ins never runs more than two Argon2id hashes at once", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");

  const original = engine.argon2idAsync;
  let running = 0;
  let peak = 0;
  engine.argon2idAsync = async (...args) => {
    running += 1;
    peak = Math.max(peak, running);
    try { return await original(...args); } finally { running -= 1; }
  };
  try {
    const results = await Promise.all(Array.from({ length: 8 }, () => verifyLocalAccount(env, "person@example.com", "wrong-password")));
    assert.ok(results.every(result => result === false));
  } finally {
    engine.argon2idAsync = original;
  }
  assert.ok(peak >= 1 && peak <= 2, `peak concurrency was ${peak}`);
});

test("a damaged record or absurd parameters still just return false", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("account:local:null@example.com", "null");
  await env.STUDIQUO_DATA.put("account:local:str@example.com", JSON.stringify("oops"));
  for (const email of ["null@example.com", "str@example.com"]) {
    assert.equal(await verifyLocalAccount(env, email, "wrong-password"), false);
  }
  for (const password of ["", "x", "a".repeat(1_024), "\u0000"]) {
    assert.equal(await verifyLocalAccount(env, "nobody@example.com", password), false);
  }
});

test("with ARGON2_WRITE off, new and reset passwords are still written as PBKDF2 and legacy accounts are not upgraded", async () => {
  const env = environment({ argon2Write: false });
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");
  const written = await storedRecord(env, "person@example.com");
  assert.equal(written.algo, undefined);
  assert.equal(written.iterations, 100_000);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal(JSON.stringify(await storedRecord(env, "person@example.com")), JSON.stringify(written), "no upgrade while the flag is off");
});

test("with the flag off the code still reads Argon2id records (so it is the safe version to roll back to)", async () => {
  const on = environment({ argon2Write: true });
  await upsertLocalAccount(on, "person@example.com", "correct-horse-battery");
  const off = environment({ argon2Write: false });
  await off.STUDIQUO_DATA.put("account:local:person@example.com", JSON.stringify(await storedRecord(on, "person@example.com")));
  assert.equal(await verifyLocalAccount(off, "person@example.com", "correct-horse-battery"), true);
  assert.equal(await verifyLocalAccount(off, "person@example.com", "wrong-password"), false);
});

test("a stale read of the pre-reset record cannot bring the old password back", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "old-password-1");
  const staleRecord = await env.STUDIQUO_DATA.get("account:local:person@example.com");

  // The owner resets; the new record is in KV...
  await upsertLocalAccount(env, "person@example.com", "brand-new-password");
  // ...but a lagging replica still serves the old one to the login that follows.
  const realGet = env.STUDIQUO_DATA.get;
  env.STUDIQUO_DATA.get = async (key, type) => (
    key === "account:local:person@example.com" ? (type === "json" ? JSON.parse(staleRecord) : staleRecord) : realGet(key, type)
  );
  try {
    // The old password is accepted off the stale record (KV consistency, not new)...
    assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), true);
  } finally {
    env.STUDIQUO_DATA.get = realGet;
  }
  // ...but its upgrade must not have replaced the reset.
  assert.equal(await verifyLocalAccount(env, "person@example.com", "brand-new-password"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), false);
});

test("a reset that lands between the upgrade's read and its write is not overwritten", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "old-password-1");
  const original = engine.argon2idAsync;
  let first = true;
  // The upgrade's own Argon2id run is the window: reset while it computes.
  engine.argon2idAsync = async (...args) => {
    const result = await original(...args);
    if (first && args[0] === "old-password-1" && args[1].length === 24 && args[1][0] !== 0x5a) {
      first = false;
      await upsertLocalAccount(env, "person@example.com", "brand-new-password");
    }
    return result;
  };
  try {
    assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), true);
  } finally {
    engine.argon2idAsync = original;
  }
  assert.equal(await verifyLocalAccount(env, "person@example.com", "brand-new-password"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "old-password-1"), false);
});

test("a failed upgrade write never fails the sign-in", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "correct-horse-battery");
  env.RATE_COUNTER = { getByName: () => ({ upgradeAccountIfCurrent: async () => { throw new Error("DO down"); } }) };
  const originalError = console.error;
  console.error = () => {};
  try {
    assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  } finally {
    console.error = originalError;
  }
});

test("out-of-range Argon2id parameters or PBKDF2 iterations are treated as damaged, with the usual work", async () => {
  const env = environment();
  const base = { email: "x@example.com", salt: btoa("s".repeat(24)), passwordHash: btoa("h".repeat(32)) };
  const bad = {
    "hugeM@example.com": { ...base, algo: "argon2id", m: 32_769, t: 2, p: 1 },
    "zeroT@example.com": { ...base, algo: "argon2id", m: 19_456, t: 0, p: 1 },
    "hugeIter@example.com": { ...base, iterations: 50_000_000 },
    "noIter@example.com": { ...base },
    "oddAlgo@example.com": { ...base, algo: "scrypt", iterations: 100_000 },
  };
  for (const [email, record] of Object.entries(bad)) {
    await env.STUDIQUO_DATA.put(`account:local:${email}`, JSON.stringify(record));
    const calls = await countingWork(async () => {
      assert.equal(await verifyLocalAccount(env, email, "wrong-password"), false);
    });
    assert.deepEqual(calls, { pbkdf2: 1, argon2id: 1 }, email);
  }
});

test("a record with no generation is not upgraded once the account's generation has moved on", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "correct-horse-battery");
  // Something set a password since (the count is now 1), yet this legacy
  // record carries no stamp — as if an older instance wrote it afterwards.
  await env.RATE_COUNTER.getByName(`account-gen:${await sha256Hex("person@example.com")}`).nextAccountGeneration();
  const before = JSON.stringify(await storedRecord(env, "person@example.com"));

  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal(JSON.stringify(await storedRecord(env, "person@example.com")), before);
});

test("if the generation store is down, setting a password fails and the old record is untouched", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "old-password-1");
  const before = JSON.stringify(await storedRecord(env, "person@example.com"));

  env.RATE_COUNTER = { getByName: () => ({ nextAccountGeneration: async () => { throw new Error("DO down"); } }) };
  await assert.rejects(() => upsertLocalAccount(env, "person@example.com", "brand-new-password"), /DO down/);
  assert.equal(JSON.stringify(await storedRecord(env, "person@example.com")), before);
});

test("flag off -> on -> off: every record written along the way keeps signing in", async () => {
  const env = environment({ argon2Write: false });
  await upsertLocalAccount(env, "a@example.com", "password-for-a-1");
  env.ARGON2_WRITE = "true";
  await upsertLocalAccount(env, "b@example.com", "password-for-b-1");
  assert.equal(await verifyLocalAccount(env, "a@example.com", "password-for-a-1"), true);
  env.ARGON2_WRITE = "false";
  await upsertLocalAccount(env, "c@example.com", "password-for-c-1");

  assert.equal((await storedRecord(env, "a@example.com")).algo, "argon2id", "upgraded while on");
  assert.equal((await storedRecord(env, "b@example.com")).algo, "argon2id");
  assert.equal((await storedRecord(env, "c@example.com")).algo, undefined);
  for (const [email, password] of [["a", "password-for-a-1"], ["b", "password-for-b-1"], ["c", "password-for-c-1"]]) {
    assert.equal(await verifyLocalAccount(env, `${email}@example.com`, password), true, email);
    assert.equal(await verifyLocalAccount(env, `${email}@example.com`, "wrong-password"), false, email);
  }
});

// MARK: - the Argon2id queue limit

// Holds every Argon2id run until `release()`, so a test can fill the queue.
function holdArgon2() {
  const original = engine.argon2idAsync;
  let open;
  const gate = new Promise(resolve => { open = resolve; });
  let started = 0;
  engine.argon2idAsync = async (...args) => {
    started += 1;
    await gate;
    return original(...args);
  };
  return {
    started: () => started,
    release() { open(); },
    restore() { engine.argon2idAsync = original; },
  };
}

const tick = (ms = 20) => new Promise(resolve => setTimeout(resolve, ms));

// Waits until the queue really is full (2 running, 32 waiting). Each queued
// sign-in does a PBKDF2 run first, so this takes a moment; a probe sent before
// then would just join the queue and wait for the test to release it.
async function untilQueueFull() {
  for (let i = 0; i < 400; i++) {
    const { active, waiting } = argon2QueueState();
    if (active === 2 && waiting === 32) return;
    await tick(10);
  }
  throw new Error(`the queue never filled: ${JSON.stringify(argon2QueueState())}`);
}

// 2 running + 32 waiting: the most the queue takes before turning sign-ins away.
const FILL = 34;

test("when the Argon2id queue is full a sign-in is turned away at once, with nothing checked", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");
  const hold = holdArgon2();
  try {
    const running = Array.from({ length: FILL }, () => verifyLocalAccount(env, "nobody@example.com", "x").catch(error => error));
    await untilQueueFull();
    assert.equal(hold.started(), 2, "only two run at a time");

    // Every further attempt is refused immediately, whatever the address.
    for (const email of ["person@example.com", "nobody@example.com", "not-an-email"]) {
      await assert.rejects(() => verifyLocalAccount(env, email, "correct-horse-battery"), Argon2BusyError, email);
    }

    hold.release();
    const results = await Promise.all(running);
    assert.ok(results.every(result => result === false), "everyone already in the queue is still served");
  } finally {
    hold.release();
    hold.restore();
  }
});

test("the queue recovers fully after a rejection: later sign-ins work and nothing leaked", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");
  const hold = holdArgon2();
  try {
    const running = Array.from({ length: FILL }, () => verifyLocalAccount(env, "nobody@example.com", "x").catch(error => error));
    await untilQueueFull();
    for (let i = 0; i < 10; i++) await assert.rejects(() => verifyLocalAccount(env, "person@example.com", "x"), Argon2BusyError);
    hold.release();
    await Promise.all(running);
  } finally {
    hold.release();
    hold.restore();
  }
  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal(await verifyLocalAccount(env, "person@example.com", "wrong-password"), false);
  // And the full capacity is back: another fill is accepted without a rejection.
  const again = holdArgon2();
  try {
    const batch = Array.from({ length: FILL }, () => verifyLocalAccount(env, "nobody@example.com", "x").catch(error => error));
    await untilQueueFull();
    again.release();
    assert.ok((await Promise.all(batch)).every(result => result === false));
  } finally {
    again.release();
    again.restore();
  }
});

test("setting a password always queues, even when sign-ins are being turned away", async () => {
  const env = environment();
  const hold = holdArgon2();
  try {
    const running = Array.from({ length: FILL }, () => verifyLocalAccount(env, "nobody@example.com", "x").catch(error => error));
    await untilQueueFull();
    await assert.rejects(() => verifyLocalAccount(env, "nobody@example.com", "x"), Argon2BusyError);

    // Sign-up / reset happens after its one-time code is spent: it must wait, not fail.
    const signUp = upsertLocalAccount(env, "new@example.com", "brand-new-password");
    await tick(20);
    hold.release();
    await signUp;
    await Promise.all(running);
  } finally {
    hold.release();
    hold.restore();
  }
  assert.equal(await verifyLocalAccount(env, "new@example.com", "brand-new-password"), true);
});

test("a legacy sign-in whose optional upgrade finds the queue full still succeeds, skips it quietly and stays legacy", async () => {
  const env = environment();
  await seedLegacyAccount(env, "person@example.com", "correct-horse-battery");
  const before = JSON.stringify(await storedRecord(env, "person@example.com"));
  const originalError = console.error;
  const logs = [];
  console.error = line => logs.push(String(line));
  const original = hashers.argon2id;
  let calls = 0;
  // The first Argon2id run is the sign-in's own throwaway; the second is the upgrade's.
  hashers.argon2id = (...args) => {
    calls += 1;
    if (calls === 2) return Promise.reject(new Argon2BusyError());
    return original(...args);
  };
  try {
    assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  } finally {
    hashers.argon2id = original;
    console.error = originalError;
  }
  assert.equal(calls, 2);
  assert.equal(logs.filter(line => line.includes("upgrade failed")).length, 0, "a busy queue is not an error to log");
  assert.equal(JSON.stringify(await storedRecord(env, "person@example.com")), before, "left as it was, to be upgraded next time");
  // And the next sign-in, with room in the queue, does upgrade it.
  assert.equal(await verifyLocalAccount(env, "person@example.com", "correct-horse-battery"), true);
  assert.equal((await storedRecord(env, "person@example.com")).algo, "argon2id");
});

test("an Argon2BusyError is never confused with a damaged record", async () => {
  const env = environment();
  await upsertLocalAccount(env, "person@example.com", "correct-horse-battery");
  const hold = holdArgon2();
  let counted = 0;
  const originalPbkdf2 = hashers.pbkdf2;
  try {
    const running = Array.from({ length: FILL }, () => verifyLocalAccount(env, "nobody@example.com", "x").catch(error => error));
    await untilQueueFull();
    counted = 0;
    hashers.pbkdf2 = (...args) => { counted += 1; return originalPbkdf2(...args); };
    for (const email of ["person@example.com", "nobody@example.com", "not-an-email"]) {
      await assert.rejects(() => verifyLocalAccount(env, email, "x"), Argon2BusyError, email);
    }
    assert.equal(counted, 0, "a refused sign-in runs no hashing at all, so a flood of them costs no CPU and every address is refused equally fast");
    hold.release();
    await Promise.all(running);
  } finally {
    hashers.pbkdf2 = originalPbkdf2;
    hold.release();
    hold.restore();
  }
});
