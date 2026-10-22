import assert from "node:assert/strict";
import test from "node:test";
import { unsafeConfiguration, warnOnUnsafeConfiguration } from "./config-warnings.ts";
import { partialEnv } from "./test-env.ts";

test("a signed-token requirement with no signing key is reported", () => {
  assert.equal(unsafeConfiguration(partialEnv({ REQUIRE_SIGNED_TOKENS: "true" })).length, 1);
  assert.deepEqual(unsafeConfiguration(partialEnv({ REQUIRE_SIGNED_TOKENS: "true", TOKEN_SIGNING_KEY: "k" })), []);
  assert.deepEqual(unsafeConfiguration(partialEnv({})), []);
});

test("App Attest asked for but silently off is reported", () => {
  assert.equal(unsafeConfiguration(partialEnv({ APP_ATTEST_MODE: "enforce" })).length, 1);
  assert.deepEqual(unsafeConfiguration(partialEnv({})), []);
});

test("the report is written to the log once per environment, with no secret values in it", () => {
  const secret = "sekret-signing-value-123";
  const env = partialEnv({ REQUIRE_SIGNED_TOKENS: "true", APP_ATTEST_MODE: "enforce", APP_ATTEST_APP_ID: "TEAM.app", RATE_COUNTER: {}, RESEND_API_KEY: secret });
  const lines: string[] = [];
  const original = console.error;
  console.error = (line: unknown) => { lines.push(String(line)); };
  try {
    warnOnUnsafeConfiguration(env);
    warnOnUnsafeConfiguration(env);
  } finally {
    console.error = original;
  }
  assert.ok(lines.length >= 1);
  assert.equal(lines.length, unsafeConfiguration(env).length, "each problem once, however often it is called");
  assert.ok(lines.every(line => /unsafe configuration/.test(line) && !line.includes(secret)));
});
