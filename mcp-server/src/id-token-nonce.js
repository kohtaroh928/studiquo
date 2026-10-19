// A nonce ties a Sign in with Apple / Google ID token to the one sign-in the app
// started. Without it, the Worker could only tell that an ID token was genuine
// (signed by Apple or Google, for this app, not expired), not that it was made for
// THIS sign-in: a copy taken from the app's traffic or its device could be sent
// again by someone else, and would be accepted until it expired.
//
// How it works:
//   1. The app makes a random nonce and keeps it (it never leaves the device
//      except to this Worker over TLS).
//   2. It asks Apple / Google to put the nonce's SHA-256 (lower-case hex) in the ID
//      token's `nonce` claim.
//   3. It sends this Worker the ID token AND the raw nonce.
//   4. The Worker checks that SHA-256(raw nonce) equals the token's `nonce` claim,
//      and that this nonce has not been used before (single use, one hour).
// Someone who holds only a copied ID token does not have the raw nonce, so the
// check fails; someone who copied the whole request is stopped by single use.
//
// A request with no nonce is a build from before this existed; it is accepted
// unless REQUIRE_ID_TOKEN_NONCE is "true", which is turned on once every build
// in use sends one.
import { secretsEqual, sha256Hex } from "./auth.js";

const RAW_NONCE = /^[A-Za-z0-9_-]{16,200}$/;
const SINGLE_USE_SECONDS = 3_600;

/**
 * One structured log line per sign-in, saying how its nonce fared. It is how the
 * rollout is watched: `absent` means a build that sends no nonce is still in use, so
 * REQUIRE_ID_TOKEN_NONCE is not yet safe to turn on. It carries no nonce, token or
 * account: only the provider and the outcome.
 *
 *   verified         the nonce matched and had not been used
 *   absent           no nonce was sent; accepted because nonces are not yet required
 *   absent_refused   no nonce was sent, and nonces are required
 *   malformed        the nonce is not in the accepted shape
 *   missing_claim    a nonce was sent but the ID token carries none
 *   mismatch         the nonce does not belong to the ID token
 *   replayed         the nonce was already used
 */
function logOutcome(provider, outcome) {
  console.log(JSON.stringify({ event: "id_token_nonce", provider, outcome }));
}

/** `false` when the sign-in may go on, `true` when it is to be refused. */
export async function idTokenNonceRefused(env, payload, suppliedNonce, provider = "unknown") {
  const refuse = outcome => { logOutcome(provider, outcome); return true; };
  if (suppliedNonce === undefined || suppliedNonce === null || suppliedNonce === "") {
    if (env.REQUIRE_ID_TOKEN_NONCE === "true") return refuse("absent_refused");
    logOutcome(provider, "absent");
    return false;
  }
  if (typeof suppliedNonce !== "string" || !RAW_NONCE.test(suppliedNonce)) return refuse("malformed");
  if (typeof payload?.nonce !== "string") return refuse("missing_claim");
  const expected = await sha256Hex(suppliedNonce);
  if (!(await secretsEqual(payload.nonce.toLowerCase(), expected))) return refuse("mismatch");
  // Atomic: the counter object admits exactly one caller per nonce.
  const firstUse = await env.RATE_COUNTER.getByName(`idtoken-nonce:${expected}`).bump(1, SINGLE_USE_SECONDS);
  if (!firstUse) return refuse("replayed");
  logOutcome(provider, "verified");
  return false;
}
