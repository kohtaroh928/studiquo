// Shared "mint and record a bearer token" step every real sign-in (Apple,
// Google, local password, passkey) goes through. Recording the mint here is
// what lets requireRealSession() below refuse a token a client invented on
// its own in the same "<issued-at epoch>.<random>" shape, rather than
// trusting the token's own embedded timestamp as proof it's genuine.
import { sha256Hex } from "./auth.js";
import { VALIDITY_SECONDS } from "./token.js";

const SESSION_PREFIX = "session:";

/**
 * Mints a "<issued-at epoch>.<randomValue>" token for `identityKey`, records
 * it as a real, server-issued session (so requireRealSession can recognize
 * it later), and returns the token — or `null` if the resulting token falls
 * outside bearerToken()'s own 32-256 length window (auth.js). Every caller
 * already validates `randomValue`'s own length, but not the combined length
 * once the issued-at prefix is added, so this is the one place that check
 * can't be skipped.
 */
export async function mintSession(env, identityKey, randomValue) {
  const issuedAt = Math.floor(Date.now() / 1000);
  const token = `${issuedAt}.${randomValue}`;
  if (token.length < 32 || token.length > 256) return null;
  const key = await sha256Hex(token);
  await env.STUDIQUO_DATA.put(`${SESSION_PREFIX}${key}`, JSON.stringify({ sub: identityKey, issuedAt }), {
    expirationTtl: VALIDITY_SECONDS,
  });
  return token;
}

/**
 * True only for a token this server actually minted via mintSession — a
 * client-fabricated token in the same shape (right length, unexpired
 * timestamp) returns false even though isExpired(token) alone would accept
 * it.
 */
export async function hasRealSession(env, token) {
  const key = await sha256Hex(token);
  return (await env.STUDIQUO_DATA.get(`${SESSION_PREFIX}${key}`)) !== null;
}
