// @ts-nocheck 型の付け方は docs/notes/ts-migration.md の「テストの型検査」を参照。
import assert from "node:assert/strict";
import test from "node:test";
import { isRevoked, revoke } from "./revocation.ts";

function environment() {
  const values = new Map();
  const ttls = new Map();
  return {
    ttls,
    STUDIQUO_DATA: {
      async get(key) { return values.get(key) ?? null; },
      async put(key, value, options) { values.set(key, value); ttls.set(key, options?.expirationTtl); },
      async delete(key) { values.delete(key); },
    },
  };
}

test("a key is not revoked until revoke() is called for it", async () => {
  const env = environment();
  assert.equal(await isRevoked(env, "some-key"), false);
});

test("revoke() marks only the given key as revoked", async () => {
  const env = environment();
  await revoke(env, "leaked-token-key");
  assert.equal(await isRevoked(env, "leaked-token-key"), true);
  assert.equal(await isRevoked(env, "other-token-key"), false);
});

test("a revocation record expires once the token itself could no longer be accepted", async () => {
  const env = environment();
  await revoke(env, "leaked-token-key");
  const ttl = env.ttls.get("revoked:leaked-token-key");
  assert.ok(ttl >= 90 * 86_400, "outlives the 90-day token");
  assert.ok(ttl <= 92 * 86_400, "but does not stay forever");
});
