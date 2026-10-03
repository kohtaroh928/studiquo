// Test helper: a real signed Cloudflare Access token, verified against a local
// key set, so tests exercise src/access.js instead of bypassing it.
import { SignJWT, generateKeyPair, exportJWK, createLocalJWKSet } from "jose";

export const ACCESS = { aud: "test-aud", team: "team.cloudflareaccess.com" };
const keys = await generateKeyPair("ES256", { extractable: true });
const jwks = createLocalJWKSet({ keys: [{ ...(await exportJWK(keys.publicKey)), alg: "ES256", use: "sig" }] });

export function signAccessToken({ aud = ACCESS.aud, team = ACCESS.team } = {}) {
  return new SignJWT({}).setProtectedHeader({ alg: "ES256" })
    .setIssuer(`https://${team}`).setAudience(aud).setIssuedAt().setExpirationTime("1h").sign(keys.privateKey);
}

export const ACCESS_ENV = { ACCESS_AUD: ACCESS.aud, ACCESS_TEAM_DOMAIN: ACCESS.team, ACCESS_JWKS: jwks };
export const ACCESS_HEADERS = { "cf-access-jwt-assertion": await signAccessToken() };
