import assert from "node:assert/strict";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { jwksVerifier } from "./jwks-verify.ts";
import { partialEnv } from "./test-env.ts";

function makeEnv() {
  const store = new Map();
  const puts: { key: string; value: string; options: any; }[] = [];
  return partialEnv({
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const raw = store.get(key) ?? null;
        return type === "json" && raw ? JSON.parse(raw) : raw;
      },
      async put(key: string, value: string, options: string) {
        store.set(key, value);
        puts.push({ key, value, options });
      },
    },
    _puts: puts,
  });
}

async function makeKey(kid = "kid-1") {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  jwk.kid = kid;
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { privateKey, jwk };
}

test("fetches JWKS on cache miss, stores with 24h TTL, and serves from KV on cache hit", async () => {
  const env = makeEnv();
  const { jwk } = await makeKey();
  const verifier = jwksVerifier({
    providerName: "TestProvider",
    jwksUrl: "https://idp.example.test/keys",
    cacheKey: "test:jwks",
    issuer: "https://idp.example.test",
    audience: "client-1",
  });

  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  globalThis.fetch = async (url) => {
    fetchCount += 1;
    assert.equal(String(url), "https://idp.example.test/keys");
    return new Response(JSON.stringify({ keys: [jwk] }), { status: 200 });
  };

  try {
    const first = await verifier.getPublicKeys(env);
    assert.deepEqual(first, { keys: [jwk] });
    assert.equal(fetchCount, 1);
    assert.equal(env._puts.length, 1);
    assert.equal(env._puts[0].key, "test:jwks");
    assert.deepEqual(env._puts[0].options, { expirationTtl: 86400 });

    const second = await verifier.getPublicKeys(env);
    assert.deepEqual(second, { keys: [jwk] });
    assert.equal(fetchCount, 1, "cache hit must not call fetch again");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("throws descriptive error when JWKS endpoint responds with non-2xx HTTP status", async () => {
  const env = makeEnv();
  const verifier = jwksVerifier({
    providerName: "BrokenIdP",
    jwksUrl: "https://idp.example.test/keys",
    cacheKey: "broken:jwks",
    issuer: "https://idp.example.test",
    audience: "client-1",
  });

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("unavailable", { status: 503 });

  try {
    await assert.rejects(
      () => verifier.getPublicKeys(env),
      /Failed to fetch BrokenIdP's public keys: HTTP 503/
    );
    assert.equal(env._puts.length, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("verifyIdentityToken validates signature, issuer, audience, and expiration", async () => {
  const env = makeEnv();
  const { privateKey, jwk } = await makeKey("k1");
  await env.STUDIQUO_DATA.put("test:jwks", JSON.stringify({ keys: [jwk] }));

  const verifier = jwksVerifier({
    providerName: "TestProvider",
    jwksUrl: "https://idp.example.test/keys",
    cacheKey: "test:jwks",
    issuer: "https://idp.example.test",
    audience: "client-1",
  });

  const now = Math.floor(Date.now() / 1000);
  const validToken = await new SignJWT({ sub: "user-42", email: "u@example.com" })
    .setProtectedHeader({ alg: "RS256", kid: "k1" })
    .setIssuer("https://idp.example.test")
    .setAudience("client-1")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(privateKey);

  const payload = await verifier.verifyIdentityToken(validToken, env);
  assert.equal(payload.sub, "user-42");

  const unknownKidToken = await new SignJWT({ sub: "user-42" })
    .setProtectedHeader({ alg: "RS256", kid: "unknown-kid" })
    .setIssuer("https://idp.example.test")
    .setAudience("client-1")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(privateKey);

  await assert.rejects(() => verifier.verifyIdentityToken(unknownKidToken, env));
});
