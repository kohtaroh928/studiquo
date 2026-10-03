import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.js";
import { compareVersions } from "./app-errors.js";
import { INBOX_SCRIPT } from "./admin-inbox-ui.js";

// Same shape as admin.test.js's fake: a real in-memory SQLite database built
// from the real migrations, behind the slice of D1's API the Worker uses.
class FakeD1Statement {
  constructor(db, sql, params = []) { this.db = db; this.sql = sql; this.params = params; }
  bind(...params) { return new FakeD1Statement(this.db, this.sql, params); }
  async run() {
    const info = this.db.prepare(this.sql).run(...this.params);
    return { success: true, meta: { changes: info.changes, rows_written: info.changes } };
  }
  async all() { return { results: this.db.prepare(this.sql).all(...this.params), success: true, meta: {} }; }
  async first() { return this.db.prepare(this.sql).get(...this.params) ?? null; }
}

function fakeD1() {
  const db = new DatabaseSync(":memory:");
  for (const file of readdirSync(new URL("../migrations/", import.meta.url)).sort()) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  return { raw: db, prepare(sql) { return new FakeD1Statement(db, sql); } };
}

function fakeCloudflareLimiter(limit = 1000) {
  const counts = new Map();
  return {
    async limit({ key }) {
      const count = (counts.get(key) ?? 0) + 1;
      counts.set(key, count);
      return { success: count <= limit };
    },
  };
}

function environment({ appErrorLimit = 1000 } = {}) {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix, cursor }) {
        const all = [...values.keys()].filter(k => k.startsWith(prefix)).sort();
        const start = cursor ? Number(cursor) : 0;
        const page = all.slice(start, start + 1000);
        const done = start + page.length >= all.length;
        return { keys: page.map(name => ({ name })), list_complete: done, cursor: done ? undefined : String(start + page.length) };
      },
    },
    ADMIN_DB: fakeD1(),
    RATE_LIMIT_APP_ERROR: fakeCloudflareLimiter(appErrorLimit),
    RATE_LIMIT_ISSUE_REPORT: fakeCloudflareLimiter(),
    SLACK_ISSUE_REPORT_WEBHOOK_URL: "https://hooks.slack.test/services/xyz",
  };
}

const noopCtx = { waitUntil() {} };
const freshToken = suffix => `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;

function request(path, { method = "GET", token, body, contentType } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined || contentType) headers["content-type"] = contentType ?? "application/json";
  return new Request(`https://example.test${path}`, {
    method, headers, body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

async function seedSession(env, token, sub) {
  const key = createHash("sha256").update(token).digest("hex");
  await env.STUDIQUO_DATA.put(`session:${key}`, JSON.stringify({ sub, issuedAt: Math.floor(Date.now() / 1000) }));
}

// Captures every Slack post made while `run` executes.
async function withSlack(run) {
  const posts = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    posts.push({ url, body: JSON.parse(init.body) });
    return new Response("ok", { status: 200 });
  };
  try {
    await run();
  } finally {
    globalThis.fetch = original;
  }
  return posts;
}

async function signedInUser(env, name) {
  const token = freshToken(name.slice(0, 1));
  await seedSession(env, token, `user-${name}`);
  return token;
}

async function sendErrors(env, token, errors, extra = {}) {
  return worker.fetch(
    request("/api/app-errors", { method: "POST", token, body: { appVersion: "1.0 (10)", osVersion: "27.0", deviceModel: "iPad14,1", errors, ...extra } }),
    env, noopCtx
  );
}

const crash = (overrides = {}) => ({ kind: "crash", signature: "EXC_BAD_ACCESS|SIGSEGV|studiquo+0x1a2b", title: "EXC_BAD_ACCESS (SIGSEGV)", detail: "frame 0\nframe 1", ...overrides });

async function listErrors(env, query = "?status=all") {
  const response = await worker.fetch(request(`/api/admin/app-errors${query}`), env, noopCtx);
  assert.equal(response.status, 200);
  return (await response.json()).errors;
}

async function listReports(env, query = "?status=all") {
  const response = await worker.fetch(request(`/api/admin/issue-reports${query}`), env, noopCtx);
  assert.equal(response.status, 200);
  return (await response.json()).reports;
}

async function stats(env) {
  const response = await worker.fetch(request("/api/admin/stats"), env, noopCtx);
  return response.json();
}

// MARK: Automatic error reports

test("POST /api/app-errors needs a signed-in token", async () => {
  const env = environment();
  const anonymous = await worker.fetch(request("/api/app-errors", { method: "POST", body: { errors: [crash()] } }), env, noopCtx);
  assert.equal(anonymous.status, 401);
  const unknown = await sendErrors(env, freshToken("z"), [crash()]);
  assert.equal(unknown.status, 401);
  assert.equal((await listErrors(env)).length, 0);
});

test("the same problem becomes one row that counts occurrences and distinct people", async () => {
  const env = environment();
  const alice = await signedInUser(env, "alice");
  const bob = await signedInUser(env, "bob");

  await sendErrors(env, alice, [crash({ count: 2 })]);
  await sendErrors(env, alice, [crash()]);
  await sendErrors(env, bob, [crash()]);

  const rows = await listErrors(env);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].occurrences, 4);
  assert.equal(rows[0].affectedUsers, 2, "Alice reporting twice is still one person");
  assert.equal(rows[0].status, "open");
  assert.equal(rows[0].lastAppVersion, "1.0 (10)");
  assert.equal(rows[0].kind, "crash");
});

test("a different signature or kind is a different problem", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash(), crash({ signature: "other" }), crash({ kind: "hang" })]);
  assert.equal((await listErrors(env)).length, 3);
});

test("Slack hears about a new problem once, not on every repeat", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  const posts = await withSlack(async () => {
    await sendErrors(env, token, [crash()]);
    await sendErrors(env, token, [crash()]);
    await sendErrors(env, token, [crash({ count: 5 })]);
  });
  assert.equal(posts.length, 1);
  const text = JSON.stringify(posts[0].body);
  assert.match(text, /新しいクラッシュ/);
  assert.match(text, /EXC_BAD_ACCESS/);
  assert.match(text, /v1\.0 \(10\)/);
  assert.match(text, /\/admin#errors/);
});

test("a resolved problem reopens only when a newer build hits it again", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash()]);
  const [row] = await listErrors(env);

  const resolve = await worker.fetch(request(`/api/admin/app-errors/${row.fingerprint}`, { method: "POST", body: { status: "resolved" } }), env, noopCtx);
  assert.equal(resolve.status, 200);

  // The fixed build is still not out: an old build keeps hitting it.
  const quiet = await withSlack(async () => {
    await sendErrors(env, token, [crash()]);
    await sendErrors(env, token, [crash()], { appVersion: "1.0 (9)" });
  });
  assert.equal(quiet.length, 0, "old builds must not raise an alarm about a fixed bug");
  assert.equal((await listErrors(env))[0].status, "resolved");
  assert.equal((await listErrors(env))[0].occurrences, 3, "they are still counted");

  const loud = await withSlack(async () => {
    await sendErrors(env, token, [crash()], { appVersion: "1.0 (11)" });
  });
  assert.equal(loud.length, 1);
  assert.match(JSON.stringify(loud[0].body), /再発/);
  const [after] = await listErrors(env);
  assert.equal(after.status, "open");
  assert.equal(after.lastAppVersion, "1.0 (11)");
});

test("a delayed report from an older build doesn't move the latest-build info backwards", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash({ occurredAt: Date.now() - 1_000 })], { appVersion: "1.0 (12)", deviceModel: "iPad16,1" });
  await sendErrors(env, token, [crash({ occurredAt: Date.now() - 86_400_000 })], { appVersion: "1.0 (8)", deviceModel: "iPad7,1" });
  const [row] = await listErrors(env);
  assert.equal(row.lastAppVersion, "1.0 (12)");
  assert.equal(row.lastDeviceModel, "iPad16,1");
  assert.equal(row.occurrences, 2);
  assert.ok(row.firstSeenAt <= row.lastSeenAt);
});

test("each report can carry the version of the build it actually happened on", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash({ appVersion: "0.9 (3)", osVersion: "26.1", deviceModel: "iPad13,1" })]);
  const [row] = await listErrors(env);
  assert.equal(row.lastAppVersion, "0.9 (3)");
  assert.equal(row.lastOSVersion, "26.1");
  assert.equal(row.lastDeviceModel, "iPad13,1");
});

test("a request can't flood the dashboard or Slack", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  const many = Array.from({ length: 30 }, (_, i) => crash({ signature: `sig-${i}` }));
  const posts = await withSlack(async () => {
    const response = await sendErrors(env, token, many);
    assert.equal((await response.json()).accepted, 20);
  });
  assert.equal((await listErrors(env)).length, 20);
  assert.equal(posts.length, 5);
});

test("every field is bounded and unusable entries are dropped", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  const response = await sendErrors(env, token, [
    crash({ title: "t".repeat(1_000), detail: "d".repeat(50_000), signature: "s".repeat(2_000), count: 999_999, occurredAt: Date.now() + 10 * 86_400_000 }),
    { kind: "crash", title: "no signature" },
    { kind: "crash", signature: "no title" },
    "not an object",
    null,
  ]);
  assert.equal((await response.json()).accepted, 1);
  const [row] = await listErrors(env);
  assert.equal(row.title.length, 200);
  assert.equal(row.detail.length, 6_000);
  assert.equal(row.occurrences, 1_000);
  assert.ok(row.lastSeenAt <= Date.now(), "a device clock in the future is not believed");
});

test("an unknown kind is stored as a plain error", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash({ kind: "something-else" })]);
  assert.equal((await listErrors(env))[0].kind, "error");
});

test("a body without an errors list is rejected", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  const response = await worker.fetch(request("/api/app-errors", { method: "POST", token, body: { appVersion: "1" } }), env, noopCtx);
  assert.equal(response.status, 400);
});

test("POST /api/app-errors is rate-limited", async () => {
  const env = environment({ appErrorLimit: 2 });
  const token = await signedInUser(env, "alice");
  assert.equal((await sendErrors(env, token, [crash()])).status, 200);
  assert.equal((await sendErrors(env, token, [crash()])).status, 200);
  assert.equal((await sendErrors(env, token, [crash()])).status, 429);
});

test("version comparison reads marketing version and build together", () => {
  assert.equal(compareVersions("1.0 (11)", "1.0 (10)"), 1);
  assert.equal(compareVersions("1.0 (9)", "1.0 (10)"), -1);
  assert.equal(compareVersions("1.0 (10)", "1.0 (10)"), 0);
  assert.equal(compareVersions("1.1 (1)", "1.0 (99)"), 1);
  assert.equal(compareVersions("1.10 (1)", "1.9 (1)"), 1, "1.10 is newer than 1.9");
  assert.equal(compareVersions("2", "1.9 (5)"), 1);
  assert.equal(compareVersions("", "1.0"), -1);
});

// MARK: Dashboard API for automatic errors

test("the error list filters by status and sorts by recency or by count", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash({ signature: "rare", title: "rare", occurredAt: Date.now() - 5_000 })]);
  await sendErrors(env, token, [crash({ signature: "common", title: "common", count: 50, occurredAt: Date.now() - 9_000 })]);

  assert.deepEqual((await listErrors(env, "?status=open&sort=recent")).map(e => e.title), ["rare", "common"]);
  assert.deepEqual((await listErrors(env, "?status=open&sort=count")).map(e => e.title), ["common", "rare"]);

  const [rare] = await listErrors(env, "?status=open&sort=recent");
  await worker.fetch(request(`/api/admin/app-errors/${rare.fingerprint}`, { method: "POST", body: { status: "in_progress", note: "調査中" } }), env, noopCtx);
  assert.deepEqual((await listErrors(env, "?status=open")).map(e => e.title), ["common"]);
  const working = await listErrors(env, "?status=in_progress");
  assert.equal(working[0].note, "調査中");
  assert.equal((await listErrors(env, "?status=all")).length, 2);
});

test("updating an error validates its input and needs a JSON content type", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash()]);
  const [row] = await listErrors(env);
  const path = `/api/admin/app-errors/${row.fingerprint}`;

  assert.equal((await worker.fetch(request(path, { method: "POST", body: { status: "bogus" } }), env, noopCtx)).status, 400);
  assert.equal((await worker.fetch(request(path, { method: "POST", body: {} }), env, noopCtx)).status, 400);
  assert.equal((await worker.fetch(request(path, { method: "POST", body: { note: 5 } }), env, noopCtx)).status, 400);
  assert.equal((await worker.fetch(request(`/api/admin/app-errors/${"0".repeat(64)}`, { method: "POST", body: { status: "resolved" } }), env, noopCtx)).status, 404);
  // A cross-site form post can't set this content type, so it can't write.
  const form = new Request(`https://example.test${path}`, { method: "POST", headers: { "content-type": "text/plain" }, body: JSON.stringify({ status: "resolved" }) });
  assert.equal((await worker.fetch(form, env, noopCtx)).status, 415);
  assert.equal((await listErrors(env))[0].status, "open");
});

test("the dashboard's open-error count drops when one is resolved", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await sendErrors(env, token, [crash(), crash({ signature: "b" })]);
  assert.equal((await stats(env)).appErrorCount, 2);
  const [row] = await listErrors(env);
  await worker.fetch(request(`/api/admin/app-errors/${row.fingerprint}`, { method: "POST", body: { status: "resolved" } }), env, noopCtx);
  assert.equal((await stats(env)).appErrorCount, 1);
});

// MARK: People's own reports reach the dashboard

test("a problem report shows up in the dashboard inbox and links Slack to it", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  const posts = await withSlack(async () => {
    const response = await worker.fetch(
      request("/api/issue-reports", { method: "POST", token, body: { description: "カレンダーが真っ白", appVersion: "1.0", osVersion: "27.0", deviceModel: "iPad", language: "ja" } }),
      env, noopCtx
    );
    assert.equal(response.status, 200);
  });
  assert.match(JSON.stringify(posts[0].body), /\/admin#reports/);

  const reports = await listReports(env, "?status=open");
  assert.equal(reports.length, 1);
  assert.equal(reports[0].description, "カレンダーが真っ白");
  assert.equal(reports[0].deviceModel, "iPad");
  assert.equal(reports[0].status, "open");
  assert.equal(reports[0].hasScreenshot, false);
  assert.equal((await stats(env)).issueReportCount, 1);
});

test("a report's screenshot is linked from the inbox", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await worker.fetch(
    request("/api/issue-reports", { method: "POST", token, body: { description: "see image", screenshot: { contentType: "image/png", data: "aGVsbG8=" } } }),
    env, noopCtx
  );
  const [report] = await listReports(env);
  assert.equal(report.hasScreenshot, true);
  assert.match(report.screenshotURL, /\/api\/issue-reports\/[0-9a-f-]{36}\/screenshot$/);
});

test("a report can be moved through its statuses with a note", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  await worker.fetch(request("/api/issue-reports", { method: "POST", token, body: { description: "x" } }), env, noopCtx);
  const [report] = await listReports(env);
  const path = `/api/admin/issue-reports/${report.id}`;

  await worker.fetch(request(path, { method: "POST", body: { status: "in_progress", note: "再現中" } }), env, noopCtx);
  assert.equal((await stats(env)).issueReportCount, 0, "a report being worked on is no longer waiting");
  const [working] = await listReports(env, "?status=in_progress");
  assert.equal(working.note, "再現中");

  await worker.fetch(request(path, { method: "POST", body: { status: "resolved" } }), env, noopCtx);
  assert.equal((await listReports(env, "?status=resolved")).length, 1);
  assert.equal((await listReports(env, "?status=resolved"))[0].note, "再現中", "changing only the status keeps the note");

  assert.equal((await worker.fetch(request(path, { method: "POST", body: { status: "nope" } }), env, noopCtx)).status, 400);
  assert.equal((await worker.fetch(request(`/api/admin/issue-reports/${"0".repeat(36)}`, { method: "POST", body: { status: "resolved" } }), env, noopCtx)).status, 404);
});

test("a report that fails to mirror into D1 is still accepted", async () => {
  const env = environment();
  const token = await signedInUser(env, "alice");
  env.ADMIN_DB = { prepare() { throw new Error("D1 is down"); } };
  const originalError = console.error;
  console.error = () => {};
  try {
    const response = await worker.fetch(request("/api/issue-reports", { method: "POST", token, body: { description: "still delivered" } }), env, noopCtx);
    assert.equal(response.status, 200);
    const { id } = await response.json();
    assert.ok(await env.STUDIQUO_DATA.get(`issue-report:${id}`, "json"));
  } finally {
    console.error = originalError;
  }
});

test("reports filed before the inbox existed can be imported once, without touching handled ones", async () => {
  const env = environment();
  const legacy = id => JSON.stringify({ id, reporterKey: "k", description: `legacy ${id}`, appVersion: "0.9", osVersion: "26", deviceModel: "iPad", language: "ja", hasScreenshot: id === "00000000-0000-0000-0000-000000000002", createdAt: 1_700_000_000_000 });
  await env.STUDIQUO_DATA.put("issue-report:00000000-0000-0000-0000-000000000001", legacy("00000000-0000-0000-0000-000000000001"));
  await env.STUDIQUO_DATA.put("issue-report:00000000-0000-0000-0000-000000000002", legacy("00000000-0000-0000-0000-000000000002"));
  await env.STUDIQUO_DATA.put("issue-report-screenshot:00000000-0000-0000-0000-000000000002", JSON.stringify({ contentType: "image/png", data: "" }));
  await env.STUDIQUO_DATA.put("issue-report:broken", "{\"nothing\":true}");

  const first = await worker.fetch(request("/api/admin/issue-reports/import-legacy", { method: "POST", body: {} }), env, noopCtx);
  assert.deepEqual(await first.json(), { imported: 2, skipped: 1 });
  const reports = await listReports(env);
  assert.equal(reports.length, 2);
  assert.equal(reports[0].createdAt, 1_700_000_000_000);
  assert.equal(reports.find(r => r.id.endsWith("2")).hasScreenshot, true);

  const handled = reports[0];
  await worker.fetch(request(`/api/admin/issue-reports/${handled.id}`, { method: "POST", body: { status: "resolved", note: "done" } }), env, noopCtx);
  const second = await worker.fetch(request("/api/admin/issue-reports/import-legacy", { method: "POST", body: {} }), env, noopCtx);
  assert.deepEqual(await second.json(), { imported: 0, skipped: 3 });
  const after = (await listReports(env)).find(r => r.id === handled.id);
  assert.equal(after.status, "resolved");
  assert.equal(after.note, "done");
});

test("importing needs a JSON content type like every other write", async () => {
  const env = environment();
  const response = await worker.fetch(new Request("https://example.test/api/admin/issue-reports/import-legacy", { method: "POST", headers: { "content-type": "text/plain" }, body: "x" }), env, noopCtx);
  assert.equal(response.status, 415);
});

// MARK: The page

test("the dashboard page has both inbox tabs and the cards link to them", async () => {
  const response = await worker.fetch(request("/admin"), environment(), noopCtx);
  const html = await response.text();
  assert.match(html, /id="tab-reports"/);
  assert.match(html, /id="tab-errors"/);
  assert.match(html, /count-reports/);
  assert.match(html, /#errors/);
});

test("the inbox script never writes outside text into the page as markup", () => {
  // A report's text and a crash's symbols are untrusted: they may only reach
  // the page through textContent / .value, never innerHTML.
  assert.doesNotMatch(INBOX_SCRIPT, /innerHTML|insertAdjacentHTML|document\.write|outerHTML/);
});
