import assert from "node:assert/strict";
import test from "node:test";
import { sendVerificationCode, confirmVerificationCode } from "./email-verification.js";
import { linkedIdentities } from "./oauth-links.js";

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
    },
    RESEND_API_KEY: "test-key",
  };
}

function stubResend(handler) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => handler(url, init);
  return () => { globalThis.fetch = originalFetch; };
}

// Reads back the code this module itself just generated and sent, so tests
// don't have to hardcode or guess a code — they intercept the outgoing
// Resend request the same way a real inbox would receive it.
async function captureSentCode(env, email) {
  let sentBody = null;
  const restore = stubResend(async (_url, init) => {
    sentBody = JSON.parse(init.body);
    return new Response("{}", { status: 200 });
  });
  await sendVerificationCode(env, email);
  restore();
  const match = /確認コード: (\d{6})/.exec(sentBody.text);
  assert.ok(match, "expected the email body to contain a 6-digit code");
  return match[1];
}

test("sendVerificationCode emails a 6-digit code to the given address", async () => {
  const env = environment();
  let requestedURL = null;
  let sentBody = null;
  const restore = stubResend(async (url, init) => {
    requestedURL = String(url);
    sentBody = JSON.parse(init.body);
    return new Response("{}", { status: 200 });
  });

  const result = await sendVerificationCode(env, "Person@Example.com");

  restore();
  assert.deepEqual(result, { sent: true });
  assert.equal(requestedURL, "https://api.resend.com/emails");
  assert.equal(sentBody.to, "person@example.com");
  assert.match(sentBody.text, /確認コード: \d{6}/);
});

test("sendVerificationCode rejects an invalid email without calling Resend", async () => {
  const env = environment();
  const restore = stubResend(async () => { throw new Error("should not call Resend"); });
  try {
    await assert.rejects(() => sendVerificationCode(env, "not-an-email"), /invalid email/i);
  } finally {
    restore();
  }
});

test("sendVerificationCode throws if Resend rejects the request", async () => {
  const env = environment();
  const restore = stubResend(async () => new Response("nope", { status: 401 }));
  try {
    await assert.rejects(() => sendVerificationCode(env, "person@example.com"), /failed to send/i);
  } finally {
    restore();
  }
});

test("confirmVerificationCode verifies a correct code and links the email", async () => {
  const env = environment();
  const code = await captureSentCode(env, "person@example.com");

  const result = await confirmVerificationCode(env, "person@example.com", code);

  assert.deepEqual(result, { verified: true });
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [
    { provider: "email", sub: "person@example.com" },
  ]);
});

test("confirmVerificationCode is one-time use — the same code cannot be replayed", async () => {
  const env = environment();
  const code = await captureSentCode(env, "person@example.com");

  assert.equal((await confirmVerificationCode(env, "person@example.com", code)).verified, true);
  const replay = await confirmVerificationCode(env, "person@example.com", code);
  assert.deepEqual(replay, { verified: false, attemptsRemaining: 0 });
});

test("confirmVerificationCode rejects a wrong code and counts down attempts", async () => {
  const env = environment();
  await captureSentCode(env, "person@example.com");

  const first = await confirmVerificationCode(env, "person@example.com", "000001");
  assert.equal(first.verified, false);
  assert.equal(first.attemptsRemaining, 4);

  const second = await confirmVerificationCode(env, "person@example.com", "000002");
  assert.equal(second.attemptsRemaining, 3);
});

test("confirmVerificationCode invalidates the code after 5 wrong attempts, even if the 6th guess is correct", async () => {
  const env = environment();
  const code = await captureSentCode(env, "person@example.com");

  for (let i = 0; i < 5; i++) {
    await confirmVerificationCode(env, "person@example.com", "999999");
  }
  const finalTry = await confirmVerificationCode(env, "person@example.com", code);
  assert.deepEqual(finalTry, { verified: false, attemptsRemaining: 0 });
});

test("confirmVerificationCode rejects an expired code", async () => {
  const env = environment();
  const code = await captureSentCode(env, "person@example.com");
  const record = await env.STUDIQUO_DATA.get("email-verify:person@example.com", "json");
  await env.STUDIQUO_DATA.put("email-verify:person@example.com", JSON.stringify({ ...record, expiresAt: Date.now() - 1000 }));

  const result = await confirmVerificationCode(env, "person@example.com", code);
  assert.deepEqual(result, { verified: false, attemptsRemaining: 0 });
});

test("confirmVerificationCode with no code ever sent returns not-verified rather than throwing", async () => {
  const env = environment();
  const result = await confirmVerificationCode(env, "never-sent@example.com", "123456");
  assert.deepEqual(result, { verified: false, attemptsRemaining: 0 });
});

test("a second code for the same email replaces the first and resets attempts", async () => {
  const env = environment();
  const firstCode = await captureSentCode(env, "person@example.com");
  await confirmVerificationCode(env, "person@example.com", "000000".replace("0", "1")); // one wrong guess
  const secondCode = await captureSentCode(env, "person@example.com");

  assert.equal((await confirmVerificationCode(env, "person@example.com", firstCode)).verified, false);
  assert.equal((await confirmVerificationCode(env, "person@example.com", secondCode)).verified, true);
});
