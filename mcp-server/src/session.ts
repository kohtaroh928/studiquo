// Shared "mint and record a bearer token" step every real sign-in (Apple,
// Google, local password, passkey) goes through. Recording the mint here is
// what lets requireRealSession() below refuse a token a client invented on
// its own in the same "<issued-at epoch>.<random>" shape, rather than
// trusting the token's own embedded timestamp as proof it's genuine.
import { sha256Hex } from "./auth.ts";
import { VALIDITY_SECONDS } from "./token.ts";
import { sessionTokenAcceptable, signSessionToken } from "./token-signature.ts";
import type { Env } from "./env.ts";
import type { DeletionState, SessionRecord } from "./records.ts";

// Which life of the account a record belongs to. Each time a deleted account
// is signed into again (mintSession) the count goes up by one, and jobs and
// states carry the count they were written under. Comparing counts tells an
// earlier life's leftovers from the current one without trusting clocks that
// differ between the isolates serving a request and the one running a retry.
export function generationOf(state: { generation?: number } | null | undefined): number {
  return Number.isFinite(state?.generation) ? state.generation : 0;
}

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
async function clearDeletedCustomerRecords(env: Env, hashes) {
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

// 32 random bytes as 64 hex characters. The secret half of a token is made HERE,
// by the Worker, from its own random source. It used to be a value the app sent
// and the Worker stored as it came, so a token was only as unguessable as the
// app's own randomness.
function newSecretHalf() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

/**
 * Mints a "<issued-at epoch>.<random>[.<signature>]" token for `identityKey`,
 * records it as a real, server-issued session (so requireRealSession can
 * recognize it later), and returns the token — or `null` if the account's
 * deletion is in progress and nobody may sign in to it yet.
 *
 * The third argument is accepted for compatibility with apps that still send a
 * `randomValue` and is ignored: the secret half of the token always comes from the
 * Worker (256 random bits, so two logins never share one in practice).
 */
export async function mintSession(env: Env, identityKey, _suppliedByTheApp?: unknown, { originIssuedAtMs }: { originIssuedAtMs?: number } = {}) {
  const issuedAt = Math.floor(Date.now() / 1000);
  // Signed when a signing key is configured (token-signature.ts), so that an
  // invented token can be refused later without a KV read.
  const token = await signSessionToken(env, `${issuedAt}.${newSecretHalf()}`);
  const deletionStateKey = `account-deletion:${await sha256Hex(identityKey)}`;
  const deletionState = await env.STUDIQUO_DATA.get<DeletionState>(deletionStateKey, "json");
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
    // The marker keeps hashes of the account's identities (older ones kept the
    // identities themselves; both are read).
    const hashes = [...new Set([
      await sha256Hex(identityKey),
      ...(deletionState.identityHashes ?? []),
      ...await Promise.all((deletionState.identityKeys ?? []).map(sha256Hex)),
    ])];
    const cleared = await clearDeletedCustomerRecords(env, hashes);
    await env.STUDIQUO_DATA.delete(`privacy-account-delete:${await sha256Hex(identityKey)}`);
    // The provider treats every id of one customer as the same customer, so a
    // queued DELETE for ANY alias of the old account would erase the
    // re-registered one. They all go, not only the identity that signed in.
    await Promise.all(hashes.map(hash => env.STUDIQUO_DATA.delete(`privacy-rc-delete:${hash}`)));
    // The new account starts now whether or not the provider records could be
    // cleared: a state that stayed "deleted" would make the person's next
    // deletion of this account return early and erase nothing. What could not
    // be cleared is remembered and retried at the next sign-in.
    await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({
      status: "active", reregisteredAt: Date.now(), generation: generationOf(deletionState) + 1,
      ...(cleared ? {} : { pendingCustomerClear: hashes }),
    }));
  } else if (deletionState?.status === "active" && Array.isArray(deletionState.pendingCustomerClear)) {
    if (await clearDeletedCustomerRecords(env, deletionState.pendingCustomerClear)) {
      await env.STUDIQUO_DATA.put(deletionStateKey, JSON.stringify({ status: "active", reregisteredAt: deletionState.reregisteredAt, generation: generationOf(deletionState) }));
    }
  }
  // A queued provider (RevenueCat) DELETE for THIS identity is dropped for the
  // same reason: the customer id is the same again, so running it later would
  // erase the newly re-registered customer's records, and refusing to sign in
  // until it runs locks the person out for as long as it cannot run (no secret
  // configured, provider outage). The other aliases of an account that has
  // just come back are dropped above; this read covers a job left for the
  // identity that signed in when no "deleted" marker applies.
  const providerJobKey = `privacy-rc-delete:${await sha256Hex(identityKey)}`;
  // Read first: an ordinary sign-in has no job, and must not pay for a write.
  if (await env.STUDIQUO_DATA.get(providerJobKey)) await env.STUDIQUO_DATA.delete(providerJobKey);
  const key = await sha256Hex(token);
  await env.STUDIQUO_DATA.put(`${SESSION_PREFIX}${key}`, JSON.stringify({
    sub: identityKey, issuedAt, issuedAtMs: Date.now(),
    // When the login this token descends from began (see handleSessionRefresh).
    originIssuedAtMs: Number.isFinite(originIssuedAtMs) ? originIssuedAtMs : Date.now(),
  }), {
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
export async function hasRealSession(env: Env, token, options?: { allowSuspended?: boolean }) {
  return (await realSession(env, token, options)) !== null;
}

// An operator suspends an account (moderation-actions.ts) by writing this key;
// it is named by the same hash the chat identity uses, so a reported chat user
// can be traced to it (see chat.ts, which records chat key -> this hash).
export const SUSPENSION_PREFIX = "account-suspended:";
export async function suspensionKey(canonicalSub) {
  return `${SUSPENSION_PREFIX}${await sha256Hex(`chat-account:${canonicalSub}`)}`;
}

// Looked up under the canonical account and, for a session issued before two
// sign-in methods were linked, under the identity it was issued to as well: an
// operator's mark made against either one must hold.
async function isSuspended(env: Env, session: SessionRecord) {
  return hasModerationMark(env, session, SUSPENSION_PREFIX);
}

// An operator's mark of the given kind on this person (account-suspended: or
// chat-suspended:), under the canonical account and the identity the session
// was issued to.
export async function hasModerationMark(env: Env, session, prefix) {
  const subs = session.originalSub && session.originalSub !== session.sub ? [session.sub, session.originalSub] : [session.sub];
  const marks = await Promise.all(subs.map(async item =>
    env.STUDIQUO_DATA.get(`${prefix}${await sha256Hex(`chat-account:${item}`)}`)));
  return marks.some(Boolean);
}

export const CHAT_SUSPENSION_PREFIX = "chat-suspended:";

/**
 * `allowSuspended` is for the few things a suspended person must still be able
 * to do — leaving (deleting the account, and the passkey check that deletion
 * asks for). Everything else treats a suspended account like a signed-out one.
 */
export async function realSession(env: Env, token, { allowSuspended = false } = {}) {
  // First, before anything is read: a token whose signature is wrong (or missing
  // while signatures are required) cannot be a real session.
  if (!(await sessionTokenAcceptable(env, token))) return null;
  const key = await sha256Hex(token);
  const session = await env.STUDIQUO_DATA.get<SessionRecord>(`${SESSION_PREFIX}${key}`, "json");
  if (typeof session?.sub !== "string" || session.sub.length === 0) return null;
  // Linking providers must also affect already-issued sessions. Otherwise a
  // user switching sign-in method would remain split until every old token
  // expired. Keep the original subject for diagnostics, but expose the
  // canonical account to every authenticated feature immediately.
  const canonical = await env.STUDIQUO_DATA.get(`${IDENTITY_CANONICAL_PREFIX}${session.sub}`);
  const resolved = canonical && canonical !== session.sub
    ? { ...session, originalSub: session.sub, sub: canonical }
    : session;
  // Independent reads, so the cut-off adds no waiting on top of the state.
  const [deletionState, cutoff, suspended] = await Promise.all([
    env.STUDIQUO_DATA.get<DeletionState>(`account-deletion:${await sha256Hex(resolved.sub)}`, "json"),
    sessionCutoff(env, resolved.sub),
    allowSuspended ? null : isSuspended(env, resolved),
  ]);
  if (suspended) return null;
  // "deleted" refuses too: a session minted just before the deletion read its
  // state can outlive the cleanup, and left usable it would let the person
  // keep working in a deleted account (and ask for a second deletion that,
  // finding the marker, erased nothing). Signing in again replaces the marker
  // (mintSession), so no legitimate session exists while it stands.
  if (deletionState?.status === "deleting" || deletionState?.status === "deleted") return null;
  // A password was set (reset) after this session was issued: it belongs to
  // whoever had the old password.
  if (sessionIsBeforeCutoff(resolved, cutoff)) return null;
  return resolved;
}

/**
 * Whether the account behind `sub` is partway through its deletion. Unlike
 * `accountIsUnavailable`, an already-deleted account is not counted: a person
 * who has left may register again.
 */
export async function accountIsBeingDeleted(env: Env, sub) {
  const canonical = await env.STUDIQUO_DATA.get(`${IDENTITY_CANONICAL_PREFIX}${sub}`);
  const subs = canonical && canonical !== sub ? [sub, canonical] : [sub];
  const states = await Promise.all(subs.map(async item => env.STUDIQUO_DATA.get<DeletionState>(`account-deletion:${await sha256Hex(item)}`, "json")));
  return states.some(state => state?.status === "deleting");
}

/**
 * Whether the account behind `sub` is being deleted or has been deleted, for
 * credentials that are not sessions (connected-app tokens). `sub` may be a
 * linked identity rather than the canonical account, so both are looked at.
 */
export async function accountIsUnavailable(env: Env, sub) {
  const canonical = await env.STUDIQUO_DATA.get(`${IDENTITY_CANONICAL_PREFIX}${sub}`);
  const subs = canonical && canonical !== sub ? [sub, canonical] : [sub];
  const states = await Promise.all(subs.map(async item => env.STUDIQUO_DATA.get<DeletionState>(`account-deletion:${await sha256Hex(item)}`, "json")));
  if (states.some(state => state?.status === "deleting" || state?.status === "deleted")) return true;
  // A suspended account's connected apps stop working too.
  const suspensions = await Promise.all(subs.map(async item => env.STUDIQUO_DATA.get(await suspensionKey(item))));
  return suspensions.some(Boolean);
}

const CUTOFF_PREFIX = "session-valid-from:";

async function sessionCutoff(env: Env, identityKey) {
  const value = Number(await env.STUDIQUO_DATA.get(`${CUTOFF_PREFIX}${await sha256Hex(identityKey)}`));
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * Whether a session was issued before the account's cut-off. Sessions record
 * their issue time to the millisecond, so one minted right after the cut-off —
 * the person who has just set the new password — is kept even within the same
 * second. An older record that only has whole seconds is judged as a whole
 * second, and one with no issue time at all can't be shown to be newer.
 */
export function sessionIsBeforeCutoff(session, cutoff) {
  if (!cutoff) return false;
  if (Number.isFinite(session.issuedAtMs)) return session.issuedAtMs < cutoff;
  if (Number.isFinite(session.issuedAt)) return (session.issuedAt + 1) * 1000 <= cutoff;
  return true;
}

/**
 * Signs out every session issued so far for this account (call when its
 * password is set or reset, before minting the new session). The cut-off is a
 * key of its own — not a field on the deletion-state record, which other
 * writers replace as a whole — and expires once no session old enough to be
 * affected can still exist. KV may serve the old value for up to about a
 * minute, so a revoked session can live that long. An account that is being
 * deleted, or is already deleted, has no live sessions to protect.
 */
export async function revokeSessionsIssuedBefore(env: Env, identityKey: string, now = Date.now()) {
  const state = await env.STUDIQUO_DATA.get<DeletionState>(`account-deletion:${await sha256Hex(identityKey)}`, "json");
  if (state?.status === "deleting" || state?.status === "deleted") return;
  await env.STUDIQUO_DATA.put(`${CUTOFF_PREFIX}${await sha256Hex(identityKey)}`, String(now), { expirationTtl: VALIDITY_SECONDS + 86_400 });
}
