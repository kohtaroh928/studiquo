import assert from "node:assert/strict";
import test from "node:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { jwksVerifier } from "./jwks-verify.ts";
import { partialEnv, type Untyped } from "./test-env.ts";

const CONFIG = {
  providerName: "Example",
  jwksUrl: "https://idp.example/keys",
  cacheKey: "example:jwks",
  issuer: "https://idp.example",
  audience: "com.example.app",
};

function environment() {
  const values = new Map();
  const puts: { key: string; options: Untyped }[] = [];
  return partialEnv({
    puts,
    values,
    STUDIQUO_DATA: {
      async get(key: string, type: string) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key: string, value: string, options: Untyped) {
        puts.push({ key, options });
        values.set(key, value);
      },
    },
  });
}

async function makeKey(kid = "kid-1") {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = await exportJWK(publicKey);
  Object.assign(jwk, { kid, alg: "RS256", use: "sig" });
  return { privateKey, jwk };
}

function sign(
  privateKey: Untyped,
  kid: string,
  { issuer = CONFIG.issuer, audience = CONFIG.audience, expiresIn = 600 }: { issuer?: string; audience?: string; expiresIn?: number } = {},
) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sub: "user-1" })
    .setProtectedHeader({ alg: "RS256", kid })
    .setIssuer(issuer)
    .setAudience(audience)
    .setIssuedAt(now)
    .setExpirationTime(now + expiresIn)
    .sign(privateKey);
}

// Replaces global fetch for one test and counts calls.
async function withFetch(handler: (url: Untyped) => Untyped, body: (calls: Untyped[]) => Promise<void>) {
  const original = globalThis.fetch;
  const calls: Untyped[] = [];
  globalThis.fetch = (async (url: Untyped) => {
    calls.push(url);
    return handler(url);
  }) as typeof fetch;
  try {
    await body(calls);
  } finally {
    globalThis.fetch = original;
  }
}

const jsonResponse = (data: Untyped, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

test("getPublicKeys returns the cached key set without fetching", async () => {
  const env = environment();
  const cached = { keys: [{ kid: "cached" }] };
  env.values.set(CONFIG.cacheKey, JSON.stringify(cached));
  const { getPublicKeys } = jwksVerifier(CONFIG);

  await withFetch(() => assert.fail("fetch must not run on a cache hit"), async (calls) => {
    assert.deepEqual(await getPublicKeys(env), cached);
    assert.equal(calls.length, 0);
  });
});

test("getPublicKeys fetches on a cache miss and caches for 24 hours", async () => {
  const env = environment();
  const jwks = { keys: [{ kid: "live" }] };
  const { getPublicKeys } = jwksVerifier(CONFIG);

  await withFetch(() => jsonResponse(jwks), async (calls) => {
    assert.deepEqual(await getPublicKeys(env), jwks);
    assert.deepEqual(calls, [CONFIG.jwksUrl]);
    assert.equal(env.puts.length, 1);
    assert.equal(env.puts[0].key, CONFIG.cacheKey);
    assert.equal(env.puts[0].options.expirationTtl, 24 * 60 * 60);

    // The second call is served from the cache.
    await getPublicKeys(env);
    assert.equal(calls.length, 1);
  });
});

test("getPublicKeys throws with provider name and status on HTTP failure and caches nothing", async () => {
  const env = environment();
  const { getPublicKeys } = jwksVerifier(CONFIG);

  await withFetch(() => new Response("nope", { status: 503 }), async () => {
    await assert.rejects(getPublicKeys(env), /Failed to fetch Example's public keys: HTTP 503/);
    assert.equal(env.puts.length, 0);
  });
});

test("getPublicKeys propagates a network error and caches nothing", async () => {
  const env = environment();
  const { getPublicKeys } = jwksVerifier(CONFIG);

  await withFetch(() => { throw new TypeError("network down"); }, async () => {
    await assert.rejects(getPublicKeys(env), /network down/);
    assert.equal(env.puts.length, 0);
  });
});

test("verifyIdentityToken returns the payload for a valid token", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  const payload = await verifyIdentityToken(await sign(privateKey, "k1"), env);
  assert.equal(payload.sub, "user-1");
  assert.equal(payload.iss, CONFIG.issuer);
});

test("verifyIdentityToken rejects an expired token", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await assert.rejects(verifyIdentityToken(await sign(privateKey, "k1", { expiresIn: -60 }), env));
});

test("verifyIdentityToken rejects a wrong issuer and a wrong audience", async () => {
  const env = environment();
  const { privateKey, jwk } = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await assert.rejects(verifyIdentityToken(await sign(privateKey, "k1", { issuer: "https://evil.example" }), env));
  await assert.rejects(verifyIdentityToken(await sign(privateKey, "k1", { audience: "com.other.app" }), env));
});

test("verifyIdentityToken rejects a token signed by a different key with the same kid", async () => {
  const env = environment();
  const trusted = await makeKey("k1");
  const attacker = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [trusted.jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await assert.rejects(verifyIdentityToken(await sign(attacker.privateKey, "k1"), env));
});

test("verifyIdentityToken rejects an unknown kid (e.g. rotated key not in cache)", async () => {
  const env = environment();
  const known = await makeKey("old");
  const rotated = await makeKey("new");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [known.jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await assert.rejects(verifyIdentityToken(await sign(rotated.privateKey, "new"), env));
});

test("verifyIdentityToken rejects malformed tokens", async () => {
  const env = environment();
  const { jwk } = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await assert.rejects(verifyIdentityToken("", env));
  await assert.rejects(verifyIdentityToken("not.a.jwt", env));
});

test("verifyIdentityToken rejects an unsigned (alg none) token", async () => {
  const env = environment();
  const { jwk } = await makeKey("k1");
  env.values.set(CONFIG.cacheKey, JSON.stringify({ keys: [jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  const b64 = (o: Untyped) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const token = `${b64({ alg: "none", kid: "k1" })}.${b64({ iss: CONFIG.issuer, aud: CONFIG.audience, exp: now + 600, sub: "x" })}.`;
  await assert.rejects(verifyIdentityToken(token, env));
});

test("two verifiers with different cache keys do not share cached keys", async () => {
  const env = environment();
  const a = await makeKey("k1");
  env.values.set("other:jwks", JSON.stringify({ keys: [a.jwk] }));
  const { verifyIdentityToken } = jwksVerifier(CONFIG);

  await withFetch(() => jsonResponse({ keys: [] }), async () => {
    await assert.rejects(verifyIdentityToken(await sign(a.privateKey, "k1"), env));
  });
});

// MARK: Key rotation and fetch limits

async function signWith(privateKey: Awaited<ReturnType<typeof makeKey>>["privateKey"], kid: string) {
  return new SignJWT({}).setProtectedHeader({ alg: "RS256", kid }).setIssuer("https://idp.example.test").setAudience("client-1")
    .setSubject("u").setIssuedAt().setExpirationTime("5m").sign(privateKey);
}

function rotatingVerifier() {
  return jwksVerifier({
    providerName: "TestProvider", jwksUrl: "https://idp.example.test/keys", cacheKey: "rot:jwks",
    issuer: "https://idp.example.test", audience: "client-1",
  });
}

test("a token signed with a key newer than the cached set triggers one refresh instead of failing until the cache expires", async () => {
  const env = environment();
  const oldKey = await makeKey("kid-old");
  const newKey = await makeKey("kid-new");
  await env.STUDIQUO_DATA.put("rot:jwks", JSON.stringify({ keys: [oldKey.jwk] }));
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  globalThis.fetch = async () => { fetchCount += 1; return new Response(JSON.stringify({ keys: [oldKey.jwk, newKey.jwk] }), { status: 200 }); };
  try {
    const verifier = rotatingVerifier();
    const payload = await verifier.verifyIdentityToken(await signWith(newKey.privateKey, "kid-new"), env);
    assert.equal(payload.sub, "u");
    assert.equal(fetchCount, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("an unknown key id refreshes at most once per cooldown, so garbage tokens cannot make the Worker hammer the provider", async () => {
  const env = environment();
  const known = await makeKey("kid-known");
  const stranger = await makeKey("kid-stranger");
  await env.STUDIQUO_DATA.put("rot:jwks", JSON.stringify({ keys: [known.jwk] }));
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  globalThis.fetch = async () => { fetchCount += 1; return new Response(JSON.stringify({ keys: [known.jwk] }), { status: 200 }); };
  try {
    const verifier = rotatingVerifier();
    for (let i = 0; i < 5; i += 1) {
      await assert.rejects(verifier.verifyIdentityToken(await signWith(stranger.privateKey, "kid-stranger"), env));
    }
    assert.equal(fetchCount, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("the provider's key endpoint is fetched with a timeout", async () => {
  const env = environment();
  const { jwk } = await makeKey();
  const originalFetch = globalThis.fetch;
  let signal: AbortSignal | null | undefined;
  globalThis.fetch = async (_url, init) => { signal = init?.signal; return new Response(JSON.stringify({ keys: [jwk] }), { status: 200 }); };
  try {
    await rotatingVerifier().getPublicKeys(env);
    assert.ok(signal, "fetch must carry an abort signal");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
