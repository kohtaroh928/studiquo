// Shared "mint and record a bearer token" step every real sign-in (Apple,
// Google, local password, passkey) goes through. Recording the mint here is
// what lets requireRealSession() below refuse a token a client invented on
// its own in the same "<issued-at epoch>.<random>" shape, rather than
// trusting the token's own embedded timestamp as proof it's genuine.
import { sha256Hex } from "./auth.js";
import { VALIDITY_SECONDS } from "./token.js";

const SESSION_PREFIX = "session:";
const IDENTITY_CANONICAL_PREFIX = "identity-canonical:";

/**
 * The person is back after deleting their account, so the provider-side
 * "deleted customer" records written at deletion (they make RevenueCat events
 * for those customer ids be ignored, so a late renewal can't recreate what was
 * erased) must go: left in place, a re-registered customer would stay on the
 * free plan however many times they subscribed. All of the old account's
 * identities are cleared, since the provider lists them as aliases of the one
 * customer. Returns false when that could not be done.
 */
async function clearDeletedCustomerRecords(env, hashes) {
  if (!env.ADMIN_DB || hashes.length === 0) return true;
  try {
    await env.ADMIN_DB.prepare("DELETE FROM privacy_deleted_customers WHERE customer_hash IN (SELECT value FROM json_each(?))")
      .bind(JSON.stringify(hashes)).run();
    return true;
  } catch {
    console.error(JSON.stringify({ message: "could not clear a returning customer's deletion record" }));
    return false;
  }
}

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
  const deletionStateKey = `account-deletion:${await sha256Hex(identityKey)}`;
  const deletionState = await env.STUDIQUO_DATA.get(deletionStateKey, "json");
  if (deletionState?.status === "deleting") return null;
  // The deletion finished and this identity has now signed in again, so it is
  // a new account. The "deleted" marker (which only exists so a stale retry
  // can't run twice) must not outlive that: left in place, a later deletion of
  // this new account would return early and erase nothing.
  //
  // Whatever that deletion still had queued belongs to the previous account
  // and goes with it. And the marker is replaced, not just removed, by one
  // recording when the new account began: a retry that had already read the
  // old job before this moment still runs deleteAccount afterwards, and that
  // timestamp is how deleteAccount knows to leave the new account alone.
  if (deletionState?.status === "deleted") {
    const hashes = await Promise.all([...new Set([identityKey, ...(deletionState.identityKeys ?? [])])].map(sha256Hex));
    const cleared = await clearDeletedCustomerRecords(env, hashes);
    await env.STUDIQUO_DATA.delete(`privacy-account-delete:${await sha256Hex(identityKey)}`);
    // The new account starts now whether or not the provider records could be
    // cleared: a state that stayed "deleted" would make the person's next
    // deletion of this account return early and erase nothing. What could not
    // be cleared is remembered and retried at the next sign-in.
    await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({
      status: "active", reregisteredAt: Date.now(), ...(cleared ? {} : { pendingCustomerClear: hashes }),
    }));
  } else if (deletionState?.status === "active" && Array.isArray(deletionState.pendingCustomerClear)) {
    if (await clearDeletedCustomerRecords(env, deletionState.pendingCustomerClear)) {
      await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "active", reregisteredAt: deletionState.reregisteredAt }));
    }
  }
  // A queued provider (RevenueCat) DELETE for THIS identity is dropped for the
  // same reason: the customer id is the same again, so running it later would
  // erase the newly re-registered customer's records, and refusing to sign in
  // until it runs locks the person out for as long as it cannot run (no secret
  // configured, provider outage). Other aliases of the old account stay
  // queued: they were not signed in to, so they are not that customer again,
  // and a queued job no longer blocks any sign-in.
  const providerJobKey = `privacy-rc-delete:${await sha256Hex(identityKey)}`;
  // Read first: an ordinary sign-in has no job, and must not pay for a write.
  if (await env.STUDIQUO_DATA.get(providerJobKey)) await env.STUDIQUO_DATA.delete(providerJobKey);
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
  return (await realSession(env, token)) !== null;
}

export async function realSession(env, token) {
  const key = await sha256Hex(token);
  const session = await env.STUDIQUO_DATA.get(`${SESSION_PREFIX}${key}`, "json");
  if (typeof session?.sub !== "string" || session.sub.length === 0) return null;
  // Linking providers must also affect already-issued sessions. Otherwise a
  // user switching sign-in method would remain split until every old token
  // expired. Keep the original subject for diagnostics, but expose the
  // canonical account to every authenticated feature immediately.
  const canonical = await env.STUDIQUO_DATA.get(`${IDENTITY_CANONICAL_PREFIX}${session.sub}`);
  const resolved = canonical && canonical !== session.sub
    ? { ...session, originalSub: session.sub, sub: canonical }
    : session;
  const deletionState = await env.STUDIQUO_DATA.get(`account-deletion:${await sha256Hex(resolved.sub)}`, "json");
  return deletionState?.status === "deleting" ? null : resolved;
}
