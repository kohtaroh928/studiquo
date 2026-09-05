import assert from "node:assert/strict";
import test from "node:test";
import { linkVerifiedEmail, linkedIdentities } from "./oauth-links.js";

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

test("links a provider identity to a verified email", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "Person@Example.com", emailVerified: true });

  assert.equal(result.normalizedEmail, "person@example.com");
  assert.deepEqual(result.linkedIdentities, [{ provider: "apple", sub: "apple-sub-1" }]);
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [{ provider: "apple", sub: "apple-sub-1" }]);
});

test("a second provider with the same verified email joins the same identity list", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "person@example.com", emailVerified: true });
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-9", email: "person@example.com", emailVerified: true });

  assert.deepEqual(result.linkedIdentities, [
    { provider: "apple", sub: "apple-sub-1" },
    { provider: "google", sub: "google-sub-9" },
  ]);
});

test("an unverified email is never linked", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: false });

  assert.equal(result.normalizedEmail, null);
  assert.deepEqual(result.linkedIdentities, []);
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), []);
});

test("a missing email is a no-op", async () => {
  const env = environment();
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: null, emailVerified: true });

  assert.deepEqual(result.linkedIdentities, []);
});

test("re-linking the same provider identity does not duplicate it", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: true });
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-1", email: "person@example.com", emailVerified: true });

  assert.deepEqual(result.linkedIdentities, [{ provider: "google", sub: "google-sub-1" }]);
});

test("email matching is case- and whitespace-insensitive", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "  Person@Example.com  ", emailVerified: true });

  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [{ provider: "apple", sub: "apple-sub-1" }]);
});
