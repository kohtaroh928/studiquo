// Passkeys are the only sign-in that a look-alike site relaying traffic (an
// "adversary in the middle") cannot reuse: the device signs for the real
// site's domain only. Passwords and e-mailed codes can be relayed, so an
// account that has a passkey no longer signs in with them, and the actions
// that would let a thief keep or widen access ask for the passkey again.
//
// Passkeys are listed per account here (the credential records themselves are
// keyed by credential id), under the account's canonical identity and under
// its e-mail identity, so a later linking of sign-in methods cannot hide them.
//
// A passkey only counts as protection once it is ESTABLISHED, 24 hours after it
// was registered. Otherwise whoever holds a stolen session could register their
// own passkey, lock the owner out of the password and code sign-ins, and call
// off every recovery with it. In those first hours the owner can still sign in
// as before, is told by e-mail, and can remove the passkeys (removeAllPasskeys).
import { sha256Hex } from "./auth.js";
import { json } from "./http.js";
import { revokeAllConnections } from "./mcp-oauth.js";
import { revokeSessionsIssuedBefore } from "./session.js";

const MAX_PER_ACCOUNT = 10;
export const RECOVERY_DELAY_SECONDS = 48 * 60 * 60;
// A recovery request that is not used within this time lapses, so the person
// has to start (and be notified about) a new one.
const RECOVERY_WINDOW_SECONDS = 7 * 24 * 60 * 60;
export const REAUTH_VALIDITY_SECONDS = 2 * 60;
export const ESTABLISH_AFTER_SECONDS = 24 * 60 * 60;
export const REAUTH_ACTIONS = ["delete-account", "approve-app", "add-passkey", "remove-passkeys"];

const RESEND_API_URL = "https://api.resend.com/emails";

const indexKey = async accountKey => `passkey-account:${await sha256Hex(accountKey)}`;
const recoveryKey = async accountKey => `passkey-recovery:${await sha256Hex(accountKey)}`;

export async function resolveAccountKey(env, key) {
  return (await env.STUDIQUO_DATA.get(`identity-canonical:${key}`)) || key;
}

// Every key the same person's passkeys could be listed under.
export async function passkeyAccountKeys(env, accountKey, email) {
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

async function ensurePasskeyIndex(env) {
  if (typeof env.STUDIQUO_DATA.list !== "function") return;
  if (await env.STUDIQUO_DATA.get(BACKFILL_DONE)) return;
  let cursor = (await env.STUDIQUO_DATA.get(BACKFILL_CURSOR)) || undefined;
  let handled = 0;
  for (;;) {
    const page = await env.STUDIQUO_DATA.list({ prefix: "passkeys:credential:", cursor, limit: 100 });
    for (const { name } of page.keys) {
      const record = await env.STUDIQUO_DATA.get(name, "json");
      if (record?.id && typeof record.email === "string" && record.email) {
        await indexAccountPasskey(env, `email:${record.email.trim().toLowerCase()}`, record.email, record.id);
      }
      handled += 1;
    }
    if (page.list_complete || !page.cursor) {
      await env.STUDIQUO_DATA.put(BACKFILL_DONE, "1");
      await env.STUDIQUO_DATA.delete(BACKFILL_CURSOR);
      return;
    }
    cursor = page.cursor;
    await env.STUDIQUO_DATA.put(BACKFILL_CURSOR, cursor);
    if (handled >= BACKFILL_MAX_RECORDS_PER_RUN) return;
  }
}

/** The passkeys of this account that still exist (a deleted one may linger in a list). */
export async function loadAccountPasskeys(env, accountKey, email) {
  await ensurePasskeyIndex(env);
  const ids = new Set();
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    for (const id of (await env.STUDIQUO_DATA.get(await indexKey(key), "json")) ?? []) ids.add(id);
  }
  const records = [];
  for (const id of ids) {
    const record = await env.STUDIQUO_DATA.get(`passkeys:credential:${id}`, "json");
    if (record) records.push(record);
  }
  return records;
}

export function isEstablishedPasskey(record, now = Date.now()) {
  // Records from before registration times were kept have been in use for long enough.
  return !Number.isFinite(record.createdAt) || now >= record.createdAt + ESTABLISH_AFTER_SECONDS * 1000;
}

export async function listAccountPasskeys(env, accountKey, email) {
  return (await loadAccountPasskeys(env, accountKey, email)).map(record => record.id);
}

export async function listEstablishedPasskeys(env, accountKey, email, now = Date.now()) {
  return (await loadAccountPasskeys(env, accountKey, email)).filter(record => isEstablishedPasskey(record, now)).map(record => record.id);
}

export async function accountHasPasskey(env, accountKey, email) {
  return (await listAccountPasskeys(env, accountKey, email)).length > 0;
}

export async function accountHasEstablishedPasskey(env, accountKey, email, now = Date.now()) {
  return (await listEstablishedPasskeys(env, accountKey, email, now)).length > 0;
}

export async function indexAccountPasskey(env, accountKey, email, credentialID) {
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    const k = await indexKey(key);
    const ids = (await env.STUDIQUO_DATA.get(k, "json")) ?? [];
    if (!ids.includes(credentialID)) await env.STUDIQUO_DATA.put(k, JSON.stringify([...ids, credentialID].slice(-MAX_PER_ACCOUNT)));
  }
}

/** Removes every passkey of the account (records, lists and any recovery in progress). */
export async function removeAllPasskeys(env, accountKey, email) {
  const ids = await listAccountPasskeys(env, accountKey, email);
  await Promise.all(ids.map(id => env.STUDIQUO_DATA.delete(`passkeys:credential:${id}`)));
  for (const key of await passkeyAccountKeys(env, accountKey, email)) {
    await env.STUDIQUO_DATA.delete(await indexKey(key));
    await env.STUDIQUO_DATA.delete(await recoveryKey(key));
  }
}

/** A successful sign-in with an established passkey ends any recovery someone else started. */
export async function cancelPasskeyRecovery(env, accountKey, email) {
  for (const key of await passkeyAccountKeys(env, accountKey, email)) await env.STUDIQUO_DATA.delete(await recoveryKey(key));
}

export async function sendPasskeyNotice(env, email, subject, lines) {
  if (!env.RESEND_API_KEY || !email) return;
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
 * Called by the sign-in routes that a relayed password or code could pass
 * (e-mail code, password), after the credential checked out and before
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
export async function gatePasskeyAccount(env, accountKey, email, { now = Date.now(), notify = work => work } = {}) {
  if (!(await accountHasEstablishedPasskey(env, accountKey, email, now))) return null;
  const key = await recoveryKey(await resolveAccountKey(env, accountKey));
  const pending = await env.STUDIQUO_DATA.get(key, "json");
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
      "心当たりがない場合は、すぐにメールアカウントのパスワードを変更し、Studiquoにログインして、パスワードを再設定してください。",
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
      `何もしないと、${Math.round(RECOVERY_DELAY_SECONDS / 3600)}時間後に、パスワードやメールのコードだけでログインできるようになります。`,
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
export async function markRecentPasskey(env, tokenHash, action = "*") {
  await env.STUDIQUO_DATA.put(`passkey-reauth:${tokenHash}`, action, { expirationTtl: REAUTH_VALIDITY_SECONDS });
}

/**
 * For actions that would let a thief keep or widen access (adding a passkey,
 * approving an app, deleting the account): an account with an established
 * passkey must have used it a moment ago in this session, for this action.
 * Returns null to proceed.
 */
export async function requireRecentPasskey(env, token, session, action) {
  if (!(await accountHasEstablishedPasskey(env, session.sub, null))) return null;
  const key = `passkey-reauth:${await sha256Hex(token)}`;
  const marked = await env.STUDIQUO_DATA.get(key);
  if (marked && (marked === "*" || marked === action)) {
    await env.STUDIQUO_DATA.delete(key);
    return null;
  }
  return json({ error: "パスキーでの確認が必要です。", code: "reauth_required", action }, 403);
}
