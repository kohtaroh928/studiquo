// Local email/password accounts. The password itself is only ever sent to
// this server once per set (signup or reset), over HTTPS, and is never
// stored or logged — only a salted PBKDF2 hash is kept, the same standard
// model every mainstream app uses for a password it verifies server-side.
const ACCOUNT_PREFIX = "account:local:";
// Server-side hashing runs on every login under a Workers CPU-time budget
// shared with everything else the isolate does that tick, unlike the
// client's own (now-retired) 1,000,000-iteration hash, which was a
// device-only cost paid on hardware picked to make that cheap. 100,000
// iterations of PBKDF2-SHA256 stays comfortably inside that budget while
// remaining well above NIST's 10,000-iteration floor.
const PBKDF2_ITERATIONS = 100_000;

function normalizeEmail(email) {
  if (typeof email !== "string") return null;
  const trimmed = email.trim().toLowerCase();
  return trimmed.length > 0 && trimmed.length <= 254 && trimmed.includes("@") ? trimmed : null;
}

async function pbkdf2Hash(password, salt, iterations) {
  const keyMaterial = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, keyMaterial, 256);
  return new Uint8Array(bits);
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

/**
 * Creates or overwrites the local account for `email` with a freshly hashed
 * `password`. Used for both initial signup (after email verification) and
 * password reset (after re-verification) — "set (or replace) the password
 * hash for this now-verified email" is the same operation either way, so
 * there is no separate reset path to keep in sync with this one.
 *
 * Throws if `email`/`password` don't pass basic validation.
 */
export async function upsertLocalAccount(env, email, password) {
  const normalized = normalizeEmail(email);
  if (!normalized) throw new Error("Invalid email address.");
  if (typeof password !== "string" || password.length < 8 || password.length > 1_024) {
    throw new Error("Invalid password.");
  }
  const salt = crypto.getRandomValues(new Uint8Array(24));
  const passwordHash = await pbkdf2Hash(password, salt, PBKDF2_ITERATIONS);
  await env.STUDIQUO_DATA.put(`${ACCOUNT_PREFIX}${normalized}`, JSON.stringify({
    email: normalized,
    salt: toBase64(salt),
    passwordHash: toBase64(passwordHash),
    iterations: PBKDF2_ITERATIONS,
    updatedAt: new Date().toISOString(),
  }));
}

/**
 * Verifies `password` against the stored hash for `email`. Returns `false`
 * (never throws) for an unknown email, a malformed record, or a wrong
 * password — callers can't distinguish "no such account" from "wrong
 * password" from this alone, deliberately, same as every other login check
 * in this codebase.
 */
export async function verifyLocalAccount(env, email, password) {
  const normalized = normalizeEmail(email);
  if (!normalized || typeof password !== "string") return false;
  const record = await env.STUDIQUO_DATA.get(`${ACCOUNT_PREFIX}${normalized}`, "json");
  if (!record) return false;
  const candidate = await pbkdf2Hash(password, fromBase64(record.salt), record.iterations);
  return constantTimeEqual(candidate, fromBase64(record.passwordHash));
}
