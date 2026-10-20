// Signed tokens: a token the Worker minted carries a signature only the Worker
// can compute, so one that was made up can be refused WITHOUT reading KV.
//
// Why it matters: every request with a bearer token used to cost a KV read to
// find out whether the token was real, and a token's shape ("<epoch>.<random>")
// is easy to imitate. Anyone could send a flood of invented tokens, each one
// making the Worker read KV, until the account-wide KV limits were spent and
// real people were locked out. An IP-based rate limit slows one address down but
// not many. A signature check is a few microseconds of arithmetic and touches no
// storage, so the flood is turned away for free, from any number of addresses.
//
// Forms:
//   session token   "<issued-at epoch>.<random>.<signature>"   (was without the last part)
//   MCP access token "mcp_<64 hex>.<signature>"                (was without the last part)
// The signature is HMAC-SHA256 over the earlier part, base64url, 43 characters.
// A token with no signature is "legacy": it is still accepted (so existing
// logins keep working) unless REQUIRE_SIGNED_TOKENS is "true".
//
// Keys come from Worker secrets (never the repository):
//   TOKEN_SIGNING_KEY       base64 of at least 32 random bytes; new tokens are signed with it
//   TOKEN_SIGNING_KEY_OLD   the previous key, still accepted for checking while its tokens
//                           run out (rotation)
// With no key set nothing is signed or checked, which is how it behaves until the
// secret is added.
import { secretsEqual } from "./auth.ts";

const encoder = new TextEncoder();
const SESSION_LABEL = "studiquo-session-token-v1:";
const ACCESS_LABEL = "studiquo-mcp-access-token-v1:";

// "<epoch>.<random>.<43-character signature>". The random part of a token the app
// supplies never contains a dot; requiring the exact signature shape keeps a
// legacy token from being mistaken for a signed one.
const SIGNED_SESSION = /^(\d{9,12}\.[A-Za-z0-9_-]{16,200})\.([A-Za-z0-9_-]{43})$/;
const SIGNED_ACCESS = /^(mcp_[0-9a-f]{64})\.([A-Za-z0-9_-]{43})$/;
export const LEGACY_ACCESS = /^mcp_[0-9a-f]{64}$/;

const importedKeys = new Map();

function base64Bytes(value) {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0));
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function hmacKey(secret) {
  const cached = importedKeys.get(secret);
  if (cached) return cached;
  const raw = base64Bytes(String(secret).trim());
  if (raw.length < 32) throw new Error("TOKEN_SIGNING_KEY must be at least 32 bytes, base64-encoded.");
  const key = crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  importedKeys.set(secret, key);
  return key;
}

async function signature(secret, label, payload) {
  const digest = await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(label + payload));
  return base64Url(new Uint8Array(digest));
}

function signingKey(env) {
  return env.TOKEN_SIGNING_KEY || null;
}

function checkingKeys(env) {
  return [env.TOKEN_SIGNING_KEY, env.TOKEN_SIGNING_KEY_OLD].filter(Boolean);
}

async function matchesAnyKey(env, label, payload, presented) {
  for (const secret of checkingKeys(env)) {
    if (await secretsEqual(presented, await signature(secret, label, payload))) return true;
  }
  return false;
}

/** The token with its signature appended, or `payload` unchanged when no key is configured. */
export async function signSessionToken(env, payload) {
  const key = signingKey(env);
  return key ? `${payload}.${await signature(key, SESSION_LABEL, payload)}` : payload;
}

export async function signAccessToken(env, payload) {
  const key = signingKey(env);
  return key ? `${payload}.${await signature(key, ACCESS_LABEL, payload)}` : payload;
}

function signedRequired(env) {
  return env.REQUIRE_SIGNED_TOKENS === "true";
}

/**
 * Whether a session bearer token may go on to a KV lookup. False for a token that
 * carries a wrong signature, and, when REQUIRE_SIGNED_TOKENS is on, for one that
 * carries none. True when no key is configured (nothing can be checked).
 */
export async function sessionTokenAcceptable(env, token) {
  if (checkingKeys(env).length === 0) return true;
  const signed = SIGNED_SESSION.exec(token);
  if (!signed) return !signedRequired(env);
  return matchesAnyKey(env, SESSION_LABEL, signed[1], signed[2]);
}

/**
 * The same for an MCP access token ("mcp_…"). With a key configured, a token that is
 * neither of the two shapes this Worker issues is refused: nothing legitimate looks
 * like that, and it costs no KV read to say so.
 */
export async function accessTokenAcceptable(env, token) {
  if (checkingKeys(env).length === 0) return true;
  if (LEGACY_ACCESS.test(token)) return !signedRequired(env);
  const signed = SIGNED_ACCESS.exec(token);
  if (!signed) return false;
  return matchesAnyKey(env, ACCESS_LABEL, signed[1], signed[2]);
}
