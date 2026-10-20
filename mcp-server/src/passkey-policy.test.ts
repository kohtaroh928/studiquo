import assert from "node:assert/strict";
import test, { mock } from "node:test";
import {
  RECOVERY_DELAY_SECONDS, accountHasPasskey, removeAllPasskeys, cancelPasskeyRecovery, gatePasskeyAccount,
  indexAccountPasskey, listAccountPasskeys, markRecentPasskey, requireRecentPasskey,
} from "./passkey-policy.ts";
import { sha256Hex } from "./auth.ts";
import { realSession } from "./session.ts";
import { partialEnv, type LooseEnv } from "./test-env.ts";

function environment() {
  const values = new Map();
  return partialEnv({
    RESEND_API_KEY: "test-key",
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key: string, value: string) { values.set(key, value); },
      async delete(key: string) { values.delete(key); },
    },
  });
}

function captureMail() {
  const sent: { url: string; body: any; }[] = [];
  const original = mock.method(globalThis, "fetch", async (url: string, init: { body: string; }) => {
    sent.push({ url, body: JSON.parse(init.body) });
    return new Response("{}", { status: 200 });
  });
  return { sent, restore: () => original.mock.restore() };
}

async function addPasskey(env: LooseEnv, id: string, { account = ACCOUNT, email = EMAIL, createdAt }: { account?: string; email?: string; createdAt?: number } = {}) {
  await env.STUDIQUO_DATA.put(`passkeys:credential:${id}`, JSON.stringify({ id, email, ...(createdAt === undefined ? {} : { createdAt }) }));
  await indexAccountPasskey(env, account, email, id);
}

const ACCOUNT = "email:person@example.com";
const EMAIL = "person@example.com";
const HOUR = 3_600_000;

test("an account with no passkey is never held back", async () => {
  const env = environment();
  assert.equal(await accountHasPasskey(env, ACCOUNT, EMAIL), false);
  assert.equal(await gatePasskeyAccount(env, ACCOUNT, EMAIL), null);
});

test("passkeys are found under the canonical account and under the e-mail identity", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("identity-canonical:email:person@example.com", "google:g-1");
  await addPasskey(env, "cred-1", { account: "google:g-1" });
  assert.deepEqual(await listAccountPasskeys(env, "google:g-1", null), ["cred-1"]);
  assert.deepEqual(await listAccountPasskeys(env, ACCOUNT, EMAIL), ["cred-1"]);
  // Linking later moves the canonical account; the e-mail listing still finds it.
  assert.equal(await accountHasPasskey(env, "google:someone-else", EMAIL), true);
});

test("the first sign-in without a passkey is refused, starts a recovery and tells the owner", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    const now = Date.now();
    const pending: any[] = [];
    const response = await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now, notify: work => pending.push(work) });
    await Promise.all(pending);

    assert.equal(response.status, 403);
    const body = await response.json();
    assert.equal(body.code, "passkey_required");
    assert.equal(body.recoveryAvailableAt, now + RECOVERY_DELAY_SECONDS * 1000);
    assert.equal(mail.sent.length, 1);
    assert.equal(mail.sent[0].body.to, EMAIL);
  } finally { mail.restore(); }
});

test("a second attempt during the wait is refused without another mail and keeps the same time", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    const start = Date.now();
    const first = await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start });
    await new Promise(resolve => setImmediate(resolve));
    const second = await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start + 24 * HOUR });
    assert.equal(second.status, 403);
    assert.equal((await second.json()).recoveryAvailableAt, (await first.json()).recoveryAvailableAt);
    assert.equal(mail.sent.length, 1);
  } finally { mail.restore(); }
});

test("after the wait the sign-in goes through once and the old passkeys are removed", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    const start = Date.now();
    await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start });
    const after = await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start + RECOVERY_DELAY_SECONDS * 1000 + 1 });
    assert.equal(after, null);
    assert.equal(await accountHasPasskey(env, ACCOUNT, EMAIL), false);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:cred-1"), null);
  } finally { mail.restore(); }
});

test("a passkey sign-in calls off a recovery someone else started", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    const start = Date.now();
    await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start });
    await cancelPasskeyRecovery(env, ACCOUNT, EMAIL);
    // The wait starts over: a later attempt is a new recovery, not a finished one.
    const response = await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start + RECOVERY_DELAY_SECONDS * 1000 + 1 });
    assert.equal(response.status, 403);
  } finally { mail.restore(); }
});

test("requireRecentPasskey: no passkey means no demand; with one it needs a fresh check in this session", async () => {
  const env = environment();
  const token = `${Math.floor(Date.now() / 1000)}.${"t".repeat(40)}`;
  const session = { sub: ACCOUNT };
  assert.equal(await requireRecentPasskey(env, token, session, "delete-account"), null);

  await addPasskey(env, "cred-1");
  const refused = await requireRecentPasskey(env, token, session, "delete-account");
  assert.equal(refused.status, 403);
  assert.equal((await refused.json()).code, "reauth_required");

  await markRecentPasskey(env, await sha256Hex(token), "delete-account");
  // A check made for one action is not good for another, and is used up.
  assert.equal((await requireRecentPasskey(env, token, session, "approve-app")).status, 403);
  assert.equal(await requireRecentPasskey(env, token, session, "delete-account"), null);
  assert.equal((await requireRecentPasskey(env, token, session, "delete-account")).status, 403, "used up");
  // Another session of the same account has not proved anything.
  const other = `${Math.floor(Date.now() / 1000)}.${"u".repeat(40)}`;
  assert.equal((await requireRecentPasskey(env, other, session, "delete-account")).status, 403);
  // A check right after signing in with a passkey is good for one action of any kind.
  await markRecentPasskey(env, await sha256Hex(other));
  assert.equal(await requireRecentPasskey(env, other, session, "approve-app"), null);
});

test("passkeys registered before the per-account list existed are found once and then indexed", async () => {
  const env = environment();
  const keys = new Map();
  const base = env.STUDIQUO_DATA;
  env.STUDIQUO_DATA = {
    ...base,
    async put(key: string, value: string) { keys.set(key, value); return base.put(key, value); },
    async list({ prefix }) {
      return { keys: [...keys.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true };
    },
  };
  // A credential record from before the list existed: nothing points at it.
  await env.STUDIQUO_DATA.put("passkeys:credential:old-1", JSON.stringify({ id: "old-1", email: EMAIL }));

  assert.equal(await accountHasPasskey(env, ACCOUNT, EMAIL), true);
  assert.equal(await accountHasPasskey(env, "google:someone", EMAIL), true);
  assert.equal(await base.get("passkey-index-backfilled"), "1");
  // The sign-in gate sees it too.
  const mail = captureMail();
  try {
    assert.equal((await gatePasskeyAccount(env, ACCOUNT, EMAIL)).status, 403);
  } finally { mail.restore(); }
});


test("a passkey protects the account from the moment it is registered", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    const now = Date.now();
    await addPasskey(env, "fresh", { createdAt: now });
    assert.equal((await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now })).status, 403);
    assert.equal((await requireRecentPasskey(env, "1.t".padEnd(40, "t"), { sub: ACCOUNT }, "delete-account")).status, 403);
  } finally { mail.restore(); }
});

test("passkey list entries whose credential no longer exists are ignored", async () => {
  const env = environment();
  await indexAccountPasskey(env, ACCOUNT, EMAIL, "gone");
  assert.equal(await accountHasPasskey(env, ACCOUNT, EMAIL), false);
  assert.equal(await gatePasskeyAccount(env, ACCOUNT, EMAIL), null);
});

test("finishing a recovery signs out every earlier session and tells the owner", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    const start = Date.now();
    await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: start });
    const pending: any[] = [];
    const done = start + RECOVERY_DELAY_SECONDS * 1000 + 1;
    assert.equal(await gatePasskeyAccount(env, ACCOUNT, EMAIL, { now: done, notify: work => pending.push(work) }), null);
    await Promise.all(pending);
    assert.equal(await env.STUDIQUO_DATA.get(`session-valid-from:${await sha256Hex(ACCOUNT)}`), String(done), "earlier sessions are cut off");
    assert.equal(mail.sent.length, 2, "one when it started, one when it finished");
    assert.match(mail.sent[1].body.subject, /パスキーを使わずに/);
  } finally { mail.restore(); }
});

test("removeAllPasskeys clears the records, the lists and a recovery in progress", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await addPasskey(env, "cred-1");
    await gatePasskeyAccount(env, ACCOUNT, EMAIL);
    await removeAllPasskeys(env, ACCOUNT, EMAIL);
    assert.equal(await accountHasPasskey(env, ACCOUNT, EMAIL), false);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:cred-1"), null);
    assert.equal(await env.STUDIQUO_DATA.get(`passkey-recovery:${await sha256Hex(ACCOUNT)}`), null);
  } finally { mail.restore(); }
});

test("removeAllPasskeys also takes the passkeys out of the per-person list, and keeps other people's", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await env.STUDIQUO_DATA.put("passkeys:credential:mine", JSON.stringify({ id: "mine", email: EMAIL, userKey: "dev-mine" }));
    await indexAccountPasskey(env, ACCOUNT, EMAIL, "mine");
    await env.STUDIQUO_DATA.put("passkeys:user:dev-mine", JSON.stringify([{ id: "mine", email: EMAIL }]));
    await env.STUDIQUO_DATA.put("passkeys:credential:theirs", JSON.stringify({ id: "theirs", email: "other@example.com", userKey: "dev-theirs" }));
    await env.STUDIQUO_DATA.put("passkeys:user:dev-theirs", JSON.stringify([{ id: "theirs", email: "other@example.com" }]));
    await removeAllPasskeys(env, ACCOUNT, EMAIL);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:mine"), null);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:user:dev-mine"), null, "nothing is left that names the removed passkey");
    assert.notEqual(await env.STUDIQUO_DATA.get("passkeys:user:dev-theirs"), null);
    assert.notEqual(await env.STUDIQUO_DATA.get("passkeys:credential:theirs"), null);
  } finally { mail.restore(); }
});

test("removeAllPasskeys also removes a passkey a password reset had already cut off", async () => {
  const env = environment();
  const mail = captureMail();
  try {
    await env.STUDIQUO_DATA.put("passkeys:credential:old", JSON.stringify({ id: "old", email: EMAIL, userKey: "dev-old", createdAt: 1000 }));
    await indexAccountPasskey(env, ACCOUNT, EMAIL, "old");
    await env.STUDIQUO_DATA.put("passkeys:user:dev-old", JSON.stringify([{ id: "old", email: EMAIL }]));
    await env.STUDIQUO_DATA.put(`passkey-valid-from:${await sha256Hex(ACCOUNT)}`, "5000");
    await removeAllPasskeys(env, ACCOUNT, EMAIL);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:credential:old"), null);
    assert.equal(await env.STUDIQUO_DATA.get("passkeys:user:dev-old"), null);
  } finally { mail.restore(); }
});
