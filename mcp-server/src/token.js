// Tokens are minted client-side as "<issued-at epoch seconds>.<random secret>"
// (see MCPCloudCredentials.makeToken in the iOS app) so the server can enforce
// an expiry without having to remember when it first saw any given token.
export const VALIDITY_SECONDS = 90 * 24 * 60 * 60;

export function isExpired(token) {
  const dot = token.indexOf(".");
  if (dot <= 0) return true;
  const issuedAt = Number(token.slice(0, dot));
  if (!Number.isFinite(issuedAt) || issuedAt <= 0) return true;
  return Date.now() / 1000 - issuedAt > VALIDITY_SECONDS;
}

const KV_MINIMUM_TTL_SECONDS = 60;

// Seconds until the session this token belongs to stops being valid. Data that
// is stored under a token's hash (the synced snapshot, queued actions) is given
// this as its KV expiry, so it disappears together with the session. Account
// deletion finds a token's data through the live session rows; without this a
// snapshot written under a token whose session has long since expired could
// never be traced back to its owner and would stay forever.
export function remainingValiditySeconds(token, nowMs = Date.now()) {
  const dot = token.indexOf(".");
  const issuedAt = dot > 0 ? Number(token.slice(0, dot)) : NaN;
  if (!Number.isFinite(issuedAt) || issuedAt <= 0) return KV_MINIMUM_TTL_SECONDS;
  const remaining = Math.ceil(issuedAt + VALIDITY_SECONDS - nowMs / 1000);
  return Math.min(VALIDITY_SECONDS, Math.max(KV_MINIMUM_TTL_SECONDS, remaining));
}
