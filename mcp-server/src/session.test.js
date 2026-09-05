import assert from "node:assert/strict";
import test from "node:test";
import { mintSession, hasRealSession } from "./session.js";

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
  };
}

test("a token mintSession issues is recognized by hasRealSession", async () => {
  const env = environment();
  const token = await mintSession(env, "apple-sub-1", "r".repeat(40));

  assert.match(token, /^\d+\.r{40}$/);
  assert.equal(await hasRealSession(env, token), true);
});

test("a client-fabricated token in the same shape is not a real session", async () => {
  const env = environment();
  const fabricated = `${Math.floor(Date.now() / 1000)}.${"f".repeat(40)}`;

  assert.equal(await hasRealSession(env, fabricated), false);
});

test("mintSession refuses a randomValue that would make the token too short", async () => {
  const env = environment();
  const token = await mintSession(env, "apple-sub-1", "short");

  assert.equal(token, null);
});

test("two different identities minting a session each get their own, independently valid token", async () => {
  const env = environment();
  const a = await mintSession(env, "apple-sub-1", "a".repeat(40));
  const b = await mintSession(env, "apple-sub-2", "b".repeat(40));

  assert.equal(await hasRealSession(env, a), true);
  assert.equal(await hasRealSession(env, b), true);
  assert.notEqual(a, b);
});
