import assert from "node:assert/strict";
import test from "node:test";
import { linkVerifiedEmail, linkedIdentities } from "./oauth-links.js";

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

test("links a provider identity to a verified email", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "Person@Example.com", emailVerified: true });

  assert.equal(result.normalizedEmail, "person@example.com");
  assert.equal(result.canonicalIdentityKey, "apple-sub-1");
  assert.deepEqual(result.linkedIdentities, [{ provider: "apple", sub: "apple-sub-1" }]);
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [{ provider: "apple", sub: "apple-sub-1" }]);
});

test("a second provider with the same verified email resolves to the first identity's canonical account", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "person@example.com", emailVerified: true });
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-9", email: "person@example.com", emailVerified: true });

  assert.deepEqual(result.linkedIdentities, [
    { provider: "apple", sub: "apple-sub-1" },
    { provider: "google", sub: "google-sub-9" },
  ]);
  assert.equal(result.canonicalIdentityKey, "apple-sub-1", "the first verified identity remains the shared account owner");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:google:google-sub-9"), "apple-sub-1");
});

test("an unverified email is never linked", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: false });

  assert.equal(result.normalizedEmail, null);
  assert.deepEqual(result.linkedIdentities, []);
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), []);
});

test("a missing email is a no-op", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: null, emailVerified: true });

  assert.deepEqual(result.linkedIdentities, []);
});

test("re-linking the same provider identity does not duplicate it", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: true });
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: true });

  assert.deepEqual(result.linkedIdentities, [{ provider: "google", sub: "google-sub-1" }]);
});

test("email matching is case- and whitespace-insensitive", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "  Person@Example.com  ", emailVerified: true });

  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [{ provider: "apple", sub: "apple-sub-1" }]);
});

test("legacy email-accounts data migrates its first identity as the canonical owner", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("email-accounts:person@example.com", JSON.stringify([
    { provider: "apple", sub: "legacy-apple-sub" },
    { provider: "google", sub: "legacy-google-sub" },
  ]));

  const result = await linkVerifiedEmail(env, {
    provider: "google", sub: "legacy-google-sub", email: "person@example.com", emailVerified: true,
  });

  assert.equal(result.canonicalIdentityKey, "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("email-account-owner:person@example.com"), "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:legacy-apple-sub"), "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:google:legacy-google-sub"), "legacy-apple-sub");
});

// MARK: - fewer KV writes, same result

// The implementation before the write-reduction change, kept verbatim as the
// reference the new one must agree with.
const REF_EMAIL_LINK_PREFIX = "email-accounts:";
const REF_EMAIL_OWNER_PREFIX = "email-account-owner:";
const REF_IDENTITY_CANONICAL_PREFIX = "identity-canonical:";
const REF_MAX_LINKED_IDENTITIES = 10;
function refIdentityKey(identity) {
  if (identity.provider === "google") return `google:${identity.sub}`;
  if (identity.provider === "email") return `email:${identity.sub}`;
  return identity.sub;
}
async function referenceLinkVerifiedEmail(env, { provider, sub, email, emailVerified }) {
  const trimmed = typeof email === "string" ? email.trim().toLowerCase() : "";
  const normalized = trimmed.length > 0 && trimmed.length <= 254 && trimmed.includes("@") ? trimmed : null;
  if (!normalized || !emailVerified) return { normalizedEmail: null, linkedIdentities: [] };
  const linkKey = `${REF_EMAIL_LINK_PREFIX}${normalized}`;
  const existing = (await env.STUDIQUO_DATA.get(linkKey, "json")) ?? [];
  const alreadyLinked = existing.some(identity => identity.provider === provider && identity.sub === sub);
  const updated = alreadyLinked ? existing : [...existing, { provider, sub }].slice(-REF_MAX_LINKED_IDENTITIES);
  if (!alreadyLinked) await env.STUDIQUO_DATA.put(linkKey, JSON.stringify(updated));
  const ownerKey = `${REF_EMAIL_OWNER_PREFIX}${normalized}`;
  let canonicalIdentityKey = await env.STUDIQUO_DATA.get(ownerKey);
  if (!canonicalIdentityKey) {
    canonicalIdentityKey = refIdentityKey(updated[0]);
    await env.STUDIQUO_DATA.put(ownerKey, canonicalIdentityKey);
  }
  await Promise.all(updated.map(identity =>
    env.STUDIQUO_DATA.put(`${REF_IDENTITY_CANONICAL_PREFIX}${refIdentityKey(identity)}`, canonicalIdentityKey)
  ));
  return { normalizedEmail: normalized, linkedIdentities: updated, canonicalIdentityKey };
}

// An environment that counts reads and writes and tracks how many reads are
// in flight at once, over a KV that takes a moment to answer.
function countingEnvironment(seed = {}) {
  const values = new Map(Object.entries(seed));
  const stats = { gets: 0, puts: 0, putKeys: [], maxConcurrentGets: 0, inFlightGets: 0, readRounds: 0 };
  // Yields to the event loop without a timer's minimum delay, so operations still interleave.
  const pause = () => new Promise(resolve => setImmediate(resolve));
  return {
    stats,
    values,
    STUDIQUO_DATA: {
      async get(key, type) {
        stats.gets += 1;
        if (stats.inFlightGets === 0) stats.readRounds += 1;   // a read that starts with none in flight begins a new round
        stats.inFlightGets += 1;
        stats.maxConcurrentGets = Math.max(stats.maxConcurrentGets, stats.inFlightGets);
        await pause();
        stats.inFlightGets -= 1;
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { stats.puts += 1; stats.putKeys.push(key); await pause(); values.set(key, value); },
      async delete(key) { values.delete(key); },
    },
  };
}

const apple = { provider: "apple", sub: "apple-sub-1", email: "person@example.com", emailVerified: true };
const google = { provider: "google", sub: "g-1", email: "person@example.com", emailVerified: true };

test("a sign-in whose links are already right writes nothing at all", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  await linkVerifiedEmail(env, google);
  const before = [...env.values.entries()];

  env.stats.puts = 0; env.stats.putKeys = [];
  const again = await linkVerifiedEmail(env, google);
  assert.equal(env.stats.puts, 0, `unexpected writes: ${env.stats.putKeys.join(", ")}`);
  assert.deepEqual([...env.values.entries()], before);
  assert.equal(again.canonicalIdentityKey, "apple-sub-1");
  assert.deepEqual(again.linkedIdentities, [{ provider: "apple", sub: "apple-sub-1" }, { provider: "google", sub: "g-1" }]);
});

test("the link list and the owner are read at the same time, and so are the per-identity mappings", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  await linkVerifiedEmail(env, google);
  env.stats.maxConcurrentGets = 0; env.stats.gets = 0;
  await linkVerifiedEmail(env, google);
  // Two linked identities: the final round reads both mappings together (a serial
  // implementation never has more than one read in flight).
  assert.ok(env.stats.maxConcurrentGets >= 2, `max concurrent reads was ${env.stats.maxConcurrentGets}`);
  assert.equal(env.stats.gets, 4, "link list + owner + one mapping per linked identity");
});

test("a first-ever link writes exactly the link list, the owner and its own mapping", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  assert.deepEqual([...env.stats.putKeys].sort(), [
    "email-account-owner:person@example.com",
    "email-accounts:person@example.com",
    "identity-canonical:apple-sub-1",
  ]);
});

test("adding a second identity writes the list and only the new mapping, not the existing one", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  env.stats.puts = 0; env.stats.putKeys = [];
  await linkVerifiedEmail(env, google);
  assert.deepEqual([...env.stats.putKeys].sort(), ["email-accounts:person@example.com", "identity-canonical:google:g-1"]);
});

test("a mapping that is missing or wrong is repaired, for any identity of the email, when anyone signs in", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  await linkVerifiedEmail(env, google);
  // Drift: the Google mapping vanished and the Apple one points elsewhere.
  env.values.delete("identity-canonical:google:g-1");
  env.values.set("identity-canonical:apple-sub-1", "someone-else");

  await linkVerifiedEmail(env, apple);   // an Apple sign-in repairs Google's mapping too

  assert.equal(env.values.get("identity-canonical:google:g-1"), "apple-sub-1");
  assert.equal(env.values.get("identity-canonical:apple-sub-1"), "apple-sub-1");
});

test("an index from an older deployment with no owner record gets one, and every mapping", async () => {
  const env = countingEnvironment({ "email-accounts:person@example.com": JSON.stringify([{ provider: "apple", sub: "apple-sub-1" }, { provider: "google", sub: "g-1" }]) });
  const result = await linkVerifiedEmail(env, google);
  assert.equal(result.canonicalIdentityKey, "apple-sub-1");
  assert.equal(env.values.get("email-account-owner:person@example.com"), "apple-sub-1");
  assert.equal(env.values.get("identity-canonical:apple-sub-1"), "apple-sub-1");
  assert.equal(env.values.get("identity-canonical:google:g-1"), "apple-sub-1");
});

test("an unverified or missing email does no KV work at all", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, { ...apple, emailVerified: false });
  await linkVerifiedEmail(env, { ...apple, email: undefined });
  await linkVerifiedEmail(env, { ...apple, email: "no-at-sign" });
  assert.equal(env.stats.gets + env.stats.puts, 0);
});

// A tiny seeded generator, so a failure can be reproduced.
function makeRandom(seed) {
  let state = seed >>> 0;
  return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 2 ** 32; };
}

test("differential: for random histories (with random drift in the stored data) the new code ends in exactly the state the old code did, and returns the same thing", async () => {
  const providers = ["apple", "google", "email"];
  const emails = ["a@example.com", "B@Example.com ", "c@example.com", "not-an-email", ""];
  for (let seed = 1; seed <= 300; seed++) {
    const random = makeRandom(seed);
    const pick = list => list[Math.floor(random() * list.length)];
    const subs = ["s1", "s2", "s3", "s4"];

    // The same random starting data for both: possibly stale, partial or wrong.
    const startValues = {};
    for (const email of ["a@example.com", "b@example.com", "c@example.com"]) {
      if (random() < 0.5) {
        const list = Array.from({ length: Math.floor(random() * 4) }, () => ({ provider: pick(providers), sub: pick(subs) }));
        startValues[`email-accounts:${email}`] = JSON.stringify(list);
        if (random() < 0.5) startValues[`email-account-owner:${email}`] = random() < 0.8 ? `owner-of-${email}` : "";
        for (const identity of list) {
          if (random() < 0.5) startValues[`identity-canonical:${refIdentityKey(identity)}`] = random() < 0.7 ? `owner-of-${email}` : "stale-value";
        }
      }
    }
    const oldEnv = countingEnvironment(startValues);
    const newEnv = countingEnvironment(startValues);

    for (let step = 0; step < 12; step++) {
      const input = { provider: pick(providers), sub: pick(subs), email: pick(emails), emailVerified: random() < 0.85 };
      const expected = await referenceLinkVerifiedEmail(oldEnv, input);
      const actual = await linkVerifiedEmail(newEnv, input);
      assert.deepEqual(actual, expected, `seed ${seed} step ${step}: return value differs for ${JSON.stringify(input)}`);
      assert.deepEqual([...newEnv.values.entries()].sort(), [...oldEnv.values.entries()].sort(), `seed ${seed} step ${step}: stored state differs after ${JSON.stringify(input)}`);
    }
    assert.ok(newEnv.stats.puts <= oldEnv.stats.puts, `seed ${seed}: the new code wrote more than the old one`);
  }
});

test("in steady state the new code does a small fraction of the old code's writes", async () => {
  const oldEnv = countingEnvironment();
  const newEnv = countingEnvironment();
  for (const input of [apple, google, apple, google, apple, google, apple, google]) {
    await referenceLinkVerifiedEmail(oldEnv, input);
    await linkVerifiedEmail(newEnv, input);
  }
  // The new code writes only what changed: the list twice (two identities were added),
  // the owner once, and each identity's mapping once. The old code rewrote every
  // mapping on every call.
  assert.equal(newEnv.stats.puts, 5, `new puts: ${newEnv.stats.puts}`);
  assert.ok(oldEnv.stats.puts > 3 * newEnv.stats.puts, `old puts: ${oldEnv.stats.puts}, new puts: ${newEnv.stats.puts}`);
});

test("a returning sign-in with a single linked identity needs ONE round of reads, and no writes", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  env.stats.readRounds = 0; env.stats.puts = 0;
  await linkVerifiedEmail(env, apple);
  assert.equal(env.stats.readRounds, 1);
  assert.equal(env.stats.puts, 0);
});

test("with several linked identities it takes two rounds of reads (the others' mappings come second), still no writes", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  await linkVerifiedEmail(env, google);
  env.stats.readRounds = 0; env.stats.puts = 0;
  await linkVerifiedEmail(env, google);
  assert.equal(env.stats.readRounds, 2);
  assert.equal(env.stats.puts, 0);
});

// MARK: - the cases the review asked to pin down

test("two first sign-ins for the same address arriving together end exactly as they did with the old code", async () => {
  // Same KV, same delays, same arrival: if the old code let them split into two
  // accounts, the new one may not do any worse, and must not do anything different.
  const oldEnv = countingEnvironment();
  const newEnv = countingEnvironment();
  const [oldA, oldB] = await Promise.all([referenceLinkVerifiedEmail(oldEnv, apple), referenceLinkVerifiedEmail(oldEnv, google)]);
  const [newA, newB] = await Promise.all([linkVerifiedEmail(newEnv, apple), linkVerifiedEmail(newEnv, google)]);
  assert.deepEqual([...newEnv.values.entries()].sort(), [...oldEnv.values.entries()].sort());
  assert.deepEqual([newA, newB], [oldA, oldB]);

  // And the very next sign-in by either one repairs whatever the race left behind.
  await linkVerifiedEmail(newEnv, apple);
  await linkVerifiedEmail(newEnv, google);
  const owner = newEnv.values.get("email-account-owner:person@example.com");
  const listed = JSON.parse(newEnv.values.get("email-accounts:person@example.com"));
  for (const identity of listed) {
    const key = identity.provider === "google" ? `google:${identity.sub}` : identity.sub;
    assert.equal(newEnv.values.get(`identity-canonical:${key}`), owner, `${key} should map to the owner`);
  }
});

test("more than ten linked identities keep only the latest ten, exactly as before", async () => {
  const oldEnv = countingEnvironment();
  const newEnv = countingEnvironment();
  for (let i = 1; i <= 14; i++) {
    const input = { provider: "google", sub: `g-${i}`, email: "person@example.com", emailVerified: true };
    const expected = await referenceLinkVerifiedEmail(oldEnv, input);
    const actual = await linkVerifiedEmail(newEnv, input);
    assert.deepEqual(actual, expected, `identity ${i}`);
  }
  assert.deepEqual([...newEnv.values.entries()].sort(), [...oldEnv.values.entries()].sort());
  const listed = JSON.parse(newEnv.values.get("email-accounts:person@example.com"));
  assert.equal(listed.length, 10);
  assert.equal(listed[0].sub, "g-5");
  assert.equal(listed[9].sub, "g-14");
});

test("differential, long histories on one address (reaches the ten-identity limit and its drift)", async () => {
  for (let seed = 1000; seed < 1060; seed++) {
    const random = makeRandom(seed);
    const pick = list => list[Math.floor(random() * list.length)];
    const providers = ["apple", "google", "email"];
    const subs = Array.from({ length: 16 }, (_, i) => `s${i}`);
    const oldEnv = countingEnvironment();
    const newEnv = countingEnvironment();
    for (let step = 0; step < 40; step++) {
      const input = { provider: pick(providers), sub: pick(subs), email: "one@example.com", emailVerified: true };
      // Now and then, damage a mapping or the owner in both worlds the same way.
      if (random() < 0.15) {
        const key = pick([...oldEnv.values.keys()]);
        if (key && key.startsWith("identity-canonical:")) { oldEnv.values.delete(key); newEnv.values.delete(key); }
      }
      const expected = await referenceLinkVerifiedEmail(oldEnv, input);
      const actual = await linkVerifiedEmail(newEnv, input);
      assert.deepEqual(actual, expected, `seed ${seed} step ${step}`);
      assert.deepEqual([...newEnv.values.entries()].sort(), [...oldEnv.values.entries()].sort(), `seed ${seed} step ${step}`);
    }
  }
});

test("if the link-list write fails, nothing after it is written (the original order is kept for anything that changes the index)", async () => {
  const env = countingEnvironment();
  const realPut = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (key, value) => {
    if (key.startsWith("email-accounts:")) throw new Error("KV write failed");
    return realPut(key, value);
  };
  await assert.rejects(() => linkVerifiedEmail(env, apple), /KV write failed/);
  assert.equal(env.values.has("email-account-owner:person@example.com"), false);
  assert.equal(env.values.has("identity-canonical:apple-sub-1"), false);
});

test("an identity that is already linked but whose owner record is missing is handled the original way (the owner is chosen from a fresh read)", async () => {
  const env = countingEnvironment({ "email-accounts:person@example.com": JSON.stringify([{ provider: "apple", sub: "apple-sub-1" }]) });
  // The owner shows up between the first read and the decision: the later read must win.
  const realGet = env.STUDIQUO_DATA.get;
  let ownerReads = 0;
  env.STUDIQUO_DATA.get = async (key, type) => {
    if (key === "email-account-owner:person@example.com") {
      ownerReads += 1;
      if (ownerReads >= 2) return "google:somebody-else";
    }
    return realGet(key, type);
  };
  const result = await linkVerifiedEmail(env, apple);
  assert.equal(ownerReads, 2, "the owner is read again, just before it would be written");
  assert.equal(result.canonicalIdentityKey, "google:somebody-else");
  assert.equal(env.values.has("email-account-owner:person@example.com"), false, "an owner that appeared meanwhile is not overwritten");
});

test("the common case never takes the slow path: no second read of the list or the owner", async () => {
  const env = countingEnvironment();
  await linkVerifiedEmail(env, apple);
  const reads = [];
  const realGet = env.STUDIQUO_DATA.get;
  env.STUDIQUO_DATA.get = async (key, type) => { reads.push(key); return realGet(key, type); };
  await linkVerifiedEmail(env, apple);
  assert.equal(reads.filter(key => key === "email-accounts:person@example.com").length, 1);
  assert.equal(reads.filter(key => key === "email-account-owner:person@example.com").length, 1);
});
