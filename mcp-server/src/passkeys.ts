import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import { isRevoked } from "./revocation.ts";
import { isExpired } from "./token.ts";
import { checkRateLimit, clientKey } from "./rate-limit.ts";
import { bearerToken, sha256Hex } from "./auth.ts";
import { json, readJSONLimited } from "./http.ts";
import { confirmVerificationCode, sendVerificationCode } from "./email-verification.ts";
import { mintSession, hasRealSession, realSession } from "./session.ts";
import { linkVerifiedEmail } from "./oauth-links.ts";
import {
  REAUTH_ACTIONS, accountHasPasskey, cancelPasskeyRecovery, dropPasskeyIndex, indexAccountPasskey, indexedPasskeyIds, passkeyAccountKeys,
  passkeyIndexComplete, passkeyRevokedByReset, setPasskeyValidFrom, isEstablishedPasskey, listAccountPasskeys,
  listEstablishedPasskeys, markRecentPasskey, removeAllPasskeys, requireRecentPasskey, sendPasskeyNotice,
} from "./passkey-policy.ts";
import type { Env } from "./env.ts";
import { nextCursor } from "./kv.ts";
import type { PasskeyChallenge, PasskeyRecord } from "./records.ts";

const RP_ID = "api.studiquo.app";
const ORIGIN = `https://${RP_ID}`;
const APP_ID = "972G4VGUA6.com.yabuko.studiquo";

export async function mintPasskeySession(env: Env, email: string) {
  const link = await linkVerifiedEmail(env, {
    provider: "email", sub: email, email, emailVerified: true,
  });
  return mintSession(env, link.canonicalIdentityKey ?? `email:${email}`);
}

async function body(request: Request) {
  return readJSONLimited(request, 100_000);
}

// The first passkey of an account is what locks every other way in, so a
// session alone (a stolen one, or one made through a relayed password or code)
// must not be enough to register it: the person also reads a code sent to the
// account's own address. The proof lasts three minutes and is used up by the
// registration it was given for.
const EMAIL_PROOF_SECONDS = 3 * 60;
const emailProofKey = (tokenHash: any) => `passkey-email-proof:${tokenHash}`;

function transactionID() {
  return crypto.randomUUID();
}

async function keysWithPrefix(env: Env, prefix: string) {
  const names: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.STUDIQUO_DATA.list({ prefix, cursor });
    for (const item of page.keys ?? []) names.push(item.name);
    cursor = nextCursor(page);
  } while (cursor);
  return names;
}

// Removes every passkey that signs in as this account, so none can sign in
// again. Used when a password is reset: a passkey counts as proof of its
// e-mail address (mintPasskeySession), so one registered by whoever held the
// old password would otherwise keep working after the owner took the account
// back. The owner can register new ones once signed in.
//
// A passkey belongs to the account when its address is one of `emails`, or when
// that address is recorded as owned by `accountKey`: an account can own several
// addresses (the registration check is `email-account-owner:<address>` equals
// the session's account), and the reset is for one of them.
//
// Throws when it cannot finish, leaving the caller to stop the reset rather
// than carry on with a passkey that still works. It reads only this account's
// passkeys (the per-account list), so the cost does not grow with the service.
export async function revokePasskeysForAccount(env: Env, { accountKey, emails = [] }: any) {
  const wanted: string[] = [...new Set<string>(emails.map((email: any) => String(email).trim().toLowerCase()).filter(Boolean))];
  // Nothing registered before this moment counts any more, whether or not the
  // sweeps below find it (see passkeyRevokedByReset).
  const keys = new Set();
  if (accountKey) for (const key of await passkeyAccountKeys(env, accountKey, null)) keys.add(key);
  for (const email of wanted) for (const key of await passkeyAccountKeys(env, accountKey || `email:${email}`, email)) keys.add(key);
  await setPasskeyValidFrom(env, [...keys]);

  // The account's own list finds them without reading every passkey there is.
  // Until the list covers passkeys from before it existed, the full scan is the
  // only way to be sure.
  const scanned = async () => {
    const result = await scanAndRevoke(env, { accountKey, wanted });
    await setPasskeyValidFrom(env, [...keys]);
    return result;
  };
  if (!(await passkeyIndexComplete(env))) return scanned();
  const { ids, full } = await indexedPasskeyIds(env, [...keys]);
  // A list at its limit has dropped its oldest ids (more than that many passkeys
  // were registered), so the passkeys it names are not all there are.
  if (full) return scanned();
  let removed = 0;
  const userKeys = new Set();
  for (const id of ids) {
    const record = await env.STUDIQUO_DATA.get<PasskeyRecord>(`passkeys:credential:${id}`, "json");
    if (!record) continue;
    if (record.userKey) userKeys.add(record.userKey);
    await env.STUDIQUO_DATA.delete(`passkeys:credential:${id}`);
    removed += 1;
  }
  const gone = new Set(ids);
  for (const userKey of userKeys) {
    const list = await env.STUDIQUO_DATA.get<PasskeyRecord[]>(`passkeys:user:${userKey}`, "json") ?? [];
    const kept = list.filter(item => !gone.has(item.id));
    if (kept.length === list.length) continue;
    if (kept.length === 0) await env.STUDIQUO_DATA.delete(`passkeys:user:${userKey}`);
    else await env.STUDIQUO_DATA.put(`passkeys:user:${userKey}`, JSON.stringify(kept));
  }
  await dropPasskeyIndex(env, [...keys]);
  // Again, so a passkey registered while the sweep ran (after the time written
  // at the start, but missed by the sweep) is older than this one.
  await setPasskeyValidFrom(env, [...keys]);
  return { removed };
}

// The original sweep, kept for the time before the per-account list is complete.
async function scanAndRevoke(env: Env, { accountKey, wanted }: any) {
  const emails = new Set(wanted);
  const owners = new Map();
  const belongs = async (item: any) => {
    const email = String(item?.email ?? "").trim().toLowerCase();
    if (!email) return false;
    if (emails.has(email)) return true;
    if (!accountKey) return false;
    if (!owners.has(email)) owners.set(email, await env.STUDIQUO_DATA.get(`email-account-owner:${email}`));
    return owners.get(email) === accountKey;
  };
  let removed = 0;
  for (const key of await keysWithPrefix(env, "passkeys:credential:")) {
    if (await belongs(await env.STUDIQUO_DATA.get<PasskeyRecord>(key, "json"))) {
      await env.STUDIQUO_DATA.delete(key);
      removed += 1;
    }
  }
  for (const key of await keysWithPrefix(env, "passkeys:user:")) {
    const list = await env.STUDIQUO_DATA.get<PasskeyRecord[]>(key, "json") ?? [];
    const kept = [];
    for (const item of list) if (!(await belongs(item))) kept.push(item);
    if (kept.length === list.length) continue;
    if (kept.length === 0) await env.STUDIQUO_DATA.delete(key);
    else await env.STUDIQUO_DATA.put(key, JSON.stringify(kept));
  }
  return { removed };
}

export function associationFile() {
  return json({
    webcredentials: { apps: [APP_ID] },
    // Lets a friend-invite link use a real https:// URL (see invite.ts)
    // instead of only the studiquo:// custom scheme — a share sent through
    // LINE, Snapchat, etc. opens in that app's own in-app browser, which
    // generally won't hand off a custom scheme to iOS at all, but does
    // respect a Universal Link for a path listed here.
    applinks: {
      details: [{ appIDs: [APP_ID], components: [{ "/": "/invite" }] }],
    },
  });
}

export async function handlePasskeys(url: URL, request: Request, env: Env) {
  if (!url.pathname.startsWith("/api/passkeys/")) return null;

  if (url.pathname === "/api/passkeys/email-code/send" && request.method === "POST") {
    const auth = await authenticatedSession(request, env);
    if (auth.response) return auth.response;
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_REGISTER_OPTIONS, auth.tokenHash);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const email = String((await body(request))?.email ?? "").trim().toLowerCase();
    if (email.length > 254 || !email.includes("@")) return json({ error: "Invalid request." }, 400);
    // Only the account's own address: this must not mail arbitrary people.
    if (await env.STUDIQUO_DATA.get(`email-account-owner:${email}`) !== auth.session.sub) {
      return json({ error: "This e-mail address does not belong to the signed-in account." }, 403);
    }
    // An account that has a passkey proves it with that, not with mail.
    if (await accountHasPasskey(env, auth.session.sub, email)) return json({ error: "A passkey is already registered." }, 409);
    // Per-address budget, whichever session asks (same shape as the sign-in codes in app.ts).
    if (env.RATE_COUNTER && !(await env.RATE_COUNTER.getByName(`email-code-passkey:${await sha256Hex(email)}`).bump(5, 3_600))) {
      return json({ error: "Too many attempts. Please try again later." }, 429);
    }
    try {
      await sendVerificationCode(env, email);
    } catch {
      return json({ error: "Could not send the verification email." }, 502);
    }
    return json({ sent: true });
  }

  if (url.pathname === "/api/passkeys/email-code/confirm" && request.method === "POST") {
    const auth = await authenticatedSession(request, env);
    if (auth.response) return auth.response;
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_REGISTER_VERIFY, auth.tokenHash);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const payload = await body(request);
    const email = String(payload?.email ?? "").trim().toLowerCase();
    const code = String(payload?.code ?? "");
    if (email.length > 254 || !email.includes("@") || !code) return json({ error: "Invalid request." }, 400);
    if (await env.STUDIQUO_DATA.get(`email-account-owner:${email}`) !== auth.session.sub) {
      return json({ error: "This e-mail address does not belong to the signed-in account." }, 403);
    }
    // Per-address budget for guesses, whichever session asks (as for the sign-in codes in app.ts).
    if (env.RATE_COUNTER && !(await env.RATE_COUNTER.getByName(`email-code-passkey-confirm:${await sha256Hex(email)}`).bump(10, 3_600))) {
      return json({ error: "Too many attempts. Please try again later." }, 429);
    }
    const result = await confirmVerificationCode(env, email, code);
    if (!result.verified) return json({ error: "Incorrect or expired code.", attemptsRemaining: result.attemptsRemaining }, 401);
    await env.STUDIQUO_DATA.put(emailProofKey(auth.tokenHash), email, { expirationTtl: EMAIL_PROOF_SECONDS });
    return json({ verified: true });
  }

  if (url.pathname === "/api/passkeys/register/options" && request.method === "POST") {
    const token = bearerToken(request);
    const payload = await body(request);
    const email = String(payload?.email ?? "").trim().toLowerCase();
    if (!token || email.length > 254 || !email.includes("@")) return json({ error: "Invalid request." }, 400);
    if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
    const session = await realSession(env, token);
    if (!session) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
    const userKey = await sha256Hex(token);
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_REGISTER_OPTIONS, userKey);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    if (await isRevoked(env, userKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
    // Signing in with this passkey later is treated as proof of THIS e-mail
    // (mintPasskeySession), so the address must already belong to the account
    // that is registering it. A session for any account used to be enough to
    // register a passkey for somebody else's address, and then to sign in as
    // them; an address nobody has signed in with yet could be claimed ahead of
    // its owner the same way.
    if (await env.STUDIQUO_DATA.get(`email-account-owner:${email}`) !== session.sub) {
      return json({ error: "This e-mail address does not belong to the signed-in account." }, 403);
    }
    // An account that already has a passkey only gets another after using one:
    // a stolen session could otherwise add the thief's own.
    const needsPasskey = await requireRecentPasskey(env, token, session, "add-passkey");
    if (needsPasskey) return needsPasskey;
    // The first passkey also needs a fresh proof of the mailbox (see above).
    if (!(await accountHasPasskey(env, session.sub, email)) && await env.STUDIQUO_DATA.get(emailProofKey(userKey)) !== email) {
      return json({ error: "メールで届いたコードの確認が必要です。", code: "email_code_required" }, 403);
    }
    const existing = await env.STUDIQUO_DATA.get<PasskeyRecord[]>(`passkeys:user:${userKey}`, "json") ?? [];
    const options = await generateRegistrationOptions({
      rpName: "Studiquo",
      rpID: RP_ID,
      userName: email,
      userDisplayName: email,
      userID: new TextEncoder().encode(userKey) as Uint8Array<ArrayBuffer>,
      attestationType: "none",
      excludeCredentials: existing.map(item => ({ id: item.id, transports: item.transports ?? ["internal"] })),
      authenticatorSelection: {
        authenticatorAttachment: "platform",
        residentKey: "required",
        userVerification: "required",
      },
      supportedAlgorithmIDs: [-7],
    });
    const transaction = transactionID();
    await env.STUDIQUO_DATA.put(`passkeys:challenge:${transaction}`, JSON.stringify({
      kind: "registration", challenge: options.challenge, userKey, email,
    }), { expirationTtl: 300 });
    return json({ transaction, options });
  }

  if (url.pathname === "/api/passkeys/register/verify" && request.method === "POST") {
    const token = bearerToken(request);
    if (token) {
      const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_REGISTER_VERIFY, await sha256Hex(token));
      if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    }
    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const pending = await env.STUDIQUO_DATA.get<PasskeyChallenge>(`passkeys:challenge:${transaction}`, "json");
    if (!token || !pending || pending.kind !== "registration" || pending.userKey !== await sha256Hex(token)) {
      return json({ error: "Registration expired." }, 400);
    }
    if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
    if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
    if (await isRevoked(env, pending.userKey)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);
    await env.STUDIQUO_DATA.delete(`passkeys:challenge:${transaction}`);
    await env.STUDIQUO_DATA.delete(emailProofKey(pending.userKey));
    try {
      const verification = await verifyRegistrationResponse({
        response: payload.credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        requireUserVerification: true,
      });
      if (!verification.verified) return json({ error: "Passkey verification failed." }, 401);
      const saved = await env.STUDIQUO_DATA.get<PasskeyRecord[]>(`passkeys:user:${pending.userKey}`, "json") ?? [];
      const credential = verification.registrationInfo.credential;
      const record = {
        id: credential.id,
        publicKey: Array.from(credential.publicKey),
        counter: credential.counter,
        transports: credential.transports ?? ["internal"],
        email: pending.email,
        userKey: pending.userKey,
        // Protects the account from the moment it is registered (passkey-policy.ts).
        createdAt: Date.now(),
      };
      const updated = [...saved.filter(item => item.id !== record.id), record].slice(-10);
      // Listed BEFORE the record exists, and always (at least under the address):
      // deleting an account finds its passkeys through this list, so a record
      // must never exist without an entry in it.
      const owner = await realSession(env, token);
      await indexAccountPasskey(env, owner?.sub ?? `email:${pending.email}`, pending.email!, record.id);
      await Promise.all([
        env.STUDIQUO_DATA.put(`passkeys:user:${pending.userKey}`, JSON.stringify(updated)),
        env.STUDIQUO_DATA.put(`passkeys:credential:${record.id}`, JSON.stringify(record)),
      ]);
      await sendPasskeyNotice(env, pending.email!, "Studiquoにパスキーが追加されました", [
        "お使いのStudiquoアカウントに、パスキーが追加されました。",
        "",
        "このパスキーは登録した時点から有効です。以降、パスワード、メールのコード、Apple、Googleによるログインはできなくなります(パスキーを使えない場合の復旧手続きを除く)。",
        "心当たりがない場合は、メールアカウントのパスワードを変更してください。そのうえで、Studiquoでパスワードやメールのコードによるログインを試みると、復旧の手続きが始まります。48時間後にもう一度ログインすると、すべてのパスキーが削除され、すべての端末がログアウトされます。",
      ]);
      return json({ registered: true });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  if (url.pathname === "/api/passkeys/login/options" && request.method === "POST") {
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_LOGIN_OPTIONS, clientKey(request));
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: "required",
      allowCredentials: [],
    });
    const transaction = transactionID();
    await env.STUDIQUO_DATA.put(`passkeys:challenge:${transaction}`, JSON.stringify({
      kind: "authentication", challenge: options.challenge,
    }), { expirationTtl: 300 });
    return json({ transaction, options });
  }

  if (url.pathname === "/api/passkeys/login/verify" && request.method === "POST") {
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_LOGIN_VERIFY, clientKey(request));
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);

    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const credentialID = String(payload?.credential?.id ?? "");
    const [pending, record] = await Promise.all([
      env.STUDIQUO_DATA.get<PasskeyChallenge>(`passkeys:challenge:${transaction}`, "json"),
      env.STUDIQUO_DATA.get<PasskeyRecord>(`passkeys:credential:${credentialID}`, "json"),
    ]);
    if (!pending || pending.kind !== "authentication" || !record) return json({ error: "Login expired." }, 400);
    await env.STUDIQUO_DATA.delete(`passkeys:challenge:${transaction}`);
    try {
      const verification = await verifyAuthenticationResponse({
        response: payload.credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        credential: {
          id: record.id,
          publicKey: new Uint8Array(record.publicKey),
          counter: record.counter,
          transports: record.transports,
        },
        requireUserVerification: true,
      });
      if (!verification.verified) return json({ error: "Passkey verification failed." }, 401);
      // A reset cuts off every passkey registered before it, including one the
      // reset's own sweep did not find.
      if (await passkeyRevokedByReset(env, record)) return json({ error: "Passkey verification failed." }, 401);
      record.counter = verification.authenticationInfo.newCounter;
      await env.STUDIQUO_DATA.put(`passkeys:credential:${record.id}`, JSON.stringify(record));
      // A successful passkey assertion is itself the proof of identity, same
      // as a verified Apple/Google token — mint a real session the same way
      // those exchanges do, rather than leaving the client to keep reusing
      // whatever bearer token it happened to already hold.
      const token = await mintPasskeySession(env, record.email);
      if (!token) return json({ error: "Signing in is not available for this account right now." }, 400);
      // Passkeys registered before the per-account list existed are listed
      // the first time they are used, and a recovery someone else started
      // is called off.
      const owner = await realSession(env, token);
      if (owner) {
        await indexAccountPasskey(env, owner.sub, record.email, record.id);
        // Only a passkey that has had time to be trusted calls a recovery off.
        if (isEstablishedPasskey(record) && await cancelPasskeyRecovery(env, owner.sub, record.email)) {
          // Whoever started the recovery is told it came to nothing, so a
          // passkey that is not the owner's does not keep it off in silence.
          await sendPasskeyNotice(env, record.email, "Studiquoのパスキーを使わない復旧が取り消されました", [
            "パスキーを使わずにログインするための復旧手続きが、パスキーでのログインによって取り消されました。",
            "",
            record.createdAt ? `使われたパスキーの登録日時: ${new Date(record.createdAt).toISOString()}` : "使われたパスキーの登録日時: 不明",
            "ご自身のログインでない場合は、メールアカウントのパスワードを変更し、復旧の手続きをもう一度行ってください。",
          ]);
        }
      }
      // Having just used the passkey, this session need not be asked again
      // for the next few minutes.
      await markRecentPasskey(env, await sha256Hex(token));
      return json({ authenticated: true, email: record.email, token });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  if (url.pathname === "/api/passkeys/status" && request.method === "GET") {
    const auth = await authenticatedSession(request, env);
    if (auth.response) return auth.response;
    const ids = await listAccountPasskeys(env, auth.session.sub, null);
    return json({ registered: ids.length > 0, count: ids.length });
  }

  // Removes every passkey of the account, after that passkey's own check. The
  // app no longer offers this; it stays for apps released before that.
  if (url.pathname === "/api/passkeys/remove-all" && request.method === "POST") {
    const auth = await authenticatedSession(request, env);
    if (auth.response) return auth.response;
    const token = bearerToken(request);
    const needsPasskey = await requireRecentPasskey(env, token!, auth.session, "remove-passkeys");
    if (needsPasskey) return needsPasskey;
    await removeAllPasskeys(env, auth.session.sub, null);
    return json({ removed: true });
  }

  // Asks the signed-in person to use a passkey of THIS account right now; the
  // session then counts as freshly verified for a few minutes (see
  // requireRecentPasskey). Only the account's own passkeys are offered.
  if (url.pathname === "/api/passkeys/reauth/options" && request.method === "POST") {
    // Deleting the account asks for this, and a suspended person may still delete.
    const auth = await authenticatedSession(request, env, { allowSuspended: true });
    if (auth.response) return auth.response;
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_LOGIN_OPTIONS, auth.tokenHash);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const payload = await body(request);
    const action = String(payload?.action ?? "");
    if (!REAUTH_ACTIONS.includes(action)) return json({ error: "Invalid action." }, 400);
    const ids = await listEstablishedPasskeys(env, auth.session.sub, null);
    if (ids.length === 0) return json({ error: "No passkey is registered." }, 404);
    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: "required",
      allowCredentials: ids.map(id => ({ id, transports: ["internal"] })),
    });
    const transaction = transactionID();
    await env.STUDIQUO_DATA.put(`passkeys:challenge:${transaction}`, JSON.stringify({
      kind: "reauth", challenge: options.challenge, tokenHash: auth.tokenHash, action,
    }), { expirationTtl: 300 });
    return json({ transaction, options });
  }

  if (url.pathname === "/api/passkeys/reauth/verify" && request.method === "POST") {
    // Deleting the account asks for this, and a suspended person may still delete.
    const auth = await authenticatedSession(request, env, { allowSuspended: true });
    if (auth.response) return auth.response;
    const allowed = await checkRateLimit(env.RATE_LIMIT_PASSKEY_LOGIN_VERIFY, auth.tokenHash);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const payload = await body(request);
    const transaction = String(payload?.transaction ?? "");
    const credentialID = String(payload?.credential?.id ?? "");
    const [pending, record] = await Promise.all([
      env.STUDIQUO_DATA.get<PasskeyChallenge>(`passkeys:challenge:${transaction}`, "json"),
      env.STUDIQUO_DATA.get<PasskeyRecord>(`passkeys:credential:${credentialID}`, "json"),
    ]);
    // The challenge belongs to this session, and the passkey to this account.
    if (!pending || pending.kind !== "reauth" || pending.tokenHash !== auth.tokenHash || !record) {
      return json({ error: "Verification expired." }, 400);
    }
    await env.STUDIQUO_DATA.delete(`passkeys:challenge:${transaction}`);
    const ids = await listEstablishedPasskeys(env, auth.session.sub, null);
    if (!ids.includes(record.id)) return json({ error: "Passkey verification failed." }, 401);
    try {
      const verification = await verifyAuthenticationResponse({
        response: payload.credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        credential: {
          id: record.id,
          publicKey: new Uint8Array(record.publicKey),
          counter: record.counter,
          transports: record.transports,
        },
        requireUserVerification: true,
      });
      if (!verification.verified) return json({ error: "Passkey verification failed." }, 401);
      record.counter = verification.authenticationInfo.newCounter;
      await env.STUDIQUO_DATA.put(`passkeys:credential:${record.id}`, JSON.stringify(record));
      await markRecentPasskey(env, auth.tokenHash, pending.action);
      return json({ verified: true });
    } catch {
      return json({ error: "Passkey verification failed." }, 401);
    }
  }

  return json({ error: "Not found" }, 404);
}

// The checks every signed-in passkey route shares: a well-formed, unexpired,
// server-issued, unrevoked token. Returns the session, or the response to send.
async function authenticatedSession(request: Request, env: Env, options?: { allowSuspended?: boolean }) {
  const token = bearerToken(request);
  if (!token) return { response: json({ error: "A valid bearer token is required." }, 401) };
  if (isExpired(token)) return { response: json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401) };
  const session = await realSession(env, token, options);
  if (!session) return { response: json({ error: "Reconnect from Studiquo to get a new token." }, 401) };
  const tokenHash = await sha256Hex(token);
  if (await isRevoked(env, tokenHash)) return { response: json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401) };
  return { session, tokenHash };
}
