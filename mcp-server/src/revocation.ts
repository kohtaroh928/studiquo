import { VALIDITY_SECONDS } from "./token.ts";
import type { Env } from "./env.ts";
// A revoked bearer token's SHA-256 hash is recorded here so every endpoint
// that authenticates with it can reject it even after logout, regardless of
// which module first derived the hash (worker.ts, chat.ts, passkeys.ts all
// compute the same SHA-256 hex digest of the token).
const PREFIX = "revoked:";

export async function isRevoked(env: Env, key: string) {
  return Boolean(await env.STUDIQUO_DATA.get(`${PREFIX}${key}`));
}

// A token is refused after VALIDITY_SECONDS whatever its revocation record
// says, so the record only has to outlive that (with a day's margin).
const TTL_SECONDS = VALIDITY_SECONDS + 86_400;

export async function revoke(env: Env, key: string) {
  await env.STUDIQUO_DATA.put(`${PREFIX}${key}`, "1", { expirationTtl: TTL_SECONDS });
}

// A refresh replaces a token but keeps the old one alive for a grace period (see
// handleSessionRefresh). The new token records which one it replaced, so that
// logging out the new one also ends the old one instead of leaving it usable
// for up to the rest of that grace period.
const PREDECESSOR_PREFIX = "session-predecessor:";
// Refreshes are at least 7 days apart and a replaced token lives at most 14 days,
// so only a short chain can still be alive; the bound also stops a corrupt loop.
const MAX_PREDECESSOR_HOPS = 5;

export async function recordPredecessor(env: Env, newKey: string, oldKey: string, ttlSeconds: number) {
  if (ttlSeconds <= 0) return;
  // KV needs at least 60 seconds of expiration.
  await env.STUDIQUO_DATA.put(`${PREDECESSOR_PREFIX}${newKey}`, oldKey, { expirationTtl: Math.max(60, Math.floor(ttlSeconds)) });
}

/** Revokes the token and every token it replaced that could still be alive. */
export async function revokeWithPredecessors(env: Env, key: string) {
  const seen = new Set<string>();
  let current: string | null = key;
  for (let hop = 0; current && !seen.has(current) && hop <= MAX_PREDECESSOR_HOPS; hop++) {
    seen.add(current);
    await revoke(env, current);
    current = await env.STUDIQUO_DATA.get(`${PREDECESSOR_PREFIX}${current}`);
  }
}
