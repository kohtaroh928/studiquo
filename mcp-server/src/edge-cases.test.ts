// The small edges of several modules, each one a path that fails closed or fails
// quietly: a refused address, a service that answers with junk, an alert that can't
// be sent. They are grouped here by being short, not by sharing a subject.
import assert from "node:assert/strict";
import test from "node:test";
import { checkRateLimit, normalizeIP } from "./rate-limit.ts";
import { handleInvitePage } from "./invite.ts";
import { moderationRejection, MODERATION_UNAVAILABLE } from "./openai.ts";
import { retryRevenueCatDeletion } from "./privacy-retention.ts";
import { trustPair, trustExpiryMs } from "./login-throttle.ts";
import { sendPasskeyNotice } from "./passkey-policy.ts";
import { noteSignInContext } from "./login-monitor.ts";
import { handleDeviceRoutes } from "./devices.ts";
import { partialEnv, type Untyped } from "./test-env.ts";

const silenced = async <T>(run: () => Promise<T>) => {
  const [error, warn] = [console.error, console.warn];
  console.error = () => {}; console.warn = () => {};
  try { return await run(); } finally { console.error = error; console.warn = warn; }
};

// Replaces fetch for the length of one test and records what was asked.
async function withFetch<T>(answer: (url: string, init?: Untyped) => Response | Promise<Response>, run: (calls: { url: string; init?: Untyped }[]) => Promise<T>) {
  const real = globalThis.fetch;
  const calls: { url: string; init?: Untyped }[] = [];
  globalThis.fetch = (async (url: unknown, init?: Untyped) => { calls.push({ url: String(url), init }); return answer(String(url), init); }) as typeof fetch;
  try { return await run(calls); } finally { globalThis.fetch = real; }
}

// ---- rate-limit.ts ----

test("checkRateLimit answers with the binding's verdict for the given key, and only that key", async () => {
  const asked: unknown[] = [];
  const binding = (success: boolean) => ({ async limit(arg: unknown) { asked.push(arg); return { success }; } }) as unknown as RateLimit;
  assert.equal(await checkRateLimit(binding(true), "user-1"), true);
  assert.equal(await checkRateLimit(binding(false), "user-2"), false);
  assert.deepEqual(asked, [{ key: "user-1" }, { key: "user-2" }]);
});

test("an IPv6 address with a dotted IPv4 tail is read as its two last groups; an impossible tail is returned as it came", () => {
  assert.equal(normalizeIP("64:ff9b::192.0.2.1"), "64:ff9b:0:0::/64");
  assert.equal(normalizeIP("64:ff9b::192.0.2.1"), normalizeIP("64:ff9b::c000:201"));
  assert.equal(normalizeIP("64:ff9b::192.0.2.999"), "64:ff9b::192.0.2.999");
  assert.equal(normalizeIP("1.2.3.999"), "1.2.3.999", "an IPv4-looking value is never rewritten");
  assert.equal(normalizeIP("  203.0.113.5  "), "203.0.113.5", "surrounding spaces are dropped");
});

// ---- invite.ts ----

test("the invite page is only served at /invite, refuses a malformed token, and never runs a script", async () => {
  assert.equal(handleInvitePage(new URL("https://example.test/other?token=ABCDEF")), null);
  for (const token of ["", "abc", "a".repeat(33), "ABC DEF", "ABC<script>", "ABC%22onmouseover%3D"]) {
    const response = handleInvitePage(new URL(`https://example.test/invite?token=${encodeURIComponent(token)}`))!;
    assert.equal(response.status, 400, JSON.stringify(token));
  }
  const ok = handleInvitePage(new URL("https://example.test/invite?token=ABCDEF1234"))!;
  assert.equal(ok.status, 200);
  assert.match(ok.headers.get("content-security-policy")!, /script-src 'none'/);
  const html = await ok.text();
  assert.ok(html.includes('href="studiquo://friend/add?token=ABCDEF1234"'));
  assert.ok(!/<script/i.test(html), "the token is handed over by a tap, not a script");
});

// ---- openai.ts: moderation fails closed ----

test("moderation: an error status, an unreadable answer or a failed request means unavailable, never allowed", async () => {
  const env = partialEnv({ OPENAI_API_KEY: "test-key" });
  for (const answer of [
    () => new Response("", { status: 500 }),
    () => Response.json({}),
    () => Response.json({ results: [] }),
    () => Response.json({ results: "yes" }),
    () => Response.json(null),
    () => { throw new Error("offline"); },
  ]) {
    const result = await silenced(() => withFetch(answer as () => Response, () => moderationRejection(env, ["こんにちは"])));
    assert.equal(result, MODERATION_UNAVAILABLE);
  }
});

test("moderation: flagged text is refused in Japanese, but a self-harm flag alone is let through", async () => {
  const env = partialEnv({ OPENAI_API_KEY: "test-key" });
  const answer = (categories: Record<string, boolean>) => () => Response.json({ results: [{ categories }] });
  const refused = await withFetch(answer({ violence: true }), () => moderationRejection(env, ["x"]));
  assert.equal(typeof refused, "string");
  assert.match(refused as string, /この内容は学習アプリでは扱えません/);
  assert.equal(await withFetch(answer({ "self-harm": true, "self-harm/intent": true }), () => moderationRejection(env, ["x"])), null);
  assert.equal(await withFetch(answer({ violence: false, hate: false }), () => moderationRejection(env, ["x"])), null);
  const mixed = await withFetch(answer({ "self-harm": true, harassment: true }), () => moderationRejection(env, ["x"]));
  assert.equal(typeof mixed, "string", "another flag alongside self-harm still refuses");
});

test("moderation: any one flagged text among several refuses; the request carries only non-empty text, split into pieces of at most 8000 characters", async () => {
  const env = partialEnv({ OPENAI_API_KEY: "test-key" });
  let sent: Untyped;
  const result = await withFetch((_url, init) => {
    sent = JSON.parse(init!.body);
    return Response.json({ results: [{ categories: {} }, { categories: {} }, { categories: { sexual: true } }] });
  }, () => moderationRejection(env, ["あ".repeat(9000), "", "b"]));
  assert.equal(typeof result, "string");
  assert.deepEqual(sent.input.map((piece: string) => piece.length), [8000, 1000, 1], "nothing past the first 8000 characters goes unchecked");
  assert.equal(sent.model, "omni-moderation-latest");
});

test("moderation: with the switch off, no key or nothing to check, nothing is asked and nothing is refused", async () => {
  const asked = async (env: Untyped, texts: string[], key?: string) =>
    withFetch(() => Response.json({ results: [{ categories: { violence: true } }] }), async calls => ({ result: await moderationRejection(partialEnv(env), texts, key), calls: calls.length }));
  assert.deepEqual(await asked({ OPENAI_API_KEY: "k", AI_MODERATION: "off" }, ["x"]), { result: null, calls: 0 });
  assert.deepEqual(await asked({}, ["x"]), { result: null, calls: 0 });
  assert.deepEqual(await asked({ OPENAI_API_KEY: "k" }, ["", "", undefined as unknown as string]), { result: null, calls: 0 });
  assert.deepEqual(await asked({ OPENAI_API_KEY: "k" }, []), { result: null, calls: 0 });
  assert.deepEqual(await asked({}, ["x"], "explicit-key"), { result: "この内容は学習アプリでは扱えません。表現を変えて、もう一度送信してください。", calls: 1 }, "an explicit key is used even when the env has none");
});

// ---- privacy-retention.ts ----

test("a RevenueCat erasure job: no key keeps it, 404 counts as erased, another failure keeps it for the next sweep", async () => {
  const values = new Map([["privacy-revenuecat:a", JSON.stringify({ identity: "user@example.test" })]]);
  const base = { STUDIQUO_DATA: { async delete(key: string) { values.delete(key); } } };
  const job = { identity: "user/with space" };
  const fetchWith = (status: number) => (async () => new Response("{}", { status })) as unknown as typeof fetch;

  assert.equal(await retryRevenueCatDeletion(partialEnv(base), "privacy-revenuecat:a", job, fetchWith(200)), false, "no secret configured");
  assert.equal(values.size, 1);

  const env = partialEnv({ ...base, REVENUECAT_SECRET_API_KEY: "sk_test" });
  assert.equal(await retryRevenueCatDeletion(env, "privacy-revenuecat:a", job, fetchWith(500)), false);
  assert.equal(values.size, 1, "a failed attempt is retried later");
  assert.equal(await retryRevenueCatDeletion(env, "privacy-revenuecat:a", job, fetchWith(404)), true);
  assert.equal(values.size, 0, "a customer that is already gone is done");
});

test("the RevenueCat erasure request names the subscriber, escaped, with the secret in the header only", async () => {
  const env = partialEnv({ STUDIQUO_DATA: { async delete() {} }, REVENUECAT_SECRET_API_KEY: "sk_test" });
  let seen: { url: string; init: Untyped } | undefined;
  const fetcher = (async (url: string, init: Untyped) => { seen = { url, init }; return new Response(null, { status: 200 }); }) as unknown as typeof fetch;
  await retryRevenueCatDeletion(env, "k", { identity: "a/b c" }, fetcher);
  assert.equal(seen!.url, "https://api.revenuecat.com/v1/subscribers/a%2Fb%20c");
  assert.equal(seen!.init.method, "DELETE");
  assert.equal(seen!.init.headers.authorization, "Bearer sk_test");
  assert.ok(!seen!.url.includes("sk_test"));
});

// ---- login-throttle.ts ----

test("a trusted pair has no failures and no wait, and its expiry is read back; no state means no trust", () => {
  const trusted = trustPair({ failures: 9, blockedUntil: 5_000 }, 1_000);
  assert.equal(trusted.failures, 0);
  assert.equal(trusted.blockedUntil, 0);
  assert.equal(trusted.lastFailureAt, 1_000);
  assert.ok(trusted.trustedUntil > 1_000);
  assert.equal(trustExpiryMs(trusted), trusted.trustedUntil);
  assert.equal(trustExpiryMs(null), 0);
  assert.equal(trustExpiryMs(undefined), 0);
  assert.equal(trustExpiryMs({ failures: 3 }), 0);
});

// ---- passkey-policy.ts ----

test("a passkey notice is sent through Resend with the lines as the body, and from the default sender when none is set", async () => {
  const env = partialEnv({ RESEND_API_KEY: "re_test" });
  await withFetch(() => new Response("{}", { status: 200 }), async calls => {
    await sendPasskeyNotice(env, "me@example.test", "件名", ["一行目", "二行目"]);
    assert.equal(calls.length, 1);
    const body = JSON.parse(calls[0].init!.body);
    assert.deepEqual([body.to, body.subject, body.text], ["me@example.test", "件名", "一行目\n二行目"]);
    assert.match(body.from, /onboarding@resend\.dev/);
    assert.equal(calls[0].init!.headers.Authorization, "Bearer re_test");
  });
  await withFetch(() => new Response("{}", { status: 200 }), async calls => {
    await sendPasskeyNotice(partialEnv({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "Studiquo <no-reply@example.test>" }), "me@example.test", "s", []);
    assert.equal(JSON.parse(calls[0].init!.body).from, "Studiquo <no-reply@example.test>");
  });
});

test("a passkey notice that can't be sent never raises: Resend refusing, the network failing, or nothing to send it with", async () => {
  await silenced(async () => {
    await withFetch(() => new Response("no", { status: 422 }), async () => {
      await sendPasskeyNotice(partialEnv({ RESEND_API_KEY: "k" }), "me@example.test", "s", ["x"]);
    });
    await withFetch(() => { throw new Error("offline"); }, async () => {
      await sendPasskeyNotice(partialEnv({ RESEND_API_KEY: "k" }), "me@example.test", "s", ["x"]);
    });
  });
  for (const [env, email] of [[{}, "me@example.test"], [{ RESEND_API_KEY: "k" }, null], [{ RESEND_API_KEY: "k", DISABLED_FEATURES: "email" }, "me@example.test"]] as const) {
    await withFetch(() => new Response("{}"), async calls => {
      await sendPasskeyNotice(partialEnv(env), email, "s", ["x"]);
      assert.equal(calls.length, 0);
    });
  }
});

// ---- login-monitor.ts ----

// Cloudflare's view of the caller (country, network) arrives on request.cf.
const fromJapan = (cf: Untyped = { country: "JP", asn: 2516, asOrganization: "KDDI" }) =>
  Object.assign(new Request("https://example.test/x"), { cf });

test("noting a sign-in never raises: when the counter fails the account is simply not marked new", async () => {
  const env = partialEnv({
    RATE_COUNTER: { getByName() { return { async seenContext() { throw new Error("counter unavailable"); } }; } },
  });
  const result = await silenced(() => noteSignInContext(env, fromJapan(), "Me@Example.test", { notify: true }));
  assert.deepEqual(result, { newContext: false, firstSeen: false });
});

test("without Cloudflare's country and network there is nothing to remember, and the counter isn't touched", async () => {
  let touched = 0;
  const env = partialEnv({ RATE_COUNTER: { getByName() { touched++; return {}; } } });
  for (const cf of [null, {}, { country: "JP" }, { asn: 1 }, { country: "JP", asn: null }]) {
    assert.deepEqual(await noteSignInContext(env, fromJapan(cf), "me@example.test", { notify: true }), { newContext: false, firstSeen: false });
  }
  assert.equal(touched, 0);
});

test("a sign-in from somewhere new is still counted when the notice can't be sent, and a known place says nothing", async () => {
  const bumps: string[] = [];
  const counter = (isNew: boolean, wasEmpty = false) => partialEnv({
    RESEND_API_KEY: "k",
    RATE_COUNTER: {
      getByName(name: string) {
        return {
          async seenContext() { return { isNew, wasEmpty }; },
          async bump() { bumps.push(name); return true; },
        };
      },
    },
  });
  const failing = (env: Untyped) => silenced(() => withFetch(() => { throw new Error("mail down"); }, () => noteSignInContext(env, fromJapan(), "me@example.test", { notify: true })));

  assert.deepEqual(await failing(counter(true)), { newContext: true, firstSeen: false }, "counted although the mail failed");
  assert.equal(bumps.length, 1, "the daily notice budget was spent on the attempt");
  assert.deepEqual(await failing(counter(true, true)), { newContext: false, firstSeen: true }, "a first-ever sign-in isn't a spike");
  bumps.length = 0;
  assert.deepEqual(await failing(counter(false)), { newContext: false, firstSeen: false });
  assert.deepEqual(bumps, [], "a known place sends nothing and spends nothing");
});

// ---- devices.ts ----

test("removing a device needs a well-formed token, and any other method is refused", async () => {
  const env = partialEnv({ STUDIQUO_DATA: { async get() { return null; }, async put() {}, async delete() {} }, RATE_LIMIT_CHAT_DEVICE_REGISTER: { async limit() { return { success: true }; } } });
  const url = new URL("https://example.test/api/chat/devices");
  const send = async (method: string, body?: unknown, raw?: string) => (await handleDeviceRoutes(url, new Request(url, {
    method, headers: { "content-type": "application/json" }, body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  }), env, "user-a"))!;
  for (const body of [{}, { deviceToken: "" }, { deviceToken: "xyz" }, { deviceToken: "a".repeat(63) }, { deviceToken: "g".repeat(64) }, { deviceToken: 123 }]) {
    assert.equal((await send("DELETE", body)).status, 400, JSON.stringify(body));
  }
  assert.equal((await send("DELETE", undefined, "{not json")).status, 400);
  assert.equal((await send("DELETE", { deviceToken: "A".repeat(64) })).status, 200, "upper case is accepted and normalised");
  assert.equal((await send("GET")).status, 405);
  assert.equal((await send("PUT", {})).status, 405);
  assert.equal(await handleDeviceRoutes(new URL("https://example.test/api/chat/other"), new Request(url), env, "user-a"), null);
});
