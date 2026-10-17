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

/** `null` when the sign-in may go on, otherwise true (refuse it). */
export async function idTokenNonceRefused(env, payload, suppliedNonce) {
  if (suppliedNonce === undefined || suppliedNonce === null || suppliedNonce === "") {
    return env.REQUIRE_ID_TOKEN_NONCE === "true";
  }
  if (typeof suppliedNonce !== "string" || !RAW_NONCE.test(suppliedNonce)) return true;
  if (typeof payload?.nonce !== "string") return true;
  const expected = await sha256Hex(suppliedNonce);
  if (!(await secretsEqual(payload.nonce.toLowerCase(), expected))) return true;
  // Atomic: the counter object admits exactly one caller per nonce.
  const firstUse = await env.RATE_COUNTER.getByName(`idtoken-nonce:${expected}`).bump(1, SINGLE_USE_SECONDS);
  return !firstUse;
}
