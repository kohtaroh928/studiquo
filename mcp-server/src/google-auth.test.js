import assert from "node:assert/strict";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { getGooglePublicKeys, verifyGoogleIdentityToken } from "./google-auth.js";

const REAL_ISSUER = "https://accounts.google.com";
const REAL_AUDIENCE = "812858933445-q6j9uih0o702884hemnk2okiet26gv1j.apps.googleusercontent.com";

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

// A local, throwaway RS256 keypair stands in for Google's own signing key —
// same idea as apple-auth.test.js.
async function makeTestSigningKey() {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  jwk.kid = "test-key-1";
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { privateKey, jwk };
}

async function seedJWKS(env, jwk) {
  await env.STUDIQUO_DATA.put("google:jwks", JSON.stringify({ keys: [jwk] }));
}

function signToken(privateKey, kid, { issuer = REAL_ISSUER, audience = REAL_AUDIENCE, email, emailVerified, expiresInSeconds = 600, issuedAtSecondsAgo = 0 } = {}) {
  const now = Math.floor(Date.now() / 1000) - issuedAtSecondsAgo;
  const claims = { sub: "108234567890123456789" };
  if (email !== undefined) claims.email = email;
  if (emailVerified !== undefined) claims.email_verified = emailVerified;
  return new SignJWT(claims)
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
  const token = await signToken(privateKey, jwk.kid, { email: "person@example.com", emailVerified: true });

  const payload = await verifyGoogleIdentityToken(token, env);

  assert.equal(payload.sub, "108234567890123456789");
  assert.equal(payload.iss, REAL_ISSUER);
  assert.equal(payload.aud, REAL_AUDIENCE);
  assert.equal(payload.email, "person@example.com");
  assert.equal(payload.email_verified, true);
});

test("accepts the bare-domain issuer form Google also uses", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { issuer: "accounts.google.com" });

  const payload = await verifyGoogleIdentityToken(token, env);
  assert.equal(payload.iss, "accounts.google.com");
});

test("rejects an expired token", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { issuedAtSecondsAgo: 3600, expiresInSeconds: 1800 });

  await assert.rejects(() => verifyGoogleIdentityToken(token, env), /exp/i);
});

test("rejects a token with the wrong audience", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { audience: "someone-else.apps.googleusercontent.com" });

  await assert.rejects(() => verifyGoogleIdentityToken(token, env), /aud/i);
});

test("rejects a token with the wrong issuer", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(privateKey, jwk.kid, { issuer: "https://evil.example.com" });

  await assert.rejects(() => verifyGoogleIdentityToken(token, env), /iss/i);
});

test("rejects a token whose signature does not match the cached public key", async () => {
  const env = environment();
  const { jwk } = await makeTestSigningKey();
  const { privateKey: attackerKey } = await makeTestSigningKey();
  await seedJWKS(env, jwk);
  const token = await signToken(attackerKey, jwk.kid);

  await assert.rejects(() => verifyGoogleIdentityToken(token, env));
});

test("getGooglePublicKeys returns the cached JWKS without fetching when the cache is warm", async () => {
  const env = environment();
  const fakeJWKS = { keys: [{ kty: "RSA", kid: "cached-key" }] };
  await env.STUDIQUO_DATA.put("google:jwks", JSON.stringify(fakeJWKS));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error("should not fetch when the cache is warm"); };

  try {
    const result = await getGooglePublicKeys(env);
    assert.deepEqual(result, fakeJWKS);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("getGooglePublicKeys fetches from Google and caches the result when the cache is cold", async () => {
  const env = environment();
  const fakeJWKS = { keys: [{ kty: "RSA", kid: "live-key" }] };
  const originalFetch = globalThis.fetch;
  let requestedURL = null;
  globalThis.fetch = async (url) => {
    requestedURL = String(url);
    return new Response(JSON.stringify(fakeJWKS), { status: 200 });
  };

  try {
    const result = await getGooglePublicKeys(env);
    assert.deepEqual(result, fakeJWKS);
    assert.equal(requestedURL, "https://www.googleapis.com/oauth2/v3/certs");
    const cached = await env.STUDIQUO_DATA.get("google:jwks", "json");
    assert.deepEqual(cached, fakeJWKS);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
