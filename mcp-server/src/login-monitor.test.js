import assert from "node:assert/strict";
import test from "node:test";
import { MONITOR, noteSignInContext, recordLoginOutcome, requestContext, touchSeenContext } from "./login-monitor.js";

const DAY = 86_400_000;

test("touchSeenContext: the first context is new and the account has no history", () => {
  const result = touchSeenContext(undefined, "JP|2516", 1_000, 20, 90 * 86_400);
  assert.equal(result.isNew, true);
  assert.equal(result.wasEmpty, true);
});

test("touchSeenContext: a known context isn't new, a different one is", () => {
  let { state } = touchSeenContext(undefined, "JP|2516", 1_000, 20, 90 * 86_400);
  assert.equal(touchSeenContext(state, "JP|2516", 2_000, 20, 90 * 86_400).isNew, false);
  const other = touchSeenContext(state, "US|7922", 2_000, 20, 90 * 86_400);
  assert.equal(other.isNew, true);
  assert.equal(other.wasEmpty, false);
});

test("touchSeenContext: entries expire after the ttl and then count as new again", () => {
  const { state } = touchSeenContext(undefined, "JP|2516", 0, 20, 10);
  const later = touchSeenContext(state, "JP|2516", 11_000, 20, 10);
  assert.equal(later.isNew, true);
  assert.equal(later.wasEmpty, true);
});

test("touchSeenContext: keeps at most maxEntries, evicting the oldest", () => {
  let state;
  for (let i = 0; i < 5; i++) state = touchSeenContext(state, `C|${i}`, i * DAY, 3, 365 * 86_400).state;
  assert.deepEqual(Object.keys(state.entries).sort(), ["C|2", "C|3", "C|4"]);
});

test("requestContext needs both country and ASN, and never exposes the IP", () => {
  const request = (cf, ip = "198.51.100.7") => Object.defineProperty(
    new Request("https://example.test/", { headers: { "cf-connecting-ip": ip } }), "cf", { value: cf }
  );
  assert.equal(requestContext(new Request("https://example.test/")), null);
  assert.equal(requestContext(request({ country: "JP" })), null);
  const context = requestContext(request({ country: "JP", asn: 2516, region: "Tokyo", asOrganization: "KDDI" }));
  assert.deepEqual(context, { key: "JP|2516", country: "JP", region: "Tokyo", network: "KDDI", asn: 2516 });
  assert.ok(!JSON.stringify(context).includes("198.51.100.7"));
});

// MARK: - fakes

function fakeEnv() {
  const counts = new Map();
  const seen = new Map();
  const env = {
    RESEND_API_KEY: "test-key",
    SLACK_ISSUE_REPORT_WEBHOOK_URL: "https://hooks.example.test/slack",
    RATE_COUNTER: {
      getByName(name) {
        return {
          async bump(limit) {
            const used = (counts.get(name) ?? 0) + 1;
            if (used > limit) return false;
            counts.set(name, used);
            return true;
          },
          async seenContext(key, { maxEntries, ttlSeconds }) {
            const result = touchSeenContext(seen.get(name), key, Date.now(), maxEntries, ttlSeconds);
            seen.set(name, result.state);
            return { isNew: result.isNew, wasEmpty: result.wasEmpty };
          },
        };
      },
    },
  };
  return env;
}

function withCf(cf) {
  return Object.defineProperty(new Request("https://example.test/", { headers: { "cf-connecting-ip": "198.51.100.7" } }), "cf", { value: cf });
}

function captureOutbound(run) {
  const original = globalThis.fetch;
  const originalLog = console.log;
  const sent = [];
  const logs = [];
  globalThis.fetch = async (url, init) => { sent.push({ url: String(url), body: JSON.parse(init.body) }); return new Response("{}", { status: 200 }); };
  console.log = line => logs.push(String(line));
  return run(sent, logs).finally(() => { globalThis.fetch = original; console.log = originalLog; });
}

// MARK: - metrics + alerts

test("each outcome is logged as one structured line without the email or IP", () => captureOutbound(async (_sent, logs) => {
  const env = fakeEnv();
  const request = withCf({ country: "JP", asn: 2516 });
  await recordLoginOutcome(env, request, "failure");
  await recordLoginOutcome(env, request, "success", { newContext: true });
  const events = logs.map(line => JSON.parse(line));
  assert.deepEqual(events.map(event => event.outcome), ["failure", "success"]);
  assert.equal(events[1].newContext, true);
  assert.equal(events[0].country, "JP");
  assert.ok(!logs.join("").includes("198.51.100.7"));
}));

test("failures alert Slack exactly once per hour when they cross the threshold", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  const request = withCf({ country: "JP", asn: 2516 });
  for (let i = 0; i < MONITOR.failureAlert; i++) await recordLoginOutcome(env, request, "failure");
  assert.equal(sent.length, 0);
  for (let i = 0; i < 20; i++) await recordLoginOutcome(env, request, "failure");
  assert.equal(sent.length, 1);
  assert.match(JSON.stringify(sent[0].body), /ログイン失敗が急増/);
}));

test("throttled tries are counted apart from failures, so hammering one account can't trip or mask the failure alert", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  const request = withCf({ country: "JP", asn: 2516 });
  for (let i = 0; i < MONITOR.failureAlert + 50; i++) await recordLoginOutcome(env, request, "throttled");
  assert.equal(sent.length, 0);
  for (let i = 0; i <= MONITOR.failureAlert; i++) await recordLoginOutcome(env, request, "failure");
  assert.equal(sent.length, 1);
  assert.match(JSON.stringify(sent[0].body), /ログイン失敗が急増/);
  for (let i = 0; i < MONITOR.throttledAlert; i++) await recordLoginOutcome(env, request, "throttled");
  assert.equal(sent.length, 2);
  assert.match(JSON.stringify(sent[1].body), /待機が多発/);
}));

test("new-context successes alert separately, and ordinary successes never do", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  const request = withCf({ country: "JP", asn: 2516 });
  for (let i = 0; i < 500; i++) await recordLoginOutcome(env, request, "success", { newContext: false });
  assert.equal(sent.length, 0);
  for (let i = 0; i <= MONITOR.newContextSuccessAlert; i++) await recordLoginOutcome(env, request, "success", { newContext: true });
  assert.equal(sent.length, 1);
  assert.match(JSON.stringify(sent[0].body), /未知の環境/);
}));

test("a Slack or counter failure never throws out of recordLoginOutcome", async () => {
  const original = console.error;
  console.error = () => {};
  try {
    await recordLoginOutcome({ RATE_COUNTER: { getByName() { throw new Error("DO down"); } } }, withCf({ country: "JP", asn: 1 }), "failure");
  } finally {
    console.error = original;
  }
});

// MARK: - new-context notice

test("a sign-in from a context the account hasn't used emails the owner, once", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  const home = withCf({ country: "JP", asn: 2516, region: "Tokyo", asOrganization: "KDDI" });
  const abroad = withCf({ country: "RO", asn: 9050, region: "Bucharest", asOrganization: "Some Hosting" });

  // Baseline (sign-up): remembered, no mail.
  assert.deepEqual(await noteSignInContext(env, home, "Person@Example.com", { notify: false }), { newContext: false, firstSeen: true });
  assert.equal(sent.length, 0);

  assert.deepEqual(await noteSignInContext(env, home, "person@example.com", { notify: true }), { newContext: false, firstSeen: false });
  assert.equal(sent.length, 0);

  assert.deepEqual(await noteSignInContext(env, abroad, "person@example.com", { notify: true }), { newContext: true, firstSeen: false });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].body.to, "person@example.com");
  assert.match(sent[0].body.text, /RO \/ Bucharest/);
  assert.match(sent[0].body.text, /Some Hosting/);
  assert.ok(!sent[0].body.text.includes("198.51.100.7"), "the IP address must not be in the mail");

  // Same place again: no second mail.
  await noteSignInContext(env, abroad, "person@example.com", { notify: true });
  assert.equal(sent.length, 1);
}));

test("notice mails are capped per account per day", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  await noteSignInContext(env, withCf({ country: "JP", asn: 1 }), "person@example.com", { notify: false });
  for (let i = 0; i < 10; i++) await noteSignInContext(env, withCf({ country: "US", asn: 100 + i }), "person@example.com", { notify: true });
  assert.equal(sent.length, MONITOR.noticesPerDay);
}));

test("without Cloudflare geo data nothing is recorded or sent", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  assert.deepEqual(await noteSignInContext(env, new Request("https://example.test/"), "person@example.com", { notify: true }), { newContext: false, firstSeen: false });
  assert.equal(sent.length, 0);
}));

test("a failing mail provider is swallowed, doesn't throw, and the context still counts as new", async () => {
  const env = fakeEnv();
  const original = globalThis.fetch;
  const originalError = console.error;
  console.error = () => {};
  globalThis.fetch = async () => new Response("no", { status: 500 });
  try {
    await noteSignInContext(env, withCf({ country: "JP", asn: 1 }), "person@example.com", { notify: false });
    const result = await noteSignInContext(env, withCf({ country: "US", asn: 2 }), "person@example.com", { notify: true });
    assert.deepEqual(result, { newContext: true, firstSeen: false });
  } finally {
    globalThis.fetch = original;
    console.error = originalError;
  }
});

test("an account's first recorded sign-in is still mailed but isn't counted as a new-context spike", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  for (let i = 0; i < MONITOR.newContextSuccessAlert + 5; i++) {
    const result = await noteSignInContext(env, withCf({ country: "JP", asn: 2516 }), `user${i}@example.com`, { notify: true });
    assert.deepEqual(result, { newContext: false, firstSeen: true });
    await recordLoginOutcome(env, withCf({ country: "JP", asn: 2516 }), "success", result);
  }
  const notices = sent.filter(item => item.url.includes("resend"));
  assert.equal(notices.length, MONITOR.newContextSuccessAlert + 5);
  assert.equal(sent.filter(item => item.url.includes("hooks.example")).length, 0, "no spike alert for first-seen sign-ins");
}));

test("without a mail API key the notice is skipped and the daily allowance isn't spent", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  delete env.RESEND_API_KEY;
  await noteSignInContext(env, withCf({ country: "JP", asn: 1 }), "person@example.com", { notify: false });
  await noteSignInContext(env, withCf({ country: "US", asn: 2 }), "person@example.com", { notify: true });
  assert.equal(sent.length, 0);

  env.RESEND_API_KEY = "test-key";
  for (let i = 0; i < MONITOR.noticesPerDay; i++) {
    await noteSignInContext(env, withCf({ country: "DE", asn: 10 + i }), "person@example.com", { notify: true });
  }
  assert.equal(sent.length, MONITOR.noticesPerDay);
}));

test("the network name in the mail is a single short printable line", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  await noteSignInContext(env, withCf({ country: "JP", asn: 1 }), "person@example.com", { notify: false });
  const hostile = `Evil Net\r\n\r\nあなたのパスワードを https://phish.example で確認してください${"x".repeat(200)}`;
  await noteSignInContext(env, withCf({ country: "US", asn: 2, asOrganization: hostile }), "person@example.com", { notify: true });
  assert.equal(sent.length, 1);
  const line = sent[0].body.text.split("\n").find(row => row.startsWith("ネットワーク: "));
  assert.ok(line.length <= "ネットワーク: ".length + 64);
  assert.ok(!/[\r]/.test(line));
  assert.equal(sent[0].body.text.split("\n").filter(row => row.startsWith("ネットワーク")).length, 1);
}));

test("hashing-saturation refusals alert Slack once per hour, separately from failures", () => captureOutbound(async (sent) => {
  const env = fakeEnv();
  const request = withCf({ country: "JP", asn: 2516 });
  for (let i = 0; i < MONITOR.busyAlert; i++) await recordLoginOutcome(env, request, "busy");
  assert.equal(sent.length, 0);
  for (let i = 0; i < 20; i++) await recordLoginOutcome(env, request, "busy");
  assert.equal(sent.length, 1);
  assert.match(JSON.stringify(sent[0].body), /ハッシュ処理の混雑/);

  // They never count towards the failure alert.
  for (let i = 0; i < MONITOR.failureAlert; i++) await recordLoginOutcome(env, request, "busy");
  assert.equal(sent.length, 1);
}));
