import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { environmentTag, isNonProduction, markAdminPage, tagged } from "./environment.ts";
import { handleAdminPage } from "./admin.ts";
import { handleAnnouncementsPage } from "./announcements.ts";
import { sendPush } from "./push.ts";
import { partialEnv } from "./test-env.ts";
import { generateKeyPair, exportPKCS8 } from "jose";


test("only a short plain label counts, and production names mean no mark", () => {
  assert.equal(environmentTag({ ENVIRONMENT_LABEL: "staging" }), "STAGING");
  assert.equal(environmentTag({ ENVIRONMENT_LABEL: " Staging " }), "STAGING");
  for (const label of [undefined, "", "production", "PROD", "<script>", "a b", "x".repeat(17), "ステージング"]) {
    assert.equal(environmentTag({ ENVIRONMENT_LABEL: label }), null, String(label));
  }
  assert.equal(tagged({ ENVIRONMENT_LABEL: "staging" }, "件名"), "[STAGING] 件名");
  assert.equal(tagged({}, "件名"), "件名");
});




test("admin pages: staging gets a banner and a title prefix, production is unchanged", async () => {
  const html = "<title>管理</title><h1>管理</h1>";
  assert.equal(markAdminPage({}, html), html);
  const marked = markAdminPage({ ENVIRONMENT_LABEL: "staging" }, html);
  assert.match(marked, /<title>\[STAGING\] 管理<\/title>/);
  assert.match(marked, /STAGING環境\(本番ではありません\)<\/div>\n<h1>/);
  for (const [handle, path] of [[handleAdminPage, "/admin"], [handleAnnouncementsPage, "/admin/announcements"]] as const) {
    const stagingPage = await handle(new URL(`https://x.test${path}`), { ENVIRONMENT_LABEL: "staging" })!.text();
    const productionPage = await handle(new URL(`https://x.test${path}`), {})!.text();
    assert.match(stagingPage, /<title>\[STAGING\] /);
    assert.match(stagingPage, /STAGING環境\(本番ではありません\)/);
    assert.doesNotMatch(productionPage, /STAGING/);
  }
});

test("push: the title is marked on staging only", async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  const base = { APNS_AUTH_KEY: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY1234567", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.yabuko.studiquo" };
  const device = [{ token: "a".repeat(64), environment: "sandbox", updatedAt: 1 }];
  const titles: string[] = [];
  const options = { devices: device as any, fetchImpl: (async (_u: unknown, init: any) => { titles.push(JSON.parse(init.body).aps.alert.title); return new Response(null, { status: 200 }); }) as typeof fetch };
  await sendPush(partialEnv({ ...base, ENVIRONMENT_LABEL: "staging" }), "user-a", { title: "新着", body: "本文" }, options);
  await sendPush(partialEnv(base), "user-a", { title: "新着", body: "本文" }, options);
  assert.deepEqual(titles, ["[STAGING] 新着", "新着"]);
  await sendPush(partialEnv({ ...base, ENVIRONMENT_LABEL: "staging" }), "user-a", { body: "本文" }, options);
  assert.equal(titles[2], "", "no title means nothing to mark");
});

test("wrangler.jsonc marks the staging Worker only, and keeps credentials out of vars", () => {
  const config = readFileSync(join(import.meta.dirname, "..", "wrangler.jsonc"), "utf8");
  const [production, staging] = config.split(/"staging"\s*:\s*\{/);
  assert.doesNotMatch(production, /ENVIRONMENT_LABEL/);
  assert.match(staging, /"ENVIRONMENT_LABEL"\s*:\s*"staging"/);
  assert.doesNotMatch(config, /"(ACCESS_AUD|ACCESS_TEAM_DOMAIN|APNS_[A-Z_]*KEY[A-Z_]*|REVENUECAT_[A-Z_]*|SLACK_ISSUE_REPORT_WEBHOOK_URL)"\s*:/);
});


test("every rate limit in wrangler.jsonc has its own namespace_id within an environment", () => {
  const config = readFileSync(join(import.meta.dirname, "..", "wrangler.jsonc"), "utf8");
  const [production, staging] = config.split(/"staging"\s*:\s*\{/);
  for (const part of [production, staging]) {
    const ids = [...part.matchAll(/"namespace_id"\s*:\s*"(\d+)"/g)].map(match => match[1]);
    assert.ok(ids.length > 20);
    assert.equal(new Set(ids).size, ids.length, "a shared id would share one counter between two limits");
  }
});

test("a malformed label still counts as non-production, an unset or production one does not", () => {
  for (const label of ["staging", "stg!", "x".repeat(40), "ステージング"]) assert.equal(isNonProduction({ ENVIRONMENT_LABEL: label }), true, label);
  for (const label of [undefined, "", "  ", "production", "PROD"]) assert.equal(isNonProduction({ ENVIRONMENT_LABEL: label }), false, String(label));
});

test("push: staging never sends to a production-environment device, even with a legacy all-environments key", async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  const base = { APNS_AUTH_KEY: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY1234567", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.yabuko.studiquo" };
  const devices = [{ token: "a".repeat(64), environment: "sandbox", updatedAt: 1 }, { token: "b".repeat(64), environment: "production", updatedAt: 2 }];
  const hosts: string[] = [];
  const options = { devices: devices as any, fetchImpl: (async (url: any) => { hosts.push(String(url)); return new Response(null, { status: 200 }); }) as typeof fetch };
  const results = await sendPush(partialEnv({ ...base, ENVIRONMENT_LABEL: "stg!" }), "user-a", { title: "t", body: "b" }, options);
  assert.equal(hosts.length, 1);
  assert.match(hosts[0], /sandbox\.push\.apple\.com/);
  assert.equal(results.find((r: any) => r.token === "b".repeat(64))?.delivered, false);
  hosts.length = 0;
  await sendPush(partialEnv(base), "user-a", { title: "t", body: "b" }, options);
  assert.equal(hosts.length, 2, "production sends to both environments as before");
});
