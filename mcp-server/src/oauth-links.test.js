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
  assert.equal(result.canonicalIdentityKey, "apple-sub-1");
  assert.deepEqual(result.linkedIdentities, [{ provider: "apple", sub: "apple-sub-1" }]);
  assert.deepEqual(await linkedIdentities(env, "person@example.com"), [{ provider: "apple", sub: "apple-sub-1" }]);
});

test("a second provider with the same verified email resolves to the first identity's canonical account", async () => {
  const env = environment();
  await linkVerifiedEmail(env, { provider: "apple", sub: "apple-sub-1", email: "person@example.com", emailVerified: true });
  const result = await linkVerifiedEmail(env, { provider: "google", sub: "google-sub-9", email: "person@example.com", emailVerified: true });

  assert.deepEqual(result.linkedIdentities, [
    { provider: "apple", sub: "apple-sub-1" },
    { provider: "google", sub: "google-sub-9" },
  ]);
  assert.equal(result.canonicalIdentityKey, "apple-sub-1", "the first verified identity remains the shared account owner");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:google:google-sub-9"), "apple-sub-1");
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

test("legacy email-accounts data migrates its first identity as the canonical owner", async () => {
  const env = environment();
  await env.STUDIQUO_DATA.put("email-accounts:person@example.com", JSON.stringify([
    { provider: "apple", sub: "legacy-apple-sub" },
    { provider: "google", sub: "legacy-google-sub" },
  ]));

  const result = await linkVerifiedEmail(env, {
    provider: "google", sub: "legacy-google-sub", email: "person@example.com", emailVerified: true,
  });

  assert.equal(result.canonicalIdentityKey, "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("email-account-owner:person@example.com"), "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:legacy-apple-sub"), "legacy-apple-sub");
  assert.equal(await env.STUDIQUO_DATA.get("identity-canonical:google:legacy-google-sub"), "legacy-apple-sub");
});
