import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { sha256Hex } from "./auth.js";
import { runPrivacyRetention, retryRevenueCatDeletion, PERSONAL_RETENTION_MS, ERROR_RETENTION_MS } from "./privacy-retention.js";
import { deleteAccount, startAccountDeletion } from "./account-deletion.js";
import { handleAdminWebhook } from "./admin.js";

function environment() {
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
    PRIVACY_RETENTION_ENABLED: "true",
    RATE_LIMIT_ADMIN_WEBHOOK: { async limit() { return { success: true }; } },
    ADMIN_DB: { prepare: statement },
    STUDIQUO_DATA: {
      async get(key, type) { const value = values.get(key) ?? null; return value && type === "json" ? JSON.parse(value) : value; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix, limit = 1000 }) { const keys = [...values.keys()].filter(key => key.startsWith(prefix)).slice(0, limit); return { keys: keys.map(name => ({ name })), list_complete: true }; },
    },
    _db: db, _values: values,
  };
}

test("retention is fail-closed until explicitly enabled", async () => {
  assert.deepEqual(await runPrivacyRetention({}), { enabled: false });
});

test("90-day report and personal data expiry preserves recent data and removes image bytes", async () => {
  const env = environment(); const now = Date.now();
  for (const [id, timestamp] of [["expired", now - PERSONAL_RETENTION_MS], ["recent", now]]) {
    env._db.prepare("INSERT INTO issue_reports (id, reporter_key, description, created_at, updated_at) VALUES (?, 'key', 'test', ?, ?)").run(id, timestamp, timestamp);
    env._values.set(`issue-report:${id}`, "{}"); env._values.set(`issue-report-screenshot:${id}`, "{}");
    env._db.prepare("INSERT INTO revenuecat_events (event_id, app_user_id, event_type, environment, occurred_at) VALUES (?, 'account', 'RENEWAL', 'SANDBOX', ?)").run(id, timestamp);
    env._db.prepare("INSERT INTO app_error_users (fingerprint, user_key, last_seen_at) VALUES (?, 'account', ?)").run(id, timestamp);
  }
  await runPrivacyRetention(env, now);
  assert.equal(env._values.has("issue-report-screenshot:expired"), false);
  assert.equal(env._values.has("issue-report:expired"), false);
  assert.equal(env._values.has("issue-report-screenshot:recent"), true);
  for (const table of ["issue_reports", "revenuecat_events", "app_error_users"]) assert.equal(env._db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 1);
});

test("180-day aggregates expire with linked accounts and sweeps have bounded batches", async () => {
  const env = environment(); const now = Date.now();
  for (let i = 0; i < 105; i++) env._db.prepare("INSERT INTO app_errors (fingerprint, kind, title, first_seen_at, last_seen_at, updated_at) VALUES (?, 'crash', 'test', 1, ?, 1)").run(String(i), now - ERROR_RETENTION_MS);
  env._db.prepare("INSERT INTO app_error_users (fingerprint, user_key, last_seen_at) VALUES ('0', 'account', ?)").run(now);
  await runPrivacyRetention(env, now);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM app_errors").get().n, 5);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM app_error_users").get().n, 0);
  await runPrivacyRetention(env, now);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM app_errors").get().n, 0);
});

test("erasure deletes reports and billing across aliases while keeping another account", async () => {
  const env = environment(); const sub = "test-owner"; const alias = "google:test-alias";
  env._values.set(`identity-canonical:${alias}`, sub);
  env._values.set("session:legacy-token", JSON.stringify({ sub }));
  for (const [id, account, reporter] of [["owned", sub, "legacy-token"], ["alias", alias, "unrelated"], ["keep", "other", "other-token"]]) {
    const accountKey = await sha256Hex(`usage-account:${account}`);
    env._values.set(`issue-report:${id}`, JSON.stringify({ accountKey, reporterKey: reporter }));
    env._values.set(`issue-report-screenshot:${id}`, "{}");
    env._db.prepare("INSERT INTO issue_reports (id, reporter_key, account_key, description, created_at, updated_at) VALUES (?, ?, ?, 'test', 1, 1)").run(id, reporter, accountKey);
    env._db.prepare("INSERT INTO subscribers (app_user_id, status, updated_at) VALUES (?, 'active', 1)").run(account);
    env._db.prepare("INSERT INTO revenuecat_events (event_id, app_user_id, event_type, environment, occurred_at) VALUES (?, ?, 'RENEWAL', 'SANDBOX', 1)").run(id, account);
  }
  await deleteAccount(env, sub);
  for (const id of ["owned", "alias"]) assert.equal(env._values.has(`issue-report-screenshot:${id}`), false);
  assert.equal(env._values.has("issue-report-screenshot:keep"), true);
  for (const table of ["issue_reports", "subscribers", "revenuecat_events"]) assert.equal(env._db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 1);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM privacy_deleted_customers").get().n, 2);
});

test("accepted erasure resumes without any live session after temporary failure", async () => {
  const env = environment(); const sub = "retry-owner";
  env._values.set("session:retry-token", JSON.stringify({ sub }));
  env._values.set("snapshot:retry-token", "{}");
  const original = env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare = () => ({ bind() { return { async run() { throw new Error("temporary storage outage"); } }; } });
  assert.deepEqual(await startAccountDeletion(env, sub), { deleted: false, cleanupPending: true });
  assert.equal(env._values.has("session:retry-token"), false);
  assert.equal(env._values.has(`privacy-account-delete:${await sha256Hex(sub)}`), true);
  env.ADMIN_DB.prepare = original;
  await runPrivacyRetention(env);
  assert.equal(env._values.has("snapshot:retry-token"), false);
  assert.equal(env._values.has(`privacy-account-delete:${await sha256Hex(sub)}`), false);
});

test("RevenueCat deletion requires configured secret and retries failures without exposing response", async () => {
  const env = environment(); const key = "privacy-rc-delete:test"; const job = { identity: "test/account" };
  env._values.set(key, JSON.stringify(job));
  let calls = 0;
  const fetcher = async (url, options) => { calls++; assert.match(url, /test%2Faccount$/); assert.equal(options.method, "DELETE"); return new Response("private provider data", { status: 503 }); };
  assert.equal(await retryRevenueCatDeletion(env, key, job, fetcher), false); assert.equal(calls, 0);
  env.REVENUECAT_SECRET_API_KEY = "test-only-secret";
  assert.equal(await retryRevenueCatDeletion(env, key, job, fetcher), false); assert.equal(env._values.has(key), true);
  assert.equal(await retryRevenueCatDeletion(env, key, job, async () => new Response(null, { status: 404 })), true);
  assert.equal(env._values.has(key), false);
});

test("future renewal and transfer aliases cannot recreate a deleted customer's records", async () => {
  const env = environment(); env.REVENUECAT_WEBHOOK_SECRET = "test-secret";
  await deleteAccount(env, "deleted-owner");
  const url = new URL("https://test.example/api/admin/revenuecat-webhook");
  const response = await handleAdminWebhook(url, new Request(url, { method: "POST", headers: { authorization: "test-secret", "content-type": "application/json" }, body: JSON.stringify({ event: { id: "renewal", app_user_id: "another-alias", aliases: ["deleted-owner"], type: "RENEWAL", event_timestamp_ms: Date.now() + 60_000 } }) }), env);
  assert.deepEqual(await response.json(), { received: true, ignored: true });
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM subscribers").get().n, 0);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM revenuecat_events").get().n, 0);
});
