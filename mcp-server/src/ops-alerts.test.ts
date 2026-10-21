import assert from "node:assert/strict";
import test from "node:test";
import { OPS_ALERTS, countAndAlert, raiseAlert } from "./ops-alerts.ts";
import { partialEnv } from "./test-env.ts";

function fakeEnv({ webhook = "https://hooks.example.test/slack", broken = false } = {}) {
  const counts = new Map<string, number>();
  return partialEnv({
    SLACK_ISSUE_REPORT_WEBHOOK_URL: webhook || undefined,
    RATE_COUNTER: {
      getByName(name: string) {
        return {
          async bump(limit: number) {
            if (broken) throw new Error("counter unavailable");
            const used = (counts.get(name) ?? 0) + 1;
            if (used > limit) return false;
            counts.set(name, used);
            return true;
          },
        };
      },
    },
  });
}

async function captureSlack(run: (sent: any[]) => Promise<void>) {
  const original = globalThis.fetch;
  const originalError = console.error;
  const sent: any[] = [];
  globalThis.fetch = (async (url: any, init: any) => { sent.push({ url: String(url), body: JSON.parse(init.body) }); return new Response("{}"); }) as typeof fetch;
  console.error = () => {};
  try { await run(sent); } finally { globalThis.fetch = original; console.error = originalError; }
}

test("an alert fires once, on the event after the threshold, and stays quiet for the rest of the hour", () => captureSlack(async sent => {
  const env = fakeEnv();
  for (let i = 0; i < 3; i++) await countAndAlert(env, "t:x", 3, "題名", "本文");
  assert.equal(sent.length, 0, "at the threshold nothing is sent");
  for (let i = 0; i < 10; i++) await countAndAlert(env, "t:x", 3, "題名", "本文");
  assert.equal(sent.length, 1);
  assert.match(JSON.stringify(sent[0].body), /題名/);
}));

test("threshold 0 alerts on the first event, once an hour", () => captureSlack(async sent => {
  const env = fakeEnv();
  for (let i = 0; i < 5; i++) await raiseAlert(env, OPS_ALERTS.retentionBacklog);
  assert.equal(sent.length, 1);
}));

test("different alerts count apart", () => captureSlack(async sent => {
  const env = fakeEnv();
  await raiseAlert(env, OPS_ALERTS.retentionBacklog);
  await raiseAlert(env, OPS_ALERTS.providerDeletionKey);
  assert.equal(sent.length, 2);
}));

test("raiseAlert never throws, even when the counter is down", () => captureSlack(async sent => {
  await raiseAlert(fakeEnv({ broken: true }), OPS_ALERTS.serverError);
  assert.equal(sent.length, 0);
}));

test("with no Slack webhook configured nothing is sent and nothing fails", () => captureSlack(async sent => {
  const env = fakeEnv({ webhook: "" });
  await raiseAlert(env, OPS_ALERTS.retentionBacklog);
  assert.equal(sent.length, 0);
}));

test("no alert text carries an address, token or other personal value", () => {
  for (const alert of Object.values(OPS_ALERTS)) {
    assert.ok(!/@|Bearer|token=|password/i.test(alert.title + alert.detail.replace(/リフレッシュトークン|MCPのリフレッシュ/g, "")), alert.counter);
    assert.ok(alert.threshold >= 0 && alert.detail.length > 20);
  }
});
