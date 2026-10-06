// Local email/password accounts. The password itself is only ever sent to
// this server once per set (signup or reset), over HTTPS, and is never
// stored or logged — only a salted, memory-hard hash is kept.
//
// New and reset passwords are hashed with Argon2id at OWASP's minimum
// recommended cost (m=19 MiB, t=2, p=1). Accounts created before that were
// hashed with PBKDF2-SHA256; they keep verifying with it and are upgraded to
// Argon2id the next time their owner signs in with the right password (the
// only moment the plaintext is available), so no one has to reset anything.
//
// Rollout is two-step on purpose. This code always READS both formats, but
// only WRITES Argon2id when the ARGON2_WRITE var is "true". Deploy with it
// off first: that version is the safe thing to roll back to, because rolling
// back to code from before Argon2id existed would lock out every account
// already rewritten. Turn it on in a second deploy once the first is stable.
import { argon2idAsync } from "@noble/hashes/argon2.js";
import { sha256Hex } from "./auth.js";

const ACCOUNT_PREFIX = "account:local:";

const ARGON2 = { m: 19_456, t: 2, p: 1, dkLen: 32 };
// A record is only ever written by this module, but its parameters decide how
// much memory and CPU a login costs, so anything out of range is treated as
// damaged rather than honoured.
const ARGON2_LIMITS = { m: 32_768, t: 10, p: 4 };

// Legacy PBKDF2 cost, kept so records written before the move still verify.
// 100,000 iterations of PBKDF2-SHA256 sat comfortably inside the Workers
// CPU budget when it was chosen.
const PBKDF2_ITERATIONS = 100_000;

// One Argon2id run holds ~19 MiB, and a Worker isolate has 128 MiB for
// everything: a burst of simultaneous logins must queue rather than all
// allocate at once. Waiting costs wall-clock time, not CPU time.
const MAX_CONCURRENT_ARGON2 = 2;
let activeArgon2 = 0;
const argon2Waiters = [];

async function withArgon2Slot(work) {
  if (activeArgon2 >= MAX_CONCURRENT_ARGON2) {
    // The slot is handed over by whoever finishes (active stays counted).
    await new Promise(resolve => argon2Waiters.push(resolve));
  } else {
    activeArgon2 += 1;
  }
  try {
    return await work();
  } finally {
    const next = argon2Waiters.shift();
    if (next) next();
    else activeArgon2 -= 1;
  }
}

async function pbkdf2(password, salt, iterations) {
  const keyMaterial = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, keyMaterial, 256);
  return new Uint8Array(bits);
}

// The actual Argon2id computation, behind the queue above. Exposed so tests
// can watch how many run at once.
export const engine = { argon2idAsync };

function argon2id(password, salt, { m, t, p }) {
  return withArgon2Slot(() => engine.argon2idAsync(password, salt, { m, t, p, dkLen: ARGON2.dkLen }));
}

// The two primitives, reachable through one object so tests can observe how
// much work each login path really does.
export const hashers = { pbkdf2, argon2id };

function normalizeEmail(email) {
  if (typeof email !== "string") return null;
  const trimmed = email.trim().toLowerCase();
  return trimmed.length > 0 && trimmed.length <= 254 && trimmed.includes("@") ? trimmed : null;
}

function toBase64(bytes) {
  return btoa(String.fromCharCode(...bytes));
}

function fromBase64(value) {
  return Uint8Array.from(atob(value), char => char.charCodeAt(0));
}

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

function argon2Writes(env) {
  return env.ARGON2_WRITE === "true";
}

async function newArgon2Record(normalized, password, gen) {
  const salt = crypto.getRandomValues(new Uint8Array(24));
  const passwordHash = await hashers.argon2id(password, salt, ARGON2);
  return {
    email: normalized,
    algo: "argon2id",
    m: ARGON2.m,
    t: ARGON2.t,
    p: ARGON2.p,
    salt: toBase64(salt),
    passwordHash: toBase64(passwordHash),
    gen,
    updatedAt: new Date().toISOString(),
  };
}

async function newLegacyRecord(normalized, password, gen) {
  const salt = crypto.getRandomValues(new Uint8Array(24));
  const passwordHash = await hashers.pbkdf2(password, salt, PBKDF2_ITERATIONS);
  return {
    email: normalized,
    salt: toBase64(salt),
    passwordHash: toBase64(passwordHash),
    iterations: PBKDF2_ITERATIONS,
    gen,
    updatedAt: new Date().toISOString(),
  };
}

// Each account has a "generation" held in a Durable Object (one at a time, so
// the count can't race). Every password set bumps it and stamps the number on
// the record it writes. A legacy→Argon2id upgrade is applied by that same
// object only if the generation on the record it started from is still the
// current one. KV alone can't give that guarantee: it has no compare-and-swap
// and a read can be up to a minute stale, so "re-read, compare, write" could
// still bring back a password the owner had just replaced. A stale read
// carries a stale generation, which no longer matches.
function generationStub(env, emailHash) {
  return env.RATE_COUNTER.getByName(`account-gen:${emailHash}`);
}

/**
 * Creates or overwrites the local account for `email` with a freshly hashed
 * `password`. Used for both initial signup (after email verification) and
 * password reset (after re-verification) — "set (or replace) the password
 * hash for this now-verified email" is the same operation either way, so
 * there is no separate reset path to keep in sync with this one. A reset
 * also replaces any legacy PBKDF2 record.
 *
 * Throws if `email`/`password` don't pass basic validation.
 */
export async function upsertLocalAccount(env, email, password) {
  const normalized = normalizeEmail(email);
  if (!normalized) throw new Error("Invalid email address.");
  if (typeof password !== "string" || password.length < 8 || password.length > 1_024) {
    throw new Error("Invalid password.");
  }
  // Bumped before the record is written, so an in-flight upgrade that started
  // from the previous record is already refused by the time this one lands.
  const gen = await generationStub(env, await sha256Hex(normalized)).nextAccountGeneration();
  const record = argon2Writes(env)
    ? await newArgon2Record(normalized, password, gen)
    : await newLegacyRecord(normalized, password, gen);
  await env.STUDIQUO_DATA.put(`${ACCOUNT_PREFIX}${normalized}`, JSON.stringify(record));
}

// Fixed, public, never matches a real account: they only exist so the paths
// that find no usable record (or a record of the other kind) cost the same
// as one that does. See verifyLocalAccount.
const DUMMY_SALT = new Uint8Array(24).fill(0x5a);

function dummyPbkdf2(password) {
  return hashers.pbkdf2(password, DUMMY_SALT, PBKDF2_ITERATIONS);
}

function dummyArgon2(password) {
  return hashers.argon2id(password, DUMMY_SALT, ARGON2);
}

async function rejectAfterDummyWork(password) {
  const text = typeof password === "string" ? password : "";
  await dummyPbkdf2(text);
  await dummyArgon2(text);
  return false;
}

function argon2ParamsOf(record) {
  const { m, t, p } = record;
  const ok = [m, t, p].every(Number.isInteger) && m >= 8 && t >= 1 && p >= 1
    && m <= ARGON2_LIMITS.m && t <= ARGON2_LIMITS.t && p <= ARGON2_LIMITS.p;
  return ok ? { m, t, p } : null;
}

// Moves a legacy record to Argon2id after a correct password, but only if no
// password was set since this record was read (see the generation note above).
async function upgradeLegacyRecord(env, key, original, normalized, password) {
  if (!argon2Writes(env)) return;
  try {
    const expectedGen = Number.isInteger(original.gen) ? original.gen : 0;
    const upgraded = await newArgon2Record(normalized, password, expectedGen);
    await generationStub(env, await sha256Hex(normalized)).upgradeAccountIfCurrent(key, JSON.stringify(upgraded), expectedGen);
  } catch (error) {
    console.error(JSON.stringify({ message: "password hash upgrade failed", error: error instanceof Error ? error.message : String(error) }));
  }
}

function legacyIterationsOf(record) {
  const { iterations } = record;
  const known = record.algo === undefined || record.algo === "pbkdf2";
  return known && Number.isInteger(iterations) && iterations >= 1 && iterations <= 1_000_000 ? iterations : null;
}

/**
 * Verifies `password` against the stored hash for `email`. Returns `false`
 * (never throws) for an unknown email, a malformed record, or a wrong
 * password — callers can't distinguish "no such account" from "wrong
 * password" from this alone, deliberately, same as every other login check
 * in this codebase.
 *
 * It holds for response time too: every path does exactly one PBKDF2 run and
 * one Argon2id run. The one matching the record's own algorithm is real, the
 * other is a throwaway, and an unknown email runs two throwaways. Without
 * that, an account on Argon2id, one still on PBKDF2 and a made-up address
 * would all answer at different speeds. TEMPORARY: once no legacy PBKDF2
 * records remain, drop the PBKDF2 half (and the legacy branch below).
 */
export async function verifyLocalAccount(env, email, password) {
  const normalized = normalizeEmail(email);
  if (!normalized || typeof password !== "string") return rejectAfterDummyWork(password);
  const key = `${ACCOUNT_PREFIX}${normalized}`;
  const record = await env.STUDIQUO_DATA.get(key, "json");
  if (!record) return rejectAfterDummyWork(password);

  try {
    if (record.algo === "argon2id") {
      const params = argon2ParamsOf(record);
      if (!params) return rejectAfterDummyWork(password);
      const stored = fromBase64(record.passwordHash);
      const candidate = await hashers.argon2id(password, fromBase64(record.salt), params);
      await dummyPbkdf2(password);
      return constantTimeEqual(candidate, stored);
    }

    // Legacy: PBKDF2-SHA256.
    const iterations = legacyIterationsOf(record);
    if (!iterations) return rejectAfterDummyWork(password);
    const stored = fromBase64(record.passwordHash);
    const candidate = await hashers.pbkdf2(password, fromBase64(record.salt), iterations);
    await dummyArgon2(password);
    if (!constantTimeEqual(candidate, stored)) return false;
    await upgradeLegacyRecord(env, key, record, normalized, password);
    return true;
  } catch {
    return rejectAfterDummyWork(password);
  }
}
