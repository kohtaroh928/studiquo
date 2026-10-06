import assert from "node:assert/strict";
import test from "node:test";
import { captchaEnabled, captchaRefusal, resetCaptchaWarnings, verifyCaptcha } from "./turnstile.js";

function envWith(response, { status = 200, throws = null } = {}) {
  const calls = [];
  return {
    calls,
    env: {
      TURNSTILE_SECRET: "secret-value",
      TURNSTILE_SITE_KEY: "site-key-value",
      TURNSTILE_FETCH: async (url, init) => {
        calls.push({ url, init });
        if (throws) throw throws;
        return new Response(JSON.stringify(response), { status });
      },
    },
  };
}

function quietly(run) {
  const original = console.error;
  console.error = () => {};
  return run().finally(() => { console.error = original; });
}

test("CAPTCHA is only on when both the secret and the site key are configured", () => {
  const original = console.error;
  console.error = () => {};
  try {
    assert.equal(captchaEnabled({}), false);
    assert.equal(captchaEnabled({ TURNSTILE_SECRET: "s" }), false);
    assert.equal(captchaEnabled({ TURNSTILE_SITE_KEY: "k" }), false);
    assert.equal(captchaEnabled({ TURNSTILE_SECRET: "s", TURNSTILE_SITE_KEY: "k" }), true);
  } finally {
    console.error = original;
  }
});

test("a missing, empty or non-string token is 'required' and never reaches Cloudflare", async () => {
  const { env, calls } = envWith({ success: true });
  for (const token of [undefined, null, "", 42, {}]) {
    assert.deepEqual(await verifyCaptcha(env, token, { action: "login", ip: "198.51.100.1" }), { ok: false, code: "captcha_required" });
  }
  assert.equal(calls.length, 0);
});

test("an over-long token is rejected without calling Cloudflare", async () => {
  const { env, calls } = envWith({ success: true });
  assert.deepEqual(await verifyCaptcha(env, "x".repeat(2_049), { action: "login" }), { ok: false, code: "captcha_failed" });
  assert.equal(calls.length, 0);
});

test("a solved token for the right action passes, and the request carries the secret, token, IP and a timeout", async () => {
  const { env, calls } = envWith({ success: true, action: "login", hostname: "studiquo.example" });
  assert.deepEqual(await verifyCaptcha(env, "tok", { action: "login", ip: "198.51.100.1" }), { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
  const form = calls[0].init.body;
  assert.equal(form.get("secret"), "secret-value");
  assert.equal(form.get("response"), "tok");
  assert.equal(form.get("remoteip"), "198.51.100.1");
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});

test("the client IP is left out when it is unknown", async () => {
  const { env, calls } = envWith({ success: true, action: "login" });
  await verifyCaptcha(env, "tok", { action: "login", ip: "unknown" });
  assert.equal(calls[0].init.body.has("remoteip"), false);
});

test("a token minted for a different action is refused (no spending a login token on send-code)", async () => {
  const { env } = envWith({ success: true, action: "login" });
  assert.deepEqual(await verifyCaptcha(env, "tok", { action: "send-code" }), { ok: false, code: "captcha_failed" });
});

test("a real key must echo the action; only Cloudflare's testing keys may omit it", async () => {
  assert.deepEqual(
    await verifyCaptcha(envWith({ success: true }).env, "tok", { action: "login" }),
    { ok: false, code: "captcha_failed" }
  );
  assert.deepEqual(
    await verifyCaptcha(envWith({ success: true, metadata: { result_with_testing_key: true } }).env, "tok", { action: "login" }),
    { ok: true }
  );
  // ...but even a testing key can't carry a *wrong* action.
  assert.deepEqual(
    await verifyCaptcha(envWith({ success: true, action: "other", metadata: { result_with_testing_key: true } }).env, "tok", { action: "login" }),
    { ok: false, code: "captcha_failed" }
  );
});

test("an unsuccessful verification is 'failed'", async () => {
  const { env } = envWith({ success: false, "error-codes": ["invalid-input-response"] });
  assert.deepEqual(await verifyCaptcha(env, "tok", { action: "login" }), { ok: false, code: "captcha_failed" });
});

test("Cloudflare being down, slow or erroring fails closed as 'unavailable'", () => quietly(async () => {
  assert.deepEqual(
    await verifyCaptcha(envWith({}, { throws: new Error("network down") }).env, "tok", { action: "login" }),
    { ok: false, code: "captcha_unavailable" }
  );
  assert.deepEqual(
    await verifyCaptcha(envWith({}, { throws: new DOMException("timed out", "TimeoutError") }).env, "tok", { action: "login" }),
    { ok: false, code: "captcha_unavailable" }
  );
  assert.deepEqual(
    await verifyCaptcha(envWith({ success: true }, { status: 503 }).env, "tok", { action: "login" }),
    { ok: false, code: "captcha_unavailable" }
  );
}));

test("an unreadable verification response is 'unavailable', not a pass", () => quietly(async () => {
  const env = { TURNSTILE_SECRET: "s", TURNSTILE_SITE_KEY: "k", TURNSTILE_FETCH: async () => new Response("<html>", { status: 200 }) };
  assert.deepEqual(await verifyCaptcha(env, "tok", { action: "login" }), { ok: false, code: "captcha_unavailable" });
}));

test("refusals carry the public site key and the right status, and never the secret", () => {
  const env = { TURNSTILE_SECRET: "secret-value", TURNSTILE_SITE_KEY: "site-key-value" };
  for (const code of ["captcha_required", "captcha_failed"]) {
    const { status, body } = captchaRefusal(env, code);
    assert.equal(status, 403);
    assert.equal(body.code, code);
    assert.equal(body.siteKey, "site-key-value");
    assert.ok(!JSON.stringify(body).includes("secret-value"));
  }
  const unavailable = captchaRefusal(env, "captcha_unavailable");
  assert.equal(unavailable.status, 503);
  assert.equal(unavailable.body.code, "captcha_unavailable");
});

test("a bad secret or malformed request is reported as an outage and logged, not as an endless 403", async () => {
  const original = console.error;
  const logs = [];
  console.error = line => logs.push(String(line));
  try {
    for (const code of ["invalid-input-secret", "missing-input-secret", "bad-request", "internal-error"]) {
      const { env } = envWith({ success: false, "error-codes": [code] });
      assert.deepEqual(await verifyCaptcha(env, "tok", { action: "login" }), { ok: false, code: "captcha_unavailable" }, code);
    }
  } finally {
    console.error = original;
  }
  assert.equal(logs.length, 4);
  assert.ok(logs.every(line => line.includes("misconfigured")));
  assert.ok(!logs.join("").includes("secret-value"));
});

test("a bad or reused token is an ordinary failure and is not logged as a problem", async () => {
  const original = console.error;
  const logs = [];
  console.error = line => logs.push(String(line));
  try {
    for (const code of ["invalid-input-response", "timeout-or-duplicate"]) {
      const { env } = envWith({ success: false, "error-codes": [code] });
      assert.deepEqual(await verifyCaptcha(env, "tok", { action: "login" }), { ok: false, code: "captcha_failed" }, code);
    }
  } finally {
    console.error = original;
  }
  assert.equal(logs.length, 0);
});

test("when TURNSTILE_HOSTNAME is set, a token minted on another hostname is refused (testing keys excepted)", async () => {
  const ok = { success: true, action: "login", hostname: "studiquo.example" };
  const withHost = (response, hostname) => ({ ...envWith(response).env, TURNSTILE_HOSTNAME: hostname });
  assert.deepEqual(await verifyCaptcha(withHost(ok, "studiquo.example"), "tok", { action: "login" }), { ok: true });
  assert.deepEqual(await verifyCaptcha(withHost({ ...ok, hostname: "evil.example" }, "studiquo.example"), "tok", { action: "login" }), { ok: false, code: "captcha_failed" });
  assert.deepEqual(
    await verifyCaptcha(withHost({ success: true, hostname: "example.com", metadata: { result_with_testing_key: true } }, "studiquo.example"), "tok", { action: "login" }),
    { ok: true }
  );
  // Not configured: not checked.
  assert.deepEqual(await verifyCaptcha(envWith({ ...ok, hostname: "anything" }).env, "tok", { action: "login" }), { ok: true });
});

test("a half-configured Turnstile is OFF and says so (once)", () => {
  resetCaptchaWarnings();
  const original = console.error;
  const logs = [];
  console.error = line => logs.push(String(line));
  try {
    assert.equal(captchaEnabled({ TURNSTILE_SECRET: "only-the-secret" }), false);
    assert.equal(captchaEnabled({ TURNSTILE_SITE_KEY: "only-the-key" }), false);
    assert.equal(captchaEnabled({}), false);
  } finally {
    console.error = original;
  }
  assert.equal(logs.length, 1);
  assert.match(logs[0], /half-configured/);
  assert.ok(!logs[0].includes("only-the-secret"));
});
