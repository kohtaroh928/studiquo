import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.js";
import { PRODUCT_BILLING_MONTHS } from "./admin.js";

// Wraps a real in-memory SQLite database (seeded from the actual migration
// file, so tests run against the real schema) in the shape D1 exposes to a
// Worker: prepare(sql).bind(...params).run()/.all()/.first().
class FakeD1Statement {
  constructor(db, sql, params = []) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }
  bind(...params) { return new FakeD1Statement(this.db, this.sql, params); }
  async run() {
    const info = this.db.prepare(this.sql).run(...this.params);
    return { success: true, meta: { changes: info.changes, rows_written: info.changes, last_row_id: info.lastInsertRowid } };
  }
  async all() {
    return { results: this.db.prepare(this.sql).all(...this.params), success: true, meta: {} };
  }
  async first() {
    return this.db.prepare(this.sql).get(...this.params) ?? null;
  }
}

function fakeD1() {
  const db = new DatabaseSync(":memory:");
  for (const file of readdirSync(new URL("../migrations/", import.meta.url)).sort()) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  return { prepare(sql) { return new FakeD1Statement(db, sql); } };
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

const WEBHOOK_SECRET = "test-shared-secret";

function environment() {
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
    RATE_LIMIT_ADMIN_WEBHOOK: fakeCloudflareLimiter(),
    RATE_LIMIT_USAGE_EVENT: fakeCloudflareLimiter(),
    REVENUECAT_WEBHOOK_SECRET: WEBHOOK_SECRET,
    _kv: values,
  };
}

const noopCtx = { waitUntil() {} };

function freshToken(suffix) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;
}

function request(path, { method = "GET", token, body, authorization } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (authorization !== undefined) headers.authorization = authorization;
  if (body !== undefined) headers["content-type"] = "application/json";
  return new Request(`https://example.test${path}`, {
    method, headers, body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

async function seedSession(env, token, sub) {
  const { createHash } = await import("node:crypto");
  const key = createHash("sha256").update(token).digest("hex");
  await env.STUDIQUO_DATA.put(`session:${key}`, JSON.stringify({ sub, issuedAt: Math.floor(Date.now() / 1000) }));
}

async function sendWebhook(env, event, authorization = WEBHOOK_SECRET) {
  return worker.fetch(
    request("/api/admin/revenuecat-webhook", { method: "POST", authorization, body: { event } }),
    env, noopCtx
  );
}

function purchaseEvent(overrides = {}) {
  return {
    id: crypto.randomUUID(),
    app_user_id: "user-1",
    type: "INITIAL_PURCHASE",
    period_type: "NORMAL",
    product_id: "studiquo_pro_monthly",
    price_in_purchased_currency: 9.99,
    currency: "USD",
    environment: "PRODUCTION",
    event_timestamp_ms: Date.now(),
    expiration_at_ms: Date.now() + 30 * 24 * 60 * 60 * 1000,
    ...overrides,
  };
}

async function stats(env) {
  const response = await worker.fetch(request("/api/admin/stats"), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

test("a webhook with a missing/wrong Authorization header is rejected with 401", async () => {
  const env = environment();
  const wrong = await sendWebhook(env, purchaseEvent(), "wrong-secret");
  assert.equal(wrong.status, 401);
  const missing = await worker.fetch(
    new Request("https://example.test/api/admin/revenuecat-webhook", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ event: purchaseEvent() }),
    }),
    env, noopCtx
  );
  assert.equal(missing.status, 401);
});

test("a webhook with a malformed event body is rejected with 400", async () => {
  const env = environment();
  const response = await sendWebhook(env, { type: "INITIAL_PURCHASE" }); // no id/app_user_id
  assert.equal(response.status, 400);
});

test("an INITIAL_PURCHASE webhook is logged and makes the subscriber active", async () => {
  const env = environment();
  const response = await sendWebhook(env, purchaseEvent());
  assert.equal(response.status, 200);

  const data = await stats(env);
  assert.equal(data.activeSubscribers, 1);
  assert.equal(data.monthToDate.revenue, 9.99);
});

test("the same event id delivered twice is only recorded once", async () => {
  const env = environment();
  const event = purchaseEvent();
  await sendWebhook(env, event);
  await sendWebhook(env, event); // RevenueCat-style retry of the same event

  const data = await stats(env);
  assert.equal(data.monthToDate.revenue, 9.99); // not double-counted
});

test("an EXPIRATION event moves a subscriber from active to expired", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "user-2" }));
  assert.equal((await stats(env)).activeSubscribers, 1);

  await sendWebhook(env, purchaseEvent({ id: crypto.randomUUID(), app_user_id: "user-2", type: "EXPIRATION" }));
  assert.equal((await stats(env)).activeSubscribers, 0);
});

test("a BILLING_ISSUE event is reflected as a billing-issue subscriber, not counted as active", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "user-3" }));
  await sendWebhook(env, purchaseEvent({ id: crypto.randomUUID(), app_user_id: "user-3", type: "BILLING_ISSUE" }));

  const data = await stats(env);
  assert.equal(data.billingIssueCount, 1);
  assert.equal(data.activeSubscribers, 0);
});

test("a CANCELLATION event alone does not deactivate a subscriber", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "user-4" }));
  await sendWebhook(env, purchaseEvent({ id: crypto.randomUUID(), app_user_id: "user-4", type: "CANCELLATION" }));

  assert.equal((await stats(env)).activeSubscribers, 1);
});

test("SANDBOX events are stored but excluded from revenue and refund totals", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ environment: "SANDBOX" }));
  const data = await stats(env);
  assert.equal(data.monthToDate.revenue, 0);
});

test("a REFUND is reflected in this month's refund count/total", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "user-5" }));
  await sendWebhook(env, purchaseEvent({
    id: crypto.randomUUID(), app_user_id: "user-5", type: "REFUND", price_in_purchased_currency: 9.99,
  }));

  const data = await stats(env);
  assert.equal(data.monthToDate.refundCount, 1);
  assert.equal(data.monthToDate.refundTotal, 9.99);
  assert.equal(data.activeSubscribers, 0); // REFUND also deactivates
});

test("trial conversion counts a trial starter as converted once a NORMAL renewal follows", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "trial-user", period_type: "TRIAL", price_in_purchased_currency: 0 }));
  let data = await stats(env);
  assert.equal(data.trialConversion.starters, 1);
  assert.equal(data.trialConversion.converted, 0);

  await sendWebhook(env, purchaseEvent({
    id: crypto.randomUUID(), app_user_id: "trial-user", type: "RENEWAL", period_type: "NORMAL",
  }));
  data = await stats(env);
  assert.equal(data.trialConversion.starters, 1);
  assert.equal(data.trialConversion.converted, 1);
  assert.equal(data.trialConversion.rate, 1);
});

test("MRR normalizes an annual product's price to a monthly-equivalent using PRODUCT_BILLING_MONTHS", async () => {
  const env = environment();
  PRODUCT_BILLING_MONTHS.studiquo_pro_annual = 12;
  try {
    await sendWebhook(env, purchaseEvent({ app_user_id: "annual-user", product_id: "studiquo_pro_annual", price_in_purchased_currency: 120 }));
    const data = await stats(env);
    assert.equal(data.mrr, 10); // 120 / 12 months
  } finally {
    delete PRODUCT_BILLING_MONTHS.studiquo_pro_annual;
  }
});

test("an unmapped product defaults to monthly (months=1) rather than being dropped from MRR", async () => {
  const env = environment();
  await sendWebhook(env, purchaseEvent({ app_user_id: "unmapped-user", product_id: "unknown_product", price_in_purchased_currency: 5 }));
  const data = await stats(env);
  assert.equal(data.mrr, 5);
});

test("POST /api/usage-events without a token is rejected with 401", async () => {
  const env = environment();
  const response = await worker.fetch(request("/api/usage-events", { method: "POST" }), env, noopCtx);
  assert.equal(response.status, 401);
});

test("a recorded usage event counts toward DAU and MAU", async () => {
  const env = environment();
  const token = freshToken("u1");
  await seedSession(env, token, "student-1");

  const response = await worker.fetch(request("/api/usage-events", { method: "POST", token }), env, noopCtx);
  assert.equal(response.status, 200);

  const data = await stats(env);
  assert.equal(data.dau, 1);
  assert.equal(data.mau, 1);
});

// Regression coverage for the identity-key fix in handleUsageEvent: a
// token's own hash used to be the user_key directly, which meant a
// re-login (a brand-new token, same person) looked like a second, distinct
// user to DAU/MAU and reset their retention cohort. The key is now derived
// from the session's account (`sub`) instead, so it must stay the same
// person across tokens.
test("re-logging in (a new token for the same account) is still counted as the same user, not a second one", async () => {
  const env = environment();
  const firstToken = freshToken("u3a");
  const secondToken = freshToken("u3b");
  await seedSession(env, firstToken, "student-3");
  await seedSession(env, secondToken, "student-3");

  const first = await worker.fetch(request("/api/usage-events", { method: "POST", token: firstToken }), env, noopCtx);
  assert.equal(first.status, 200);
  const second = await worker.fetch(request("/api/usage-events", { method: "POST", token: secondToken }), env, noopCtx);
  assert.equal(second.status, 200);

  const data = await stats(env);
  assert.equal(data.dau, 1, "同じアカウントの2つのトークンは、1人として数えられる必要があります。");
  assert.equal(data.mau, 1);
});

// Two genuinely different accounts must still be counted separately —
// the fix must not accidentally collapse everyone into one key.
test("two different accounts are counted as two separate users", async () => {
  const env = environment();
  const tokenA = freshToken("u4a");
  const tokenB = freshToken("u4b");
  await seedSession(env, tokenA, "student-4a");
  await seedSession(env, tokenB, "student-4b");

  await worker.fetch(request("/api/usage-events", { method: "POST", token: tokenA }), env, noopCtx);
  await worker.fetch(request("/api/usage-events", { method: "POST", token: tokenB }), env, noopCtx);

  const data = await stats(env);
  assert.equal(data.dau, 2);
  assert.equal(data.mau, 2);
});

test("retention is null for a day-offset with no cohort old enough yet", async () => {
  const env = environment();
  const token = freshToken("u2");
  await seedSession(env, token, "student-2");
  await worker.fetch(request("/api/usage-events", { method: "POST", token }), env, noopCtx);

  // This user was "first seen" moments ago — not old enough for D7/D30 cohorts.
  const data = await stats(env);
  assert.equal(data.retention.d7, null);
  assert.equal(data.retention.d30, null);
});

test("account count deduplicates linked identities but keeps unrelated ones separate", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("account:apple-sub-1", JSON.stringify({ sub: "apple-sub-1", email: "same@example.com", emailIsPrivateRelay: false }));
  await env.STUDIQUO_DATA.put("account:google:google-sub-1", JSON.stringify({ sub: "google-sub-1", email: "same@example.com" }));
  await env.STUDIQUO_DATA.put("account:local:other@example.com", JSON.stringify({ email: "other@example.com" }));
  await env.STUDIQUO_DATA.put("account:apple-sub-2", JSON.stringify({ sub: "apple-sub-2", email: "hidden@privaterelay.appleid.com", emailIsPrivateRelay: true }));

  const data = await stats(env);
  // apple-sub-1 + google-sub-1 share an email -> 1 person.
  // other@example.com -> 1 person. The private-relay account -> its own person.
  assert.equal(data.userCount, 3);
});

test("the issue report count is the reports still open, not everything ever filed", async () => {
  const env = environment();
  const insert = (id, status) => env.ADMIN_DB.prepare(
    `INSERT INTO issue_reports (id, reporter_key, description, status, created_at, updated_at) VALUES (?, 'k', 'd', ?, 1, 1)`
  ).bind(id, status).run();
  await insert("report-open", "open");
  await insert("report-working", "in_progress");
  await insert("report-done", "resolved");
  // Screenshots and legacy KV copies don't count on their own.
  await env.STUDIQUO_DATA.put("issue-report:legacy", JSON.stringify({ id: "legacy" }));
  await env.STUDIQUO_DATA.put("issue-report-screenshot:legacy", JSON.stringify({ contentType: "image/png", data: "" }));

  const data = await stats(env);
  assert.equal(data.issueReportCount, 1);
});

test("MCP connection count reflects mcp:grant: entries in KV", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("mcp:grant:abc:def", JSON.stringify({ clientName: "Claude" }));
  await env.STUDIQUO_DATA.put("mcp:grant:abc:ghi", JSON.stringify({ clientName: "Other" }));

  const data = await stats(env);
  assert.equal(data.mcpConnectionCount, 2);
});

test("the webhook endpoint is rate-limited", async () => {
  const env = environment();
  env.RATE_LIMIT_ADMIN_WEBHOOK = fakeCloudflareLimiter(3);
  let last;
  for (let i = 0; i < 4; i += 1) {
    last = await sendWebhook(env, purchaseEvent({ id: crypto.randomUUID() }));
  }
  assert.equal(last.status, 429);
});

test("GET /admin serves the dashboard page", async () => {
  const env = environment();
  const response = await worker.fetch(request("/admin"), env, noopCtx);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/html/);
  assert.match(await response.text(), /studiquo 管理ダッシュボード/);
});
