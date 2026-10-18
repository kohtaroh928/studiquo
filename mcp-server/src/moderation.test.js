import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.js";
import { runPrivacyRetention } from "./privacy-retention.js";
import { SignJWT, generateKeyPair, exportJWK, createLocalJWKSet } from "jose";

class FakeD1Statement {
  constructor(db, sql, params = []) { this.db = db; this.sql = sql; this.params = params; }
  bind(...params) { return new FakeD1Statement(this.db, this.sql, params); }
  async run() { const r = this.db.prepare(this.sql).run(...this.params); return { success: true, meta: { changes: Number(r.changes) } }; }
  async all() { return { results: this.db.prepare(this.sql).all(...this.params) }; }
  async first() { return this.db.prepare(this.sql).get(...this.params) ?? null; }
}

const ACCESS = { aud: "test-aud", team: "team.cloudflareaccess.com" };
const accessKeys = await generateKeyPair("ES256", { extractable: true });
const accessJWKS = createLocalJWKSet({ keys: [{ ...(await exportJWK(accessKeys.publicKey)), alg: "ES256", use: "sig" }] });
const tokenFor = claims => new SignJWT(claims).setProtectedHeader({ alg: "ES256" })
  .setIssuer(`https://${ACCESS.team}`).setAudience(ACCESS.aud).setIssuedAt().setExpirationTime("1h").sign(accessKeys.privateKey);
const ownerToken = await tokenFor({ email: "owner@example.test", sub: "sub-1" });

function environment(extra = {}) {
  const db = new DatabaseSync(":memory:");
  for (const file of readdirSync(new URL("../migrations/", import.meta.url)).sort()) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  return {
    _db: db,
    ADMIN_DB: { prepare: sql => new FakeD1Statement(db, sql) },
    RATE_LIMIT_ANNOUNCEMENTS: { async limit() { return { success: true }; } },
    ACCESS_AUD: ACCESS.aud, ACCESS_TEAM_DOMAIN: ACCESS.team, ACCESS_JWKS: accessJWKS,
    ...extra,
  };
}

const ctx = { waitUntil() {} };
const call = (env, path, { method = "GET", body, token = ownerToken } = {}) => worker.fetch(
  new Request(`https://example.test${path}`, {
    method,
    headers: { ...(token ? { "cf-access-jwt-assertion": token } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }), env, ctx);

const announcement = { kind: "update", status: "published", translations: { ja: { title: "更新", body: "本文" } } };
const log = env => env._db.prepare("SELECT * FROM admin_audit_log ORDER BY id").all();

function seedChatReport(env, over = {}) {
  const id = over.id ?? crypto.randomUUID();
  env._db.prepare(
    `INSERT INTO chat_reports (id, room_id, message_id, reporter_key, reported_key, reason, snapshot, created_at, updated_at)
     VALUES (?, ?, 1, ?, ?, 'r', ?, ?, ?)`
  ).run(id, "a".repeat(64), over.reporter ?? `rep-${id}`, over.reported ?? "sender",
    JSON.stringify([{ id: 1, text: "SECRET", reported: true }]), over.createdAt ?? Date.now(), over.createdAt ?? Date.now());
  return id;
}

test("announcement create, update, push and delete each add one audit row naming the signed-in operator", async () => {
  const env = environment();
  const created = await (await call(env, "/api/admin/announcements", { method: "POST", body: announcement })).json();
  await call(env, `/api/admin/announcements/${created.id}`, { method: "PUT", body: announcement });
  await call(env, `/api/admin/announcements/${created.id}/push`, { method: "POST" });
  await call(env, `/api/admin/announcements/${created.id}`, { method: "DELETE" });
  const rows = log(env);
  assert.deepEqual(rows.map(row => row.action), ["announcement.create", "announcement.update", "announcement.push", "announcement.delete"]);
  assert.ok(rows.every(row => row.actor === "owner@example.test" && row.target === created.id));
});

test("an operator without an email is recorded by subject; a login that doesn't verify changes nothing and logs nothing", async () => {
  const env = environment();
  const noEmail = await tokenFor({ sub: "svc-7" });
  await call(env, "/api/admin/announcements", { method: "POST", body: announcement, token: noEmail });
  assert.equal(log(env)[0].actor, "svc-7");
  const refused = await call(env, "/api/admin/announcements", { method: "POST", body: announcement, token: null });
  assert.equal(refused.status, 403);
  assert.equal(log(env).length, 1);
});

test("deleting an announcement hides it but keeps the row, and it can no longer be edited or pushed", async () => {
  const env = environment();
  const created = await (await call(env, "/api/admin/announcements", { method: "POST", body: announcement })).json();
  assert.deepEqual(await (await call(env, `/api/admin/announcements/${created.id}`, { method: "DELETE" })).json(), { deleted: true });

  assert.equal((await (await call(env, "/api/admin/announcements")).json()).announcements.length, 0);
  assert.equal((await (await call(env, "/api/announcements")).json()).announcements.length, 0);
  assert.equal((await call(env, `/api/admin/announcements/${created.id}`, { method: "PUT", body: announcement })).status, 404);
  assert.equal((await call(env, `/api/admin/announcements/${created.id}/push`, { method: "POST" })).status, 404);
  const kept = env._db.prepare("SELECT deleted_at FROM announcements WHERE id = ?").get(created.id);
  assert.ok(kept.deleted_at > 0);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM announcement_translations").get().n, 1);
  // A second delete is a quiet no-op: no second audit row.
  await call(env, `/api/admin/announcements/${created.id}`, { method: "DELETE" });
  assert.equal(log(env).filter(row => row.action === "announcement.delete").length, 1);
});

test("the audit log can't be edited, and rows younger than a year can't be removed", async () => {
  const env = environment();
  await call(env, "/api/admin/announcements", { method: "POST", body: announcement });
  assert.throws(() => env._db.prepare("UPDATE admin_audit_log SET actor = 'x'").run(), /append-only/);
  assert.throws(() => env._db.prepare("DELETE FROM admin_audit_log").run(), /kept for a year/);
  env._db.prepare("INSERT INTO admin_audit_log (at, actor, action) VALUES (?, 'old', 'x')").run(Date.now() - 400 * 86_400_000);
  env._db.prepare("DELETE FROM admin_audit_log WHERE actor = 'old'").run();
  assert.equal(log(env).length, 1);
});

test("an action is refused when the audit log can't be written", async () => {
  const env = environment();
  env._db.exec("DROP TABLE admin_audit_log");
  const created = await call(env, "/api/admin/announcements", { method: "POST", body: announcement }).catch(error => error);
  assert.ok(created instanceof Error || created.status >= 500);
  assert.equal(env._db.prepare("SELECT COUNT(*) AS n FROM announcements").get().n, 0);
});

test("the chat report list shows no message text; opening one shows the copy and is logged", async () => {
  const env = environment();
  const id = seedChatReport(env);
  const list = await (await call(env, "/api/admin/chat-reports")).json();
  assert.equal(list.reports.length, 1);
  assert.ok(!JSON.stringify(list).includes("SECRET"));
  assert.deepEqual(log(env).map(row => row.action), ["chat_report.list"]);

  const detail = await (await call(env, `/api/admin/chat-reports/${id}`)).json();
  assert.equal(detail.messages[0].text, "SECRET");
  assert.deepEqual(log(env).map(row => row.action), ["chat_report.list", "chat_report.view"]);
  assert.ok(!JSON.stringify(log(env)).includes("SECRET"));
});

test("a chat report can be worked: status and note, dismissed allowed, bad values refused", async () => {
  const env = environment();
  const id = seedChatReport(env);
  assert.equal((await call(env, `/api/admin/chat-reports/${id}`, { method: "POST", body: { status: "dismissed", note: "問題なし" } })).status, 200);
  const row = env._db.prepare("SELECT status, admin_note FROM chat_reports WHERE id = ?").get(id);
  assert.deepEqual({ ...row }, { status: "dismissed", admin_note: "問題なし" });
  assert.equal((await call(env, `/api/admin/chat-reports/${id}`, { method: "POST", body: { status: "bogus" } })).status, 400);
  assert.equal((await call(env, `/api/admin/chat-reports/${crypto.randomUUID()}`, { method: "POST", body: { status: "open" } })).status, 404);
  assert.equal((await call(env, `/api/admin/chat-reports?status=dismissed`)).status, 200);
  assert.equal((await call(env, "/api/admin/chat-reports", { token: null })).status, 403);
});

test("reading the problem-report list is logged", async () => {
  const env = environment();
  await call(env, "/api/admin/issue-reports");
  assert.deepEqual(log(env).map(row => row.action), ["issue_report.list"]);
});

test("the retention sweep removes chat reports older than 90 days and keeps newer ones", async () => {
  const env = environment({ PRIVACY_RETENTION_ENABLED: "true", STUDIQUO_DATA: { async list() { return { keys: [], list_complete: true }; }, async get() { return null; }, async put() {}, async delete() {} } });
  const old = seedChatReport(env, { createdAt: Date.now() - 91 * 86_400_000 });
  const fresh = seedChatReport(env);
  await runPrivacyRetention(env);
  const left = env._db.prepare("SELECT id FROM chat_reports").all().map(row => row.id);
  assert.deepEqual(left, [fresh]);
  void old;
});
