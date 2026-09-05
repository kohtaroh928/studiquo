import assert from "node:assert/strict";
import test from "node:test";
import { isRevoked, revoke } from "./revocation.js";

function environment() {
  const values = new Map();
  return {
    STUDIQUO_DATA: {
      async get(key) { return values.get(key) ?? null; },
      async put(key, value) { values.set(key, value); },
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
