// Shared "fetch + cache + verify" plumbing for the OIDC providers (Apple,
// Google) whose identity tokens this server verifies. Each provider module
// supplies its own URL/cache key/issuer/audience and gets back a
// same-shaped { getPublicKeys, verifyIdentityToken } pair — same JWKS-caching
// approach, same verification contract, just pointed at that provider's own
// endpoints.
import { createLocalJWKSet, jwtVerify, type JSONWebKeySet, type JWTPayload } from "jose";
import type { Env } from "./env.ts";

const CACHE_TTL_SECONDS = 24 * 60 * 60;

export interface JwksVerifierOptions {
  providerName: string;
  jwksUrl: string;
  cacheKey: string;
  issuer: string | string[];
  audience: string | string[];
}

export function jwksVerifier({ providerName, jwksUrl, cacheKey, issuer, audience }: JwksVerifierOptions) {
  /**
   * Returns `providerName`'s current public key set (JWKS), cached in KV for
   * 24 hours so ordinary sign-ins don't hit the provider's endpoint each
   * time. A cache miss fetches live and refills the cache.
   */
  async function getPublicKeys(env: Env): Promise<JSONWebKeySet> {
    const cached = await env.STUDIQUO_DATA.get<JSONWebKeySet>(cacheKey, "json");
    if (cached) return cached;

    const response = await fetch(jwksUrl);
    if (!response.ok) {
      throw new Error(`Failed to fetch ${providerName}'s public keys: HTTP ${response.status}`);
    }
    const jwks = (await response.json()) as JSONWebKeySet;
    await env.STUDIQUO_DATA.put(cacheKey, JSON.stringify(jwks), { expirationTtl: CACHE_TTL_SECONDS });
    return jwks;
  }

  /**
   * Verifies an identity token end to end: signature against the provider's
   * published public keys, plus the `iss`, `aud`, and `exp` claims.
   *
   * Throws (via `jose`) on any failure — bad signature, unknown key id,
   * wrong issuer, wrong audience, or an expired token. Callers should treat
   * any thrown error as "reject this sign-in attempt".
   *
   * Returns the verified JWT payload on success.
   */
  async function verifyIdentityToken(token: string, env: Env): Promise<JWTPayload> {
    const jwks = await getPublicKeys(env);
    const keySet = createLocalJWKSet(jwks);
    const { payload } = await jwtVerify(token, keySet, { issuer, audience });
    return payload;
  }

  return { getPublicKeys, verifyIdentityToken };
}
