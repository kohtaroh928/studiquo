// Shared "fetch + cache + verify" plumbing for the OIDC providers (Apple,
// Google) whose identity tokens this server verifies. Each provider module
// supplies its own URL/cache key/issuer/audience and gets back a
// same-shaped { getPublicKeys, verifyIdentityToken } pair — same JWKS-caching
// approach, same verification contract, just pointed at that provider's own
// endpoints.
import { createLocalJWKSet, errors, jwtVerify, type JSONWebKeySet, type JWTPayload } from "jose";
import type { Env } from "./env.ts";

const CACHE_TTL_SECONDS = 24 * 60 * 60;
// A provider that is slow must not hold a sign-in open indefinitely.
const FETCH_TIMEOUT_MS = 5000;
// A token naming a key that is not in the cached set may mean the provider has
// rotated its keys; fetch the set again, but at most this often, so tokens with
// made-up key ids cannot turn into a stream of requests to the provider.
const REFRESH_COOLDOWN_SECONDS = 60;

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
  async function fetchKeys(env: Env): Promise<JSONWebKeySet> {
    const response = await fetch(jwksUrl, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    if (!response.ok) {
      throw new Error(`Failed to fetch ${providerName}'s public keys: HTTP ${response.status}`);
    }
    const jwks = (await response.json()) as JSONWebKeySet;
    await env.STUDIQUO_DATA.put(cacheKey, JSON.stringify(jwks), { expirationTtl: CACHE_TTL_SECONDS });
    return jwks;
  }

  async function getPublicKeys(env: Env): Promise<JSONWebKeySet> {
    const cached = await env.STUDIQUO_DATA.get<JSONWebKeySet>(cacheKey, "json");
    if (cached) return cached;
    return fetchKeys(env);
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
    try {
      const { payload } = await jwtVerify(token, createLocalJWKSet(jwks), { issuer, audience });
      return payload;
    } catch (error) {
      if (!(error instanceof errors.JWKSNoMatchingKey)) throw error;
      // Best effort: the cooldown is a KV flag (not atomic, and consistent
      // across locations only after a while), so a burst can still fetch a few
      // times. No matching key can also mean the key's type does not fit the
      // token's algorithm, not only an unknown key id. It is claimed before
      // fetching, so a fetch that then fails is not retried for the cooldown.
      const cooldownKey = `${cacheKey}:refresh-cooldown`;
      if (await env.STUDIQUO_DATA.get(cooldownKey)) throw error;
      await env.STUDIQUO_DATA.put(cooldownKey, "1", { expirationTtl: REFRESH_COOLDOWN_SECONDS });
      const refreshed = await fetchKeys(env);
      const { payload } = await jwtVerify(token, createLocalJWKSet(refreshed), { issuer, audience });
      return payload;
    }
  }

  return { getPublicKeys, verifyIdentityToken };
}
