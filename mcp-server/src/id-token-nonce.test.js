import assert from "node:assert/strict";
import test from "node:test";
import { sha256Hex } from "./auth.ts";
import { idTokenNonceRefused } from "./id-token-nonce.ts";

function makeEnv({ requireNonce = "false" } = {}) {
  const used = new Set();
  const ttlRecorded = new Map();
  return {
    REQUIRE_ID_TOKEN_NONCE: requireNonce,
    RATE_COUNTER: {
      getByName(name) {
        return {
          async bump(limit, windowSeconds) {
            ttlRecorded.set(name, { limit, windowSeconds });
            if (used.has(name)) return false;
            used.add(name);
            return true;
          },
        };
      },
    },
    _ttlRecorded: ttlRecorded,
  };
}

async function captureLogs(fn) {
  const original = console.log;
  const lines = [];
  console.log = (...args) => lines.push(args.join(" "));
  try {
    const result = await fn();
    return { result, lines: lines.map((line) => JSON.parse(line)) };
  } finally {
    console.log = original;
  }
}

test("accepts a matching raw nonce on first use and rejects a replay", async () => {
  const env = makeEnv({ requireNonce: "true" });
  const rawNonce = "valid-nonce-string-1234567890";
  const expectedHash = await sha256Hex(rawNonce);
  const payload = { sub: "user-1", nonce: expectedHash };

  const first = await captureLogs(() => idTokenNonceRefused(env, payload, rawNonce, "apple"));
  assert.equal(first.result, false);
  assert.deepEqual(first.lines, [{ event: "id_token_nonce", provider: "apple", outcome: "verified" }]);
  assert.deepEqual(env._ttlRecorded.get(`idtoken-nonce:${expectedHash}`), { limit: 1, windowSeconds: 3600 });

  const second = await captureLogs(() => idTokenNonceRefused(env, payload, rawNonce, "apple"));
  assert.equal(second.result, true);
  assert.deepEqual(second.lines, [{ event: "id_token_nonce", provider: "apple", outcome: "replayed" }]);
});

test("accepts uppercase hex in the ID token nonce claim and never logs secrets", async () => {
  const env = makeEnv({ requireNonce: "true" });
  const rawNonce = "SecretNonceValue_9876543210";
  const expectedHash = (await sha256Hex(rawNonce)).toUpperCase();
  const payload = { sub: "secret-account-id", email: "student@example.com", nonce: expectedHash };

  const { result, lines } = await captureLogs(() => idTokenNonceRefused(env, payload, rawNonce, "google"));
  assert.equal(result, false);
  assert.equal(lines.length, 1);
  const serialized = JSON.stringify(lines[0]);
  assert.ok(!serialized.includes(rawNonce));
  assert.ok(!serialized.includes(expectedHash.toLowerCase()));
  assert.ok(!serialized.includes("student@example.com"));
  assert.ok(!serialized.includes("secret-account-id"));
});

test("allows absent nonce when REQUIRE_ID_TOKEN_NONCE is not true, and refuses when true", async () => {
  const permissiveEnv = makeEnv({ requireNonce: "false" });
  for (const empty of [undefined, null, ""]) {
    const { result, lines } = await captureLogs(() =>
      idTokenNonceRefused(permissiveEnv, { sub: "u" }, empty, "apple")
    );
    assert.equal(result, false);
    assert.deepEqual(lines, [{ event: "id_token_nonce", provider: "apple", outcome: "absent" }]);
  }

  const strictEnv = makeEnv({ requireNonce: "true" });
  for (const empty of [undefined, null, ""]) {
    const { result, lines } = await captureLogs(() =>
      idTokenNonceRefused(strictEnv, { sub: "u" }, empty, "google")
    );
    assert.equal(result, true);
    assert.deepEqual(lines, [{ event: "id_token_nonce", provider: "google", outcome: "absent_refused" }]);
  }
});

test("refuses malformed raw nonces before touching RATE_COUNTER", async () => {
  const env = makeEnv({ requireNonce: "false" });
  const malformedInputs = [
    "too-short-15chr",
    "a".repeat(201),
    "contains spaces in nonce 12345",
    "invalid$characters!@#12345678",
    1234567890123456,
  ];

  for (const bad of malformedInputs) {
    const { result, lines } = await captureLogs(() =>
      idTokenNonceRefused(env, { nonce: "deadbeef" }, bad, "apple")
    );
    assert.equal(result, true);
    assert.deepEqual(lines, [{ event: "id_token_nonce", provider: "apple", outcome: "malformed" }]);
  }
  assert.equal(env._ttlRecorded.size, 0);
});

test("refuses when the ID token lacks a string nonce claim or when the hash mismatches", async () => {
  const env = makeEnv({ requireNonce: "true" });
  const rawNonce = "valid-nonce-string-1234567890";

  const missing = await captureLogs(() => idTokenNonceRefused(env, { sub: "u" }, rawNonce, "apple"));
  assert.equal(missing.result, true);
  assert.deepEqual(missing.lines, [{ event: "id_token_nonce", provider: "apple", outcome: "missing_claim" }]);

  const mismatch = await captureLogs(() =>
    idTokenNonceRefused(env, { sub: "u", nonce: "0".repeat(64) }, rawNonce, "apple")
  );
  assert.equal(mismatch.result, true);
  assert.deepEqual(mismatch.lines, [{ event: "id_token_nonce", provider: "apple", outcome: "mismatch" }]);
  assert.equal(env._ttlRecorded.size, 0);
});
