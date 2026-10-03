import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.js";
import { compareVersions, resolveTranslation, SUPPORTED_LANGUAGES } from "./announcements.js";

class FakeD1Statement {
  constructor(db, sql, params = []) { this.db = db; this.sql = sql; this.params = params; }
  bind(...params) { return new FakeD1Statement(this.db, this.sql, params); }
  async run() { this.db.prepare(this.sql).run(...this.params); return { success: true }; }
  async all() { return { results: this.db.prepare(this.sql).all(...this.params) }; }
  async first() { return this.db.prepare(this.sql).get(...this.params) ?? null; }
}

function environment(extra = {}) {
  const db = new DatabaseSync(":memory:");
  for (const file of ["0001_admin_dashboard.sql", "0003_announcements.sql"]) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  return {
    ADMIN_DB: { prepare: sql => new FakeD1Statement(db, sql) },
    RATE_LIMIT_ANNOUNCEMENTS: { async limit() { return { success: true }; } },
    ...extra,
  };
}

const ctx = { waitUntil() {} };
const call = (env, path, { method = "GET", body, headers = {} } = {}) => worker.fetch(
  new Request(`https://example.test${path}`, {
    method,
    headers: body !== undefined ? { "content-type": "application/json", ...headers } : headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }),
  env, ctx
);

const base = (over = {}) => ({
  kind: "update",
  status: "published",
  translations: { ja: { title: "更新", body: "新機能です" }, en: { title: "Update", body: "New features" } },
  ...over,
});

test("compareVersions compares numerically per component", () => {
  assert.equal(compareVersions("1.10", "1.9"), 1);
  assert.equal(compareVersions("1.2", "1.2.0"), 0);
  assert.equal(compareVersions("1.2.3", "1.3"), -1);
});

test("resolveTranslation: exact, then base language, then en, then ja, then anything", () => {
  const t = { ja: { title: "ja" }, en: { title: "en" }, zh: { title: "zh" }, "pt-BR": { title: "ptBR" } };
  assert.equal(resolveTranslation(t, "pt-BR").lang, "pt-BR");
  assert.equal(resolveTranslation(t, "zh-Hans").lang, "zh");
  assert.equal(resolveTranslation(t, "fr").lang, "en");
  assert.equal(resolveTranslation({ ja: { title: "ja" } }, "fr").lang, "ja");
  assert.equal(resolveTranslation({ de: { title: "de" } }, "fr").lang, "de");
  assert.equal(resolveTranslation(t, "not a code!!").lang, "en");
  assert.equal(resolveTranslation({}, "en"), null);
});

test("admin page and language list expose SUPPORTED_LANGUAGES", async () => {
  const env = environment();
  const page = await call(env, "/admin/announcements");
  assert.equal(page.status, 200);
  const list = await (await call(env, "/api/admin/announcements")).json();
  assert.deepEqual(list.languages, SUPPORTED_LANGUAGES);
  assert.deepEqual(list.announcements, []);
});

test("create validates input", async () => {
  const env = environment();
  const post = body => call(env, "/api/admin/announcements", { method: "POST", body });
  assert.equal((await post(base({ kind: "spam" }))).status, 400);
  assert.equal((await post(base({ status: "nope" }))).status, 400);
  assert.equal((await post(base({ link: "http://insecure.example" }))).status, 400);
  assert.equal((await post(base({ link: "javascript:alert(1)" }))).status, 400);
  assert.equal((await post(base({ minAppVersion: "abc" }))).status, 400);
  assert.equal((await post(base({ minAppVersion: "2.0", maxAppVersion: "1.0" }))).status, 400);
  assert.equal((await post(base({ translations: { en: { title: "t", body: "b" } } }))).status, 400); // ja required
  assert.equal((await post(base({ translations: { ja: { title: "t", body: "" } } }))).status, 400);
  assert.equal((await post(base({ translations: { ja: { title: "t", body: "b" }, "x y": { title: "t", body: "b" } } }))).status, 400);
  assert.equal((await post(base({ translations: { ja: { title: "x".repeat(101), body: "b" } } }))).status, 400);
  assert.equal((await post(base({ publishAt: 2000, expiresAt: 1000 }))).status, 400);
  // An empty extra language is simply skipped.
  const ok = await post(base({ translations: { ja: { title: "t", body: "b" }, en: { title: "", body: "" } } }));
  assert.equal(ok.status, 201);
});

test("public list: only live published items, in the best language, filtered by version", async () => {
  const env = environment();
  const post = body => call(env, "/api/admin/announcements", { method: "POST", body });
  const now = Date.now();
  await post(base());
  await post(base({ status: "draft", translations: { ja: { title: "下書き", body: "x" } } }));
  await post(base({ publishAt: now + 3_600_000, translations: { ja: { title: "予約", body: "x" } } }));
  await post(base({ publishAt: now - 7_200_000, expiresAt: now - 3_600_000, translations: { ja: { title: "期限切れ", body: "x" } } }));
  await post(base({ minAppVersion: "2.0", translations: { ja: { title: "新版のみ", body: "x" } } }));
  await post(base({ translations: { ja: { title: "日本語のみ", body: "x" } }, publishAt: now - 1000 }));

  const en = await (await call(env, "/api/announcements?lang=en&appVersion=1.5")).json();
  assert.deepEqual(en.announcements.map(a => a.title).sort(), ["Update", "日本語のみ"].sort());
  assert.equal(en.announcements.find(a => a.title === "Update").lang, "en");

  const ja = await (await call(env, "/api/announcements?lang=ja")).json();
  assert.ok(ja.announcements.some(a => a.title === "新版のみ")); // no appVersion → no version filter
  assert.ok(ja.announcements.every(a => a.title !== "下書き" && a.title !== "予約" && a.title !== "期限切れ"));

  // Unsupported language falls back (en first, else ja).
  const fr = await (await call(env, "/api/announcements?lang=fr&appVersion=2.1")).json();
  assert.ok(fr.announcements.some(a => a.title === "Update"));
  assert.ok(fr.announcements.some(a => a.title === "日本語のみ"));
});

test("a newly added language is served without code changes beyond the language list", async () => {
  const env = environment();
  await call(env, "/api/admin/announcements", { method: "POST", body: base({
    translations: { ja: { title: "日", body: "b" }, en: { title: "En", body: "b" }, "zh-Hans": { title: "简", body: "b" } },
  }) });
  const zh = await (await call(env, "/api/announcements?lang=zh-Hans")).json();
  assert.equal(zh.announcements[0].title, "简");
});

test("update and delete", async () => {
  const env = environment();
  const { id } = await (await call(env, "/api/admin/announcements", { method: "POST", body: base() })).json();
  const put = await call(env, `/api/admin/announcements/${id}`, { method: "PUT", body: base({ status: "archived" }) });
  assert.equal(put.status, 200);
  assert.equal((await (await call(env, "/api/announcements")).json()).announcements.length, 0);
  assert.equal((await call(env, "/api/admin/announcements/nope", { method: "PUT", body: base() })).status, 404);
  await call(env, `/api/admin/announcements/${id}`, { method: "DELETE" });
  assert.equal((await (await call(env, "/api/admin/announcements")).json()).announcements.length, 0);
});

test("admin API refuses requests without an Access token once Access is configured", async () => {
  const env = environment({ ACCESS_AUD: "aud", ACCESS_TEAM_DOMAIN: "team.cloudflareaccess.com" });
  assert.equal((await call(env, "/api/admin/announcements")).status, 403);
  assert.equal((await call(env, "/api/admin/announcements", { method: "POST", body: base() })).status, 403);
  assert.equal((await call(env, "/api/admin/announcements", { headers: { "cf-access-jwt-assertion": "garbage" } })).status, 403);
  // The public list stays open.
  assert.equal((await call(env, "/api/announcements")).status, 200);
});

test("public list is rate limited", async () => {
  const env = environment({ RATE_LIMIT_ANNOUNCEMENTS: { async limit() { return { success: false }; } } });
  assert.equal((await call(env, "/api/announcements")).status, 429);
});
