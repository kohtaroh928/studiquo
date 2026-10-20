import assert from "node:assert/strict";
import test from "node:test";
import { mintSession, hasRealSession, realSession } from "./session.ts";
import { partialEnv } from "./test-env.ts";

function environment() {
  const values = new Map();
  return partialEnv({
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key: string, value: string) { values.set(key, value); },
      async delete(key: string) { values.delete(key); },
    },
  });
}

test("a token mintSession issues is recognized by hasRealSession", async () => {
  const env = environment();
  const token = await mintSession(env, "apple-sub-1", "r".repeat(40));

  assert.match(token, /^\d+\.[0-9a-f]{64}$/);
  assert.equal(await hasRealSession(env, token), true);
});

test("a client-fabricated token in the same shape is not a real session", async () => {
  const env = environment();
  const fabricated = `${Math.floor(Date.now() / 1000)}.${"f".repeat(40)}`;

  assert.equal(await hasRealSession(env, fabricated), false);
});

test("the secret half of a token comes from the Worker, never from the value the app sends", async () => {
  const env = environment();
  const sent = "s".repeat(40);
  const first = await mintSession(env, "apple-sub-1", sent);
  const second = await mintSession(env, "apple-sub-1", sent);
  assert.ok(!first.includes(sent));
  assert.notEqual(first, second, "the same value from the app gives two different tokens");
  for (const token of [first, second]) {
    assert.match(token, /^\d+\.[0-9a-f]{64}$/);
    assert.equal(await hasRealSession(env, token), true);
  }
  // Nothing is needed from the app at all, and an odd value changes nothing.
  assert.match(await mintSession(env, "apple-sub-2"), /^\d+\.[0-9a-f]{64}$/);
  assert.match(await mintSession(env, "apple-sub-3", "short"), /^\d+\.[0-9a-f]{64}$/);
});

test("many tokens made in a row never repeat", async () => {
  const env = environment();
  const seen = new Set();
  for (let i = 0; i < 200; i += 1) seen.add(await mintSession(env, `sub-${i % 5}`));
  assert.equal(seen.size, 200);
});

test("two unlinked identities mint their own independently valid sessions", async () => {
  const env = environment();
  const a = await mintSession(env, "apple-sub-1", "a".repeat(40));
  const b = await mintSession(env, "apple-sub-2", "b".repeat(40));

  assert.equal(await hasRealSession(env, a), true);
  assert.equal(await hasRealSession(env, b), true);
  assert.notEqual(a, b);
});

test("an already-issued provider session resolves to the shared canonical account after linking", async () => {
  const env = environment();
  const token = await mintSession(env, "google:google-sub-1", "g".repeat(40));
  await env.STUDIQUO_DATA.put("identity-canonical:google:google-sub-1", "apple-sub-1");

  const session = await realSession(env, token);

  assert.equal(session.sub, "apple-sub-1");
  assert.equal(session.originalSub, "google:google-sub-1");
});
