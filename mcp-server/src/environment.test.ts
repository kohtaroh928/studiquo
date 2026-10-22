import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { environmentTag, markAdminPage, tagged } from "./environment.ts";
import { handleAdminPage } from "./admin.ts";
import { handleAnnouncementsPage } from "./announcements.ts";
import { markedPayload, postSlackBlocks } from "./slack.ts";
import { sendPush } from "./push.ts";
import { partialEnv } from "./test-env.ts";
import { generateKeyPair, exportPKCS8 } from "jose";

const staging = partialEnv({ ENVIRONMENT_LABEL: "staging", SLACK_ISSUE_REPORT_WEBHOOK_URL: "https://hooks.example.test/slack" });
const production = partialEnv({ SLACK_ISSUE_REPORT_WEBHOOK_URL: "https://hooks.example.test/slack" });
const blocks = [
  { type: "header", text: { type: "plain_text", text: "題名" } },
  { type: "section", text: { type: "mrkdwn", text: "本文" } },
];

test("only a short plain label counts, and production names mean no mark", () => {
  assert.equal(environmentTag({ ENVIRONMENT_LABEL: "staging" }), "STAGING");
  assert.equal(environmentTag({ ENVIRONMENT_LABEL: " Staging " }), "STAGING");
  for (const label of [undefined, "", "production", "PROD", "<script>", "a b", "x".repeat(17), "ステージング"]) {
    assert.equal(environmentTag({ ENVIRONMENT_LABEL: label }), null, String(label));
  }
  assert.equal(tagged({ ENVIRONMENT_LABEL: "staging" }, "件名"), "[STAGING] 件名");
  assert.equal(tagged({}, "件名"), "件名");
});

test("Slack: production's payload is exactly the blocks, untouched", () => {
  assert.deepEqual(markedPayload(production, blocks), { blocks });
});

test("Slack: staging prefixes the header, adds a notice line and a plain-text fallback", () => {
  const payload = markedPayload(staging, blocks) as { blocks: any[]; text: string };
  assert.equal(payload.text, "[STAGING] 題名");
  assert.equal(payload.blocks[0].text.text, "[STAGING] 題名");
  assert.match(payload.blocks[1].elements[0].text, /STAGING環境.*本番ではありません/);
  assert.equal(payload.blocks[2].text.text, "本文");
  assert.equal(blocks[0].text.text, "題名", "the caller's blocks are not modified");
});

test("Slack: staging adds the notice first when a message has no header", () => {
  const payload = markedPayload(staging, [blocks[1]]) as { blocks: any[]; text: string };
  assert.equal(payload.blocks[0].type, "context");
  assert.equal(payload.blocks[1].text.text, "本文");
  assert.equal(payload.text, "[STAGING] studiquo通知");
});

test("Slack: the posted body carries the mark on staging only", async () => {
  const original = globalThis.fetch;
  const bodies: any[] = [];
  globalThis.fetch = (async (_url: any, init: any) => { bodies.push(JSON.parse(init.body)); return new Response("{}"); }) as typeof fetch;
  try {
    await postSlackBlocks(staging, blocks);
    await postSlackBlocks(production, blocks);
  } finally { globalThis.fetch = original; }
  assert.equal(bodies[0].text, "[STAGING] 題名");
  assert.deepEqual(bodies[1], { blocks });
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

test("Slack: a long header still fits Slack's 150-character limit once marked", () => {
  const payload = markedPayload(staging, [{ type: "header", text: { type: "plain_text", text: "あ".repeat(150) } }]) as { blocks: any[] };
  assert.equal(payload.blocks[0].text.text.length, 150);
  assert.ok(payload.blocks[0].text.text.startsWith("[STAGING] "));
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
