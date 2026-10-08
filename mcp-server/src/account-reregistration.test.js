import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { sha256Hex } from "./auth.js";
import { deleteAccount, startAccountDeletion } from "./account-deletion.js";
import { processPendingDeletions, runPrivacyRetention, runScheduledPrivacyWork } from "./privacy-retention.js";
import { mintSession, realSession } from "./session.js";

// A real (in-memory SQLite) ADMIN_DB with every migration applied, so the
// deletion path runs exactly as it does in production, including the
// RevenueCat outbox it leaves behind.
function environment(extra = {}) {
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(new URL("../migrations/", import.meta.url)).sort()) db.exec(readFileSync(new URL(`../migrations/${name}`, import.meta.url), "utf8"));
  const values = new Map();
  const statement = (sql, params = []) => ({
    bind(...args) { return statement(sql, args); },
    async run() { return { success: true, meta: db.prepare(sql).run(...params) }; },
    async all() { return { results: db.prepare(sql).all(...params) }; },
    async first() { return db.prepare(sql).get(...params) ?? null; },
  });
  return {
    ADMIN_DB: { prepare: statement },
    STUDIQUO_DATA: {
      async get(key, type) { const value = values.get(key) ?? null; return value && type === "json" ? JSON.parse(value) : value; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix, limit = 1000 }) { const keys = [...values.keys()].filter(key => key.startsWith(prefix)).slice(0, limit); return { keys: keys.map(name => ({ name })), list_complete: true }; },
    },
    _db: db,
    _values: values,
    ...extra,
  };
}

const RANDOM = "r".repeat(40);
const jobKey = async identity => `privacy-rc-delete:${await sha256Hex(identity)}`;
const stateKey = async identity => `account-deletion:${await sha256Hex(identity)}`;

// Signs in as `identity`, gives the account some data that deletion must erase,
// and returns the session token.
async function signInWithData(env, identity, marker) {
  const token = await mintSession(env, identity, RANDOM + marker);
  assert.ok(token, "sign-in should succeed");
  // Snapshots are stored under the hash of the session token that uploaded them.
  env._values.set(`snapshot:${await sha256Hex(token)}`, "{}");
  env._values.set(`account:${identity}`, "{}");
  return token;
}

test("H1: an account re-registered after deletion is really erased by a second deletion", async () => {
  const env = environment();
  const identity = "apple:reregistering";
  const firstToken = await signInWithData(env, identity, "first-life");
  assert.deepEqual(await startAccountDeletion(env, identity), { deleted: true, externalDeletionPending: true });
  assert.equal(env._values.has("account:apple:reregistering"), false);
  assert.equal(env._values.has(`snapshot:${await sha256Hex(firstToken)}`), false);
  assert.equal(JSON.parse(env._values.get(await stateKey(identity))).status, "deleted");

  // Same person signs in again: a new account. The marker must not outlive that.
  const secondToken = await signInWithData(env, identity, "second-life");
  const marker = JSON.parse(env._values.get(await stateKey(identity)));
  assert.equal(marker.status, "active", "the deleted marker is replaced by the new sign-in");
  assert.equal(typeof marker.reregisteredAt, "number");

  // Deleting the new account must run in full, not return early with nothing erased.
  assert.deepEqual(await startAccountDeletion(env, identity), { deleted: true, externalDeletionPending: true });
  assert.equal(env._values.has("account:apple:reregistering"), false, "the new account's data is erased");
  assert.equal(env._values.has(`snapshot:${await sha256Hex(secondToken)}`), false);
  assert.equal(env._values.has(`session:${await sha256Hex(secondToken)}`), false, "the new session is revoked too");
  assert.equal(JSON.parse(env._values.get(await stateKey(identity))).status, "deleted");
});

test("H1: a stale retry of a finished deletion is still a no-op until the person signs in again", async () => {
  const env = environment();
  const identity = "google:one-shot";
  await signInWithData(env, identity, "only-life");
  await deleteAccount(env, identity);
  // Data that appears with no sign-in (a stray write) is not the account's: the early return stays.
  env._values.set("account:google:one-shot", "{}");
  assert.deepEqual(await deleteAccount(env, identity), { deleted: true });
  assert.equal(env._values.has("account:google:one-shot"), true);
});

test("H2: a queued RevenueCat deletion no longer locks the person out of signing in again", async () => {
  const env = environment(); // no REVENUECAT_SECRET_API_KEY, retention flag off: the shipping configuration
  const identity = "email:comeback@example.com";
  await signInWithData(env, identity, "life");
  await startAccountDeletion(env, identity);
  assert.ok(env._values.has(await jobKey(identity)), "deletion leaves a provider job queued");

  const token = await mintSession(env, identity, RANDOM + "again");
  assert.ok(token, "signing in again succeeds");
  assert.equal(env._values.has(await jobKey(identity)), false, "the pending provider DELETE is dropped so it cannot erase the new customer");
  assert.ok(await realSession(env, token), "and the new session is usable");
});

test("H2: coming back through one sign-in method drops only that identity's queued job, and never blocks", async () => {
  const env = environment();
  const apple = "apple:alias-one", google = "google:alias-two";
  env._values.set(`identity-canonical:${google}`, apple);
  env._values.set(`identity-canonical:${apple}`, apple);
  await signInWithData(env, apple, "life");
  await startAccountDeletion(env, apple);
  assert.ok(env._values.has(await jobKey(apple)));
  assert.ok(env._values.has(await jobKey(google)));

  // The person comes back with Apple only.
  const token = await mintSession(env, apple, RANDOM + "back");
  assert.ok(token);
  assert.equal(env._values.has(await jobKey(apple)), false, "the identity that signed in again is that customer again");
  assert.equal(env._values.has(await jobKey(google)), true, "an alias that was not signed in to keeps its queued erasure");
  // The alias job is still there but must not stop the alias itself from signing in later.
  assert.ok(await mintSession(env, google, RANDOM + "alias"));
  assert.equal(env._values.has(await jobKey(google)), false);
});

test("N1: a leftover cleanup job cannot erase an account created after the deletion", async () => {
  const env = environment();
  const identity = "apple:leftover-job";
  await signInWithData(env, identity, "first-life");
  // The deletion completes and records "deleted", but removing its job fails (a KV hiccup):
  // the person is told the cleanup is pending and the job stays queued.
  const realDelete = env.STUDIQUO_DATA.delete;
  const jobKeyName = `privacy-account-delete:${await sha256Hex(identity)}`;
  env.STUDIQUO_DATA.delete = async key => { if (key === jobKeyName) throw new Error("temporary storage outage"); return realDelete(key); };
  assert.deepEqual(await startAccountDeletion(env, identity), { deleted: false, cleanupPending: true });
  env.STUDIQUO_DATA.delete = realDelete;
  assert.equal(env._values.has(jobKeyName), true, "the leftover job is still queued");
  assert.equal(JSON.parse(env._values.get(await stateKey(identity))).status, "deleted");

  // The person signs in again and has a new account with data.
  const token = await signInWithData(env, identity, "second-life");
  assert.equal(env._values.has(jobKeyName), false, "signing in again retires the old account's cleanup job");

  // The next scheduled run must leave the new account alone.
  await processPendingDeletions(env);
  assert.equal(env._values.has("account:apple:leftover-job"), true, "the new account's data survives");
  assert.ok(await realSession(env, token), "and its session still works");
});

test("H2: another person's queued job is untouched", async () => {
  const env = environment();
  await signInWithData(env, "apple:leaver", "leaver");
  await signInWithData(env, "apple:stayer", "stayer");
  await startAccountDeletion(env, "apple:leaver");
  await mintSession(env, "apple:stayer", RANDOM + "stayer2");
  assert.ok(env._values.has(await jobKey("apple:leaver")));
});

test("an account whose deletion is still in progress cannot sign in yet", async () => {
  const env = environment();
  const identity = "apple:half-deleted";
  await signInWithData(env, identity, "life");
  env._values.set(await stateKey(identity), JSON.stringify({ status: "deleting", deletionKeys: [] }));
  assert.equal(await mintSession(env, identity, RANDOM + "x"), null);
});

test("an ordinary sign-in performs no KV writes besides the session", async () => {
  const env = environment();
  const writes = [];
  const { put, delete: del } = env.STUDIQUO_DATA;
  env.STUDIQUO_DATA.put = async (key, value, options) => { writes.push(["put", key]); return put(key, value, options); };
  env.STUDIQUO_DATA.delete = async key => { writes.push(["delete", key]); return del(key); };
  assert.ok(await mintSession(env, "apple:ordinary", RANDOM));
  assert.deepEqual(writes.map(([kind]) => kind), ["put"]);
  assert.match(writes[0][1], /^session:/);
});

test("H2: pending deletions finish even while the automatic retention flag is off", async () => {
  const env = environment({ REVENUECAT_SECRET_API_KEY: "test-only-secret" }); // PRIVACY_RETENTION_ENABLED is not "true"
  const identity = "apple:cleanup-pending";
  await signInWithData(env, identity, "life");
  const original = env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare = () => ({ bind() { return { async run() { throw new Error("temporary storage outage"); } }; } });
  assert.deepEqual(await startAccountDeletion(env, identity), { deleted: false, cleanupPending: true });
  env.ADMIN_DB.prepare = original;
  assert.equal(await mintSession(env, identity, RANDOM + "stuck"), null, "stuck mid-deletion, sign-in is refused");

  // runPrivacyRetention is gated by the flag, so it does nothing...
  assert.deepEqual(await runPrivacyRetention(env), { enabled: false });
  assert.ok(env._values.has(`privacy-account-delete:${await sha256Hex(identity)}`));
  // ...but the pending-deletion pass the scheduled handler uses when the flag is off finishes the job.
  const calls = [];
  await processPendingDeletions(env, async (url, options) => { calls.push([url, options.method]); return new Response(null, { status: 200 }); });
  assert.equal(env._values.has(`privacy-account-delete:${await sha256Hex(identity)}`), false);
  assert.equal(JSON.parse(env._values.get(await stateKey(identity))).status, "deleted");
  assert.ok(await mintSession(env, identity, RANDOM + "free"), "and the person can sign in again");
  assert.ok(calls.every(([, method]) => method === "DELETE"));
});

test("L1: the schedule runs only the pending deletions when the retention flag is off", async () => {
  const env = environment(); // no PRIVACY_RETENTION_ENABLED
  const identity = "apple:scheduled";
  await signInWithData(env, identity, "life");
  env._values.set(`privacy-account-delete:${await sha256Hex(identity)}`, JSON.stringify({ canonicalSub: identity, requestedAt: Date.now() }));
  // Old data that the automatic expiry would sweep: it must stay while the flag is off.
  env._db.prepare("INSERT INTO issue_reports (id, reporter_key, description, created_at, updated_at) VALUES ('old', 'k', 'd', 1, 1)").run();
  assert.deepEqual(await runScheduledPrivacyWork(env, Date.now()), { enabled: false });
  assert.equal(env._values.has("account:apple:scheduled"), false, "the requested deletion finished");
  assert.equal(env._db.prepare("SELECT count(*) AS n FROM issue_reports").get().n, 1, "the automatic expiry did not run");
});

test("L1: the schedule runs the full retention job when the flag is on", async () => {
  const env = environment({ PRIVACY_RETENTION_ENABLED: "true" });
  env._db.prepare("INSERT INTO issue_reports (id, reporter_key, description, created_at, updated_at) VALUES ('old', 'k', 'd', 1, 1)").run();
  await runScheduledPrivacyWork(env, Date.now());
  assert.equal(env._db.prepare("SELECT count(*) AS n FROM issue_reports").get().n, 0, "the 90-day expiry ran");
});

test("L3: pending deletions can be processed without an ADMIN_DB binding", async () => {
  const env = environment();
  delete env.ADMIN_DB;
  const identity = "apple:no-db";
  await signInWithData(env, identity, "life");
  env._values.set(`privacy-account-delete:${await sha256Hex(identity)}`, JSON.stringify({ canonicalSub: identity, requestedAt: Date.now() }));
  await processPendingDeletions(env);
  assert.equal(env._values.has("account:apple:no-db"), false);
});

test("N4: a run that is not the full retention job takes only a few jobs at a time", async () => {
  const env = environment();
  for (let i = 0; i < 5; i++) {
    const identity = `apple:batch-${i}`;
    await signInWithData(env, identity, `life${i}`);
    env._values.set(`privacy-account-delete:${await sha256Hex(identity)}`, JSON.stringify({ canonicalSub: identity, requestedAt: Date.now() }));
  }
  await runScheduledPrivacyWork(env, Date.now()); // flag off: limit of 2 per kind
  const remaining = [...env._values.keys()].filter(key => key.startsWith("privacy-account-delete:")).length;
  assert.equal(remaining, 3);
});

test("M1: a retry that read the old job just before the person came back leaves the new account alone", async () => {
  const env = environment();
  const identity = "apple:race";
  await signInWithData(env, identity, "first-life");
  const jobName = `privacy-account-delete:${await sha256Hex(identity)}`;
  // The deletion finishes, but removing its job fails: the job stays queued.
  const realDelete = env.STUDIQUO_DATA.delete;
  env.STUDIQUO_DATA.delete = async key => { if (key === jobName) throw new Error("temporary storage outage"); return realDelete(key); };
  await startAccountDeletion(env, identity);
  env.STUDIQUO_DATA.delete = realDelete;
  const jobRead = JSON.parse(env._values.get(jobName)); // what a cron run has just read

  // The person signs in again, then the cron run carries on with what it read.
  const token = await signInWithData(env, identity, "second-life");
  assert.equal(env._values.has(jobName), false);
  assert.deepEqual(await deleteAccount(env, jobRead.canonicalSub), { deleted: true });
  assert.equal(env._values.has("account:apple:race"), true, "the new account is untouched");
  assert.ok(await realSession(env, token));
});

test("M1: a deletion the person asks for after coming back is not mistaken for a leftover", async () => {
  const env = environment();
  const identity = "apple:asks-again";
  await signInWithData(env, identity, "first-life");
  await startAccountDeletion(env, identity);
  await signInWithData(env, identity, "second-life");
  // No timer is faked: requestedAt is written after reregisteredAt by construction.
  assert.deepEqual(await startAccountDeletion(env, identity), { deleted: true, externalDeletionPending: true });
  assert.equal(env._values.has("account:apple:asks-again"), false);
});

test("the cycle sign in, delete, sign in again works any number of times", async () => {
  const env = environment();
  const identity = "apple:cycles";
  for (let life = 1; life <= 3; life++) {
    const token = await signInWithData(env, identity, `life${life}`);
    assert.ok(await realSession(env, token), `life ${life} can sign in`);
    assert.deepEqual(await startAccountDeletion(env, identity), { deleted: true, externalDeletionPending: true });
    assert.equal(env._values.has("account:apple:cycles"), false, `life ${life} is erased`);
    assert.equal(await realSession(env, token), null, `life ${life}'s session is revoked`);
  }
});

test("N4: without the provider secret the RevenueCat pass is skipped and its jobs stay put", async () => {
  const env = environment();
  const key = await jobKey("apple:no-secret");
  env._values.set(key, JSON.stringify({ identity: "apple:no-secret", requestedAt: Date.now() }));
  let calls = 0;
  await processPendingDeletions(env, async () => { calls++; return new Response(null, { status: 200 }); });
  assert.equal(calls, 0);
  assert.equal(env._values.has(key), true);
  env.REVENUECAT_SECRET_API_KEY = "test-only-secret";
  await processPendingDeletions(env, async () => { calls++; return new Response(null, { status: 200 }); });
  assert.equal(calls, 1);
  assert.equal(env._values.has(key), false);
});

test("M1: a leftover job from before the new account is cleared without touching the account", async () => {
  const env = environment();
  const identity = "apple:stale-present";
  await signInWithData(env, identity, "first-life");
  await startAccountDeletion(env, identity);
  await signInWithData(env, identity, "second-life");
  // A leftover job that is still queued, older than the new account.
  const jobName = `privacy-account-delete:${await sha256Hex(identity)}`;
  env._values.set(jobName, JSON.stringify({ canonicalSub: identity, requestedAt: 1 }));
  assert.deepEqual(await processPendingDeletions(env), undefined);
  assert.equal(env._values.has("account:apple:stale-present"), true, "the new account is untouched");
  assert.equal(env._values.has(jobName), false, "and the leftover job is cleared");
});

test("M1: a request made while a leftover is being cleared is not lost", async () => {
  const env = environment();
  const identity = "apple:request-in-flight";
  await signInWithData(env, identity, "first-life");
  await startAccountDeletion(env, identity);
  await signInWithData(env, identity, "second-life");
  const jobName = `privacy-account-delete:${await sha256Hex(identity)}`;
  // The first read sees a leftover; before the second read the person's own request has written its job.
  env._values.set(jobName, JSON.stringify({ canonicalSub: identity, requestedAt: 1 }));
  const realGet = env.STUDIQUO_DATA.get;
  let jobReads = 0;
  env.STUDIQUO_DATA.get = async (key, type) => {
    if (key === jobName && ++jobReads === 2) env._values.set(jobName, JSON.stringify({ canonicalSub: identity, requestedAt: Date.now() + 1000 }));
    return realGet(key, type);
  };
  await deleteAccount(env, identity);
  assert.equal(env._values.has("account:apple:request-in-flight"), false, "the person's request is carried out");
});

test("M1: an 'active' marker without a usable time never makes a request a no-op", async () => {
  const env = environment();
  const identity = "apple:bad-marker";
  await signInWithData(env, identity, "life");
  env._values.set(await stateKey(identity), JSON.stringify({ status: "active" }));
  env._values.set(`privacy-account-delete:${await sha256Hex(identity)}`, JSON.stringify({ canonicalSub: identity, requestedAt: Date.now() }));
  await deleteAccount(env, identity);
  assert.equal(env._values.has("account:apple:bad-marker"), false);
});

test("N4: queued provider deletions without a secret are reported, and only then", async () => {
  const warnings = [];
  const realWarn = console.warn;
  console.warn = message => warnings.push(message);
  try {
    const env = environment();
    await processPendingDeletions(env);
    assert.equal(warnings.length, 0, "nothing queued, nothing to say");
    env._values.set(await jobKey("apple:waiting"), JSON.stringify({ identity: "apple:waiting", requestedAt: Date.now() }));
    await processPendingDeletions(env);
    assert.equal(warnings.length, 1);
    assert.doesNotMatch(warnings[0], /apple:waiting/, "no identity in the log");
  } finally {
    console.warn = realWarn;
  }
});
