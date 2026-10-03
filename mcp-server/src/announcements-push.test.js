import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { generateKeyPair, exportPKCS8, exportJWK, createLocalJWKSet, SignJWT } from "jose";
import { handleAnnouncements } from "./announcements.js";

class FakeD1Statement {
  constructor(db, sql, params = []) { this.db = db; this.sql = sql; this.params = params; }
  bind(...params) { return new FakeD1Statement(this.db, this.sql, params); }
  async run() { const info = this.db.prepare(this.sql).run(...this.params); return { success: true, meta: { changes: info.changes } }; }
  async all() { return { results: this.db.prepare(this.sql).all(...this.params) }; }
  async first() { return this.db.prepare(this.sql).get(...this.params) ?? null; }
}

const ACCESS = { aud: "test-aud", team: "team.cloudflareaccess.com" };
const accessKeys = await generateKeyPair("ES256", { extractable: true });
const accessJWKS = createLocalJWKSet({ keys: [{ ...(await exportJWK(accessKeys.publicKey)), alg: "ES256", use: "sig" }] });
const accessToken = await new SignJWT({}).setProtectedHeader({ alg: "ES256" })
  .setIssuer(`https://${ACCESS.team}`).setAudience(ACCESS.aud).setIssuedAt().setExpirationTime("1h").sign(accessKeys.privateKey);

async function fixture(extra = {}) {
  const db = new DatabaseSync(":memory:");
  for (const file of ["0001_admin_dashboard.sql", "0003_announcements.sql", "0004_announcement_push.sql"]) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  const values = new Map();
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  const env = {
    ADMIN_DB: { prepare: sql => new FakeD1Statement(db, sql) },
    RATE_LIMIT_ANNOUNCEMENTS: { async limit() { return { success: true }; } },
    APNS_AUTH_KEY: await exportPKCS8(privateKey),
    APNS_KEY_ID: "KEY1234567", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.yabuko.studiquo",
    STUDIQUO_DATA: {
      async get(key, type) { const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix, cursor, limit = 1000 }) {
        const all = [...values.keys()].filter(k => k.startsWith(prefix)).sort();
        const start = cursor ? Number(cursor) : 0;
        const page = all.slice(start, start + limit);
        const done = start + page.length >= all.length;
        return { keys: page.map(name => ({ name })), list_complete: done, cursor: done ? undefined : String(start + page.length) };
      },
    },
    ANNOUNCEMENT_PUSH_BATCH: "2",
    ACCESS_AUD: ACCESS.aud, ACCESS_TEAM_DOMAIN: ACCESS.team, ACCESS_JWKS: accessJWKS,
    ...extra,
  };
  return { env, values };
}

const token = n => String(n).repeat(64).slice(0, 64);
function seedUser(values, name, devices) {
  values.set(`chat:devices:${name}`, JSON.stringify(devices));
}

// Records every APNs call: which language's text, which device.
function apns(calls, { failFor = new Set() } = {}) {
  return async (url, init) => {
    const body = JSON.parse(init.body);
    const device = url.split("/").pop();
    calls.push({ device, title: body.aps.alert.title, body: body.aps.alert.body, category: body.aps.category, route: body.route, id: body.announcementID });
    return new Response(failFor.has(device) ? JSON.stringify({ reason: "InternalServerError" }) : null, { status: failFor.has(device) ? 500 : 200 });
  };
}

async function call(env, path, { method = "POST", body, fetchImpl } = {}) {
  const request = new Request(`https://example.test${path}`, {
    method, headers: { "cf-access-jwt-assertion": accessToken, ...(body ? { "content-type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined,
  });
  return handleAnnouncements(new URL(request.url), request, env, { fetchImpl });
}

async function create(env, over = {}) {
  const response = await call(env, "/api/admin/announcements", { body: {
    kind: "update", status: "published",
    translations: { ja: { title: "更新のお知らせ", body: "新機能が増えました" }, en: { title: "Update", body: "New features" } },
    ...over,
  } });
  return (await response.json()).id;
}

async function pushAll(env, id, fetchImpl) {
  let last;
  for (let i = 0; i < 20; i++) {
    const response = await call(env, `/api/admin/announcements/${id}/push`, { fetchImpl });
    last = await response.json();
    if (last.done) return last;
  }
  throw new Error("push never finished");
}

test("push walks every user in batches, in each device's language, honoring the toggle", async () => {
  const { env, values } = await fixture();
  seedUser(values, "u1", [{ token: token(1), environment: "production", language: "ja-JP" }]);
  seedUser(values, "u2", [{ token: token(2), environment: "production", language: "en-US" }]);
  seedUser(values, "u3", [{ token: token(3), environment: "production", language: "fr" }]); // → en
  seedUser(values, "u4", [{ token: token(4), environment: "production", preferences: { announcement: false } }]);
  seedUser(values, "u5", [{ token: token(5), environment: "production" }, { token: token(6), environment: "sandbox", language: "ja" }]); // no language → en
  const id = await create(env);

  const calls = [];
  const result = await pushAll(env, id, apns(calls));
  assert.equal(result.done, true);
  assert.equal(result.users, 5);
  assert.equal(result.delivered, 5);
  assert.equal(calls.length, 5, "u4 opted out");
  const byDevice = Object.fromEntries(calls.map(c => [c.device, c.title]));
  assert.equal(byDevice[token(1)], "更新のお知らせ");
  assert.equal(byDevice[token(2)], "Update");
  assert.equal(byDevice[token(3)], "Update");
  assert.equal(byDevice[token(5)], "Update");
  assert.equal(byDevice[token(6)], "更新のお知らせ");
  assert.ok(calls.every(c => c.category === "studiquo.announcement" && c.route === "announcement" && c.id === id));
});

test("a finished push cannot be sent twice", async () => {
  const { env, values } = await fixture();
  seedUser(values, "u1", [{ token: token(1), environment: "production" }]);
  const id = await create(env);
  const calls = [];
  await pushAll(env, id, apns(calls));
  const again = await call(env, `/api/admin/announcements/${id}/push`, { fetchImpl: apns(calls) });
  assert.equal(again.status, 409);
  assert.equal(calls.length, 1);
  const list = await (await call(env, "/api/admin/announcements", { method: "GET" })).json();
  assert.equal(list.announcements[0].pushState, "sent");
  assert.equal(list.announcements[0].pushDelivered, 1);
});

test("failures are counted and do not stop the walk", async () => {
  const { env, values } = await fixture();
  seedUser(values, "u1", [{ token: token(1), environment: "production" }]);
  seedUser(values, "u2", [{ token: token(2), environment: "production" }]);
  const id = await create(env);
  const result = await pushAll(env, id, apns([], { failFor: new Set([token(1)]) }));
  assert.deepEqual([result.delivered, result.failed], [1, 1]);
});

test("push is refused for news, drafts, scheduled and expired items", async () => {
  const { env } = await fixture();
  const push = async over => (await call(env, `/api/admin/announcements/${await create(env, over)}/push`, { fetchImpl: apns([]) })).status;
  assert.equal(await push({ kind: "news" }), 400);
  assert.equal(await push({ status: "draft" }), 400);
  assert.equal(await push({ publishAt: Date.now() + 3_600_000 }), 400);
  assert.equal(await push({ publishAt: Date.now() - 7_200_000, expiresAt: Date.now() - 3_600_000 }), 400);
  assert.equal((await call(env, "/api/admin/announcements/nope/push", { fetchImpl: apns([]) })).status, 404);
});

test("an overlapping batch request cannot claim the same batch", async () => {
  const { env, values } = await fixture();
  for (let i = 1; i <= 4; i++) seedUser(values, `u${i}`, [{ token: token(i), environment: "production" }]);
  const id = await create(env);

  // Force both requests to read the announcement row before either claims a
  // batch, so both hold the same (stale) batch counter.
  const realPrepare = env.ADMIN_DB.prepare;
  let arrived = 0;
  let release;
  const barrier = new Promise(resolve => { release = resolve; });
  env.ADMIN_DB.prepare = sql => {
    const statement = realPrepare(sql);
    if (!sql.startsWith("SELECT * FROM announcements WHERE id")) return statement;
    return { bind: (...params) => ({ first: async () => {
      const row = await statement.bind(...params).first();
      if (++arrived <= 2) { if (arrived === 2) release(); await barrier; }
      return row;
    } }) };
  };

  const calls = [];
  const [a, b] = await Promise.all([
    call(env, `/api/admin/announcements/${id}/push`, { fetchImpl: apns(calls) }),
    call(env, `/api/admin/announcements/${id}/push`, { fetchImpl: apns(calls) }),
  ]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  assert.equal(calls.length, 2, "only one batch of two users was sent");
  assert.equal(new Set(calls.map(c => c.device)).size, calls.length, "no device was pushed twice");
});

test("test push goes only to the user behind a friend code, marked as a test", async () => {
  const { env, values } = await fixture();
  seedUser(values, "me", [{ token: token(1), environment: "production", language: "en" }]);
  seedUser(values, "other", [{ token: token(2), environment: "production" }]);
  values.set("chat:code:ABC123", "me");
  const id = await create(env, { status: "draft" });
  const calls = [];
  const ok = await call(env, `/api/admin/announcements/${id}/push-test`, { body: { friendCode: "abc123" }, fetchImpl: apns(calls) });
  assert.equal(ok.status, 200);
  assert.deepEqual(calls.map(c => [c.device, c.title]), [[token(1), "[テスト] Update"]]);
  assert.equal((await call(env, `/api/admin/announcements/${id}/push-test`, { body: { friendCode: "ZZZZZZ" }, fetchImpl: apns(calls) })).status, 404);
  assert.equal((await call(env, `/api/admin/announcements/${id}/push-test`, { body: { friendCode: "x" }, fetchImpl: apns(calls) })).status, 400);
  const list = await (await call(env, "/api/admin/announcements", { method: "GET" })).json();
  assert.equal(list.announcements[0].pushState, null, "a test never changes the real push state");
});

test("long bodies are shortened in the notification", async () => {
  const { env, values } = await fixture();
  seedUser(values, "u1", [{ token: token(1), environment: "production" }]);
  const id = await create(env, { translations: { ja: { title: "t", body: "あ".repeat(500) } } });
  const calls = [];
  await pushAll(env, id, apns(calls));
  assert.equal(Array.from(calls[0].body).length, 141);
  assert.ok(calls[0].body.endsWith("…"));
});
