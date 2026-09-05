import assert from "node:assert/strict";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { getApplePublicKeys, verifyAppleIdentityToken } from "./apple-auth.js";

const REAL_ISSUER = "https://appleid.apple.com";
const REAL_AUDIENCE = "com.yabuko.studiquo";

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

// A local, throwaway RS256 keypair stands in for Apple's own signing key —
// same idea as passkeys.test.js hashing a token with node:crypto instead of
// needing a real Apple credential.
async function makeTestSigningKey() {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  jwk.kid = "test-key-1";
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { privateKey, jwk };
}

async function seedJWKS(env, jwk) {
  await env.STUDIQUO_DATA.put("apple:jwks", JSON.stringify({ keys: [jwk] }));
}

function signToken(privateKey, kid, { issuer = REAL_ISSUER, audience = REAL_AUDIENCE, expiresInSeconds = 600, issuedAtSecondsAgo = 0 } = {}) {
  const now = Math.floor(Date.now() / 1000) - issuedAtSecondsAgo;
  return new SignJWT({ sub: "000123.abcdef.4567" })
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt(now)
    .setExpirationTime(now + expiresInSeconds)
    .sign(privateKey);
}

test("verifies a validly-signed token with matching iss/aud and a live exp", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid);

  const payload = await verifyAppleIdentityToken(token, env);

  assert.equal(payload.sub, "000123.abcdef.4567");
  assert.equal(payload.iss, REAL_ISSUER);
  assert.equal(payload.aud, REAL_AUDIENCE);
});

test("rejects an expired token", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { issuedAtSecondsAgo: 3600, expiresInSeconds: 1800 }); // expired 30 min ago

  await assert.rejects(() => verifyAppleIdentityToken(token, env), /exp/i);
});

test("rejects a token with the wrong audience", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { audience: "com.someone-else.app" });

  await assert.rejects(() => verifyAppleIdentityToken(token, env), /aud/i);
});

test("rejects a token with the wrong issuer", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { issuer: "https://evil.example.com" });

  await assert.rejects(() => verifyAppleIdentityToken(token, env), /iss/i);
});

test("rejects a token whose signature does not match the cached public key", async () => {
  const env = environment();
  const { jwk } = await makeTestSigningKey();
  // A completely different keypair signs the token, but we publish the
  // *first* key's public half — simulating a forged/tampered token.
  const { privateKey: attackerKey } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(attackerKey, jwk.kid);

  await assert.rejects(() => verifyAppleIdentityToken(token, env));
});

test("getApplePublicKeys returns the cached JWKS without fetching when the cache is warm", async () => {
  const env = environment();
  const fakeJWKS = { keys: [{ kty: "RSA", kid: "cached-key" }] };
  await env.STUDIQUO_DATA.put("apple:jwks", JSON.stringify(fakeJWKS));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error("should not fetch when the cache is warm"); };

  try {
    const result = await getApplePublicKeys(env);
    assert.deepEqual(result, fakeJWKS);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("getApplePublicKeys fetches from Apple and caches the result when the cache is cold", async () => {
  const env = environment();
  const fakeJWKS = { keys: [{ kty: "RSA", kid: "live-key" }] };
  const originalFetch = globalThis.fetch;
  let requestedURL = null;
  globalThis.fetch = async (url) => {
    requestedURL = String(url);
    return new Response(JSON.stringify(fakeJWKS), { status: 200 });
  };

  try {
    const result = await getApplePublicKeys(env);
    assert.deepEqual(result, fakeJWKS);
    assert.equal(requestedURL, "https://appleid.apple.com/auth/keys");
    const cached = await env.STUDIQUO_DATA.get("apple:jwks", "json");
    assert.deepEqual(cached, fakeJWKS);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
