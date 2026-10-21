// Passkeys are the only sign-in that a look-alike site relaying traffic (an
// "adversary in the middle") cannot reuse: the device signs for the real
// site's domain only. Passwords, e-mailed codes and Apple/Google tokens can be
// relayed, so an account that has a passkey no longer signs in with them, and the actions
// that would let a thief keep or widen access ask for the passkey again.
//
// Passkeys are listed per account here (the credential records themselves are
// keyed by credential id), under the account's canonical identity and under
// its e-mail identity, so a later linking of sign-in methods cannot hide them.
//
// A passkey counts as protection from the moment it is registered: from then
// on the account signs in with it only (see gatePasskeyAccount). The app asks
// every account for one at its first sign-in and has no way to remove it; the
// way back after losing it is the e-mailed recovery below.
import { sha256Hex } from "./auth.ts";
import { json } from "./http.ts";
import { featureDisabled } from "./features.ts";
import { revokeAllConnections } from "./mcp-oauth.ts";
import { revokeSessionsIssuedBefore } from "./session.ts";
import type { Env } from "./env.ts";
import { nextCursor } from "./kv.ts";
import type { PasskeyRecord, SessionRecord } from "./records.ts";

const MAX_PER_ACCOUNT = 10;
export const RECOVERY_DELAY_SECONDS = 48 * 60 * 60;
// A recovery request that is not used within this time lapses, so the person
// has to start (and be notified about) a new one.
const RECOVERY_WINDOW_SECONDS = 7 * 24 * 60 * 60;
export const REAUTH_VALIDITY_SECONDS = 2 * 60;
// 0: a passkey protects the account as soon as it is registered.
export const ESTABLISH_AFTER_SECONDS = 0;
export const REAUTH_ACTIONS = ["delete-account", "approve-app", "add-passkey", "remove-passkeys"];

const RESEND_API_URL = "https://api.resend.com/emails";

const indexKey = async (accountKey: string) => `passkey-account:${await sha256Hex(accountKey)}`;
const recoveryKey = async (accountKey: string) => `passkey-recovery:${await sha256Hex(accountKey)}`;

export async function resolveAccountKey(env: Env, key: string) {
  return (await env.STUDIQUO_DATA.get(`identity-canonical:${key}`)) || key;
}

// Every key the same person's passkeys could be listed under.
export async function passkeyAccountKeys(env: Env, accountKey: string, email: string | null | undefined) {
  const keys = new Set([await resolveAccountKey(env, accountKey)]);
  if (email) keys.add(`email:${email.trim().toLowerCase()}`);
  return [...keys];
}

// Passkeys registered before the per-account list existed are only found by
// their own records. The first request after that change lists them once and
// files each under its e-mail identity; later requests only read a flag. A run
// that cannot finish (too many to read in one request) leaves the flag unset
// and carries on from where it got to next time.
const BACKFILL_DONE = "passkey-index-backfilled";
const BACKFILL_CURSOR = "passkey-index-backfill-cursor";
const BACKFILL_MAX_RECORDS_PER_RUN = 300;

async function ensurePasskeyIndex(env: Env) {
  if (typeof env.STUDIQUO_DATA.list !== "function") return;
  if (await env.STUDIQUO_DATA.get(BACKFILL_DONE)) return;
  let cursor = (await env.STUDIQUO_DATA.get(BACKFILL_CURSOR)) || undefined;
  let handled = 0;
  for (;;) {
    const page = await env.STUDIQUO_DATA.list({ prefix: "passkeys:credential:", cursor, limit: 100 });
    for (const { name } of page.keys) {
      const record = await env.STUDIQUO_DATA.get<PasskeyRecord>(name, "json");
      if (record?.id && typeof record.email === "string" && record.email) {
        await indexAccountPasskey(env, `email:${record.email.trim().toLowerCase()}`, record.email, record.id);
      }
      handled += 1;
    }
    if (!nextCursor(page)) {
      await env.STUDIQUO_DATA.put(BACKFILL_DONE, "1");
      await env.STUDIQUO_DATA.delete(BACKFILL_CURSOR);
      return;
    }
    cursor = nextCursor(page);
    await env.STUDIQUO_DATA.put(BACKFILL_CURSOR, cursor!);
    if (handled >= BACKFILL_MAX_RECORDS_PER_RUN) return;
  }
}

/** The passkeys of this account that still exist (a deleted one may linger in a list). */
export async function loadAccountPasskeys(env: Env, accountKey: string, email: string | null) {
  await ensurePasskeyIndex(env);
  const ids = new Set<string>();
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    for (const id of (await env.STUDIQUO_DATA.get<string[]>(await indexKey(key), "json")) ?? []) ids.add(id);
  }
  const keys = await passkeyAccountKeys(env, accountKey, email);
  const records: PasskeyRecord[] = [];
  for (const id of ids) {
    const record = await env.STUDIQUO_DATA.get<PasskeyRecord>(`passkeys:credential:${id}`, "json");
    if (record && !(await passkeyRevokedByReset(env, record, keys))) records.push(record);
  }
  return records;
}

// A password reset writes "nothing registered before now counts" for the account
// (setPasskeyValidFrom). The reset also deletes the passkeys it can list, but a
// key-value listing can lag by up to a minute, so a passkey registered just as
// the reset ran could be missed and, unlike a session, would never expire. This
// time is read straight from a key, not found by listing, so it still catches
// that one, as long as the key itself has reached the place reading it (a
// key-value read can also be about a minute behind). A record without a registration time predates the field, and so
// predates any reset that wrote this.
const validFromKey = async (accountKey: string) => `passkey-valid-from:${await sha256Hex(accountKey)}`;

export async function setPasskeyValidFrom(env: Env, keys: Iterable<string>, now = Date.now()) {
  for (const key of keys) await env.STUDIQUO_DATA.put(await validFromKey(key), String(now));
}

export async function passkeyRevokedByReset(env: Env, record: Partial<PasskeyRecord> | null | undefined, keys: string[] | null = null) {
  let checked = keys;
  if (!checked) {
    const email = String(record?.email ?? "").trim().toLowerCase();
    checked = await passkeyAccountKeys(env, `email:${email}`, record?.email);
    // The account that owns this address, even when the sign-in methods were
    // never linked (so the canonical mapping above does not reach it): a reset
    // writes its time under that account's key.
    const owner = email ? await env.STUDIQUO_DATA.get(`email-account-owner:${email}`) : null;
    if (owner) checked = [...new Set([...checked, ...await passkeyAccountKeys(env, owner, null)])];
  }
  for (const key of checked) {
    const validFrom = Number(await env.STUDIQUO_DATA.get(await validFromKey(key)));
    if (Number.isFinite(validFrom) && validFrom > 0 && !(Number(record?.createdAt) >= validFrom)) return true;
  }
  return false;
}

/** True once every passkey record made before the per-account list existed has been filed in it. */
export async function passkeyIndexComplete(env: Env) {
  await ensurePasskeyIndex(env);
  return Boolean(await env.STUDIQUO_DATA.get(BACKFILL_DONE));
}

/**
 * The ids filed under these account keys, without opening the records. `full`
 * is true when a list is at its size limit: the oldest ids drop off a full list,
 * so it can no longer be taken as everything the account has.
 */
export async function indexedPasskeyIds(env: Env, keys: Iterable<string>) {
  const ids = new Set<string>();
  let full = false;
  for (const key of keys) {
    const list = (await env.STUDIQUO_DATA.get<string[]>(await indexKey(key), "json")) ?? [];
    if (list.length >= MAX_PER_ACCOUNT) full = true;
    for (const id of list) ids.add(id);
  }
  return { ids: [...ids], full };
}

export async function dropPasskeyIndex(env: Env, keys: Iterable<string>) {
  for (const key of keys) await env.STUDIQUO_DATA.delete(await indexKey(key));
}

export function isEstablishedPasskey(record: Pick<PasskeyRecord, "createdAt">, now = Date.now()) {
  // Records from before registration times were kept count as established.
  return !Number.isFinite(record.createdAt) || now >= (record.createdAt as number) + ESTABLISH_AFTER_SECONDS * 1000;
}

export async function listAccountPasskeys(env: Env, accountKey: string, email: string | null) {
  return (await loadAccountPasskeys(env, accountKey, email)).map(record => record.id);
}

export async function listEstablishedPasskeys(env: Env, accountKey: string, email: string | null, now = Date.now()) {
  return (await loadAccountPasskeys(env, accountKey, email)).filter(record => isEstablishedPasskey(record, now)).map(record => record.id);
}

export async function accountHasPasskey(env: Env, accountKey: string, email: string | null) {
  return (await listAccountPasskeys(env, accountKey, email)).length > 0;
}

export async function accountHasEstablishedPasskey(env: Env, accountKey: string, email: string | null, now = Date.now()) {
  return (await listEstablishedPasskeys(env, accountKey, email, now)).length > 0;
}

export async function indexAccountPasskey(env: Env, accountKey: string, email: string | null, credentialID: string) {
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    const k = await indexKey(key);
    const ids = (await env.STUDIQUO_DATA.get<string[]>(k, "json")) ?? [];
    if (!ids.includes(credentialID)) await env.STUDIQUO_DATA.put(k, JSON.stringify([...ids, credentialID].slice(-MAX_PER_ACCOUNT)));
  }
}

/** Removes every passkey of the account (records, lists and any recovery in progress). */
export async function removeAllPasskeys(env: Env, accountKey: string, email: string | null) {
  // Every id on the account's lists, including passkeys a password reset has
  // already cut off (listAccountPasskeys leaves those out): the lists are
  // dropped below, so anything not removed here could no longer be found.
  const ids = new Set<string>();
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    for (const id of (await env.STUDIQUO_DATA.get<string[]>(await indexKey(key), "json")) ?? []) ids.add(id);
  }
  // The per-person list (passkeys:user:) names these passkeys too, with the
  // e-mail address. Once the records and this account's list are gone nothing
  // leads back to it, so an account deletion would leave it behind: take the
  // entries out here, while the records still say which list they are in.
  const userKeys = new Set<string>();
  for (const id of ids) {
    const record = await env.STUDIQUO_DATA.get<PasskeyRecord>(`passkeys:credential:${id}`, "json");
    if (record?.userKey) userKeys.add(record.userKey);
  }
  const gone = ids;
  for (const userKey of userKeys) {
    const list = (await env.STUDIQUO_DATA.get<PasskeyRecord[]>(`passkeys:user:${userKey}`, "json")) ?? [];
    const kept = list.filter(item => !gone.has(item?.id));
    if (kept.length === list.length) continue;
    if (kept.length === 0) await env.STUDIQUO_DATA.delete(`passkeys:user:${userKey}`);
    else await env.STUDIQUO_DATA.put(`passkeys:user:${userKey}`, JSON.stringify(kept));
  }
  await Promise.all([...ids].map(id => env.STUDIQUO_DATA.delete(`passkeys:credential:${id}`)));
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    await env.STUDIQUO_DATA.delete(await indexKey(key));
    await env.STUDIQUO_DATA.delete(await recoveryKey(key));
  }
}

/** A successful sign-in with an established passkey ends any recovery someone else started. Returns whether there was one. */
export async function cancelPasskeyRecovery(env: Env, accountKey: string, email: string | null) {
  let hadRecovery = false;
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    const k = await recoveryKey(key);
    if (await env.STUDIQUO_DATA.get(k)) hadRecovery = true;
    await env.STUDIQUO_DATA.delete(k);
  }
  return hadRecovery;
}

export async function sendPasskeyNotice(env: Env, email: string | null, subject: string, lines: unknown[]) {
  if (!env.RESEND_API_KEY || !email) return;
  // The "email" kill switch (features.ts).
  if (featureDisabled(env, "email")) return;
  try {
    const response = await fetch(RESEND_API_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({
        from: env.RESEND_FROM_EMAIL ?? "Studiquo <onboarding@resend.dev>",
        to: email,
        subject,
        text: lines.join("\n"),
      }),
    });
    if (!response.ok) console.warn(JSON.stringify({ message: "passkey notice not sent", status: response.status }));
  } catch {
    console.warn(JSON.stringify({ message: "passkey notice not sent" }));
  }
}

/**
 * Called by the sign-in routes that a relayed password, code or provider token
 * could pass (e-mail code, password, Apple, Google), after the credential checked out and before
 * anything changes. Returns null when the account has no established passkey
 * (or its recovery wait is over), otherwise the response to send instead.
 *
 * Someone who lost the passkey can still get back in: the first attempt only
 * starts a recovery and tells the owner by e-mail, and once
 * RECOVERY_DELAY_SECONDS have passed the same sign-in is let through. That is
 * the weak point of any recovery by e-mail, so it is made loud: every session
 * and connected app that exists is signed out, the old passkeys are removed
 * (they are lost or no longer trusted), the owner is told again, and the app
 * asks for a new passkey. Signing in with a passkey in the meantime cancels it.
 *
 * `notify` runs the mail in the background (waitUntil) when given.
 */
export async function gatePasskeyAccount(env: Env, accountKey: string, email: string | null, { now = Date.now(), notify = (work: Promise<unknown>): unknown => work } = {}) {
  if (!(await accountHasEstablishedPasskey(env, accountKey, email, now))) return null;
  const key = await recoveryKey(await resolveAccountKey(env, accountKey));
  const pending = await env.STUDIQUO_DATA.get<{ requestedAt?: number }>(key, "json");
  const requestedAt = Number(pending?.requestedAt);
  if (Number.isFinite(requestedAt) && now >= requestedAt + RECOVERY_DELAY_SECONDS * 1000) {
    const keys = await passkeyAccountKeys(env, accountKey, email);
    await removeAllPasskeys(env, accountKey, email);
    // Whoever held a session before this moment loses it (this sign-in's own
    // session is minted after the cut-off and is kept).
    try {
      for (const identity of keys) await revokeSessionsIssuedBefore(env, identity, now);
      await revokeAllConnections(env, keys);
    } catch {
      console.warn("passkey recovery: could not sign out every session");
    }
    notify(sendPasskeyNotice(env, email, "Studiquoのパスキーを使わずにログインされました", [
      "お使いのStudiquoアカウントに、パスキーを使わない復旧手続きでログインがありました。",
      "",
      "セキュリティのため、それまでのパスキーはすべて削除し、すべての端末のログイン状態を解除しました。",
      "ご本人の場合は、Studiquoを開いて、新しいパスキーを設定してください。",
      "心当たりがない場合は、すぐにメールアカウントのパスワードを変更し、Studiquoを開いて、新しいパスキーを設定してください。",
    ]));
    return null;
  }
  let availableAt = requestedAt + RECOVERY_DELAY_SECONDS * 1000;
  if (!Number.isFinite(requestedAt)) {
    availableAt = now + RECOVERY_DELAY_SECONDS * 1000;
    await env.STUDIQUO_DATA.put(key, JSON.stringify({ requestedAt: now }), { expirationTtl: RECOVERY_WINDOW_SECONDS });
    notify(sendPasskeyNotice(env, email, "Studiquoのパスキーを使わないログインがありました", [
      "お使いのStudiquoアカウントには、パスキーが設定されています。パスキーを使わずにログインしようとした操作がありました。",
      "",
      `何もしないと、${Math.round(RECOVERY_DELAY_SECONDS / 3600)}時間後に、パスワード、メールのコード、Apple、Googleだけでログインできるようになります。`,
      "",
      "パスキーが使える場合は、Studiquoでパスキーでログインしてください。この手続きは取り消されます。",
      "心当たりがない場合も、すぐにパスキーでログインして取り消してください。メールを第三者に見られている可能性があるときは、メールアカウントのパスワードも変更してください。",
    ]));
  }
  return json({
    error: "このアカウントはパスキーでログインする設定です。パスキーでログインしてください。",
    code: "passkey_required",
    recoveryAvailableAt: availableAt,
  }, 403);
}

/**
 * Marks this session as having just proved itself with a passkey, for one
 * action (or "*" for any, right after signing in with one). The mark is used
 * up by the action it was given for, so a stolen copy of the session cannot
 * ride along on the owner's check for something else.
 */
export async function markRecentPasskey(env: Env, tokenHash: string, action = "*") {
  await env.STUDIQUO_DATA.put(`passkey-reauth:${tokenHash}`, action, { expirationTtl: REAUTH_VALIDITY_SECONDS });
}

/**
 * For actions that would let a thief keep or widen access (adding a passkey,
 * approving an app, deleting the account): an account with an established
 * passkey must have used it a moment ago in this session, for this action.
 * Returns null to proceed.
 */
export async function requireRecentPasskey(env: Env, token: string, session: Pick<SessionRecord, "sub">, action: string) {
  if (!(await accountHasEstablishedPasskey(env, session.sub, null))) return null;
  const key = `passkey-reauth:${await sha256Hex(token)}`;
  const marked = await env.STUDIQUO_DATA.get(key);
  if (marked && (marked === "*" || marked === action)) {
    await env.STUDIQUO_DATA.delete(key);
    return null;
  }
  return json({ error: "パスキーでの確認が必要です。", code: "reauth_required", action }, 403);
}
