// A revoked bearer token's SHA-256 hash is recorded here so every endpoint
// that authenticates with it can reject it even after logout, regardless of
// which module first derived the hash (worker.js, chat.js, passkeys.js all
// compute the same SHA-256 hex digest of the token).
const PREFIX = "revoked:";

export async function isRevoked(env, key) {
  return Boolean(await env.STUDIQUO_DATA.get(`${PREFIX}${key}`));
}

export async function revoke(env, key) {
  await env.STUDIQUO_DATA.put(`${PREFIX}${key}`, "1");
}
