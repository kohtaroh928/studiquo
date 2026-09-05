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
