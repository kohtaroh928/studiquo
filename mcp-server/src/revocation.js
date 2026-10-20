import { VALIDITY_SECONDS } from "./token.ts";
// A revoked bearer token's SHA-256 hash is recorded here so every endpoint
// that authenticates with it can reject it even after logout, regardless of
// which module first derived the hash (worker.js, chat.js, passkeys.js all
// compute the same SHA-256 hex digest of the token).
const PREFIX = "revoked:";

export async function isRevoked(env, key) {
  return Boolean(await env.STUDIQUO_DATA.get(`${PREFIX}${key}`));
}

// A token is refused after VALIDITY_SECONDS whatever its revocation record
// says, so the record only has to outlive that (with a day's margin).
const TTL_SECONDS = VALIDITY_SECONDS + 86_400;

export async function revoke(env, key) {
  await env.STUDIQUO_DATA.put(`${PREFIX}${key}`, "1", { expirationTtl: TTL_SECONDS });
}
