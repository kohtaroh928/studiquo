// Sign in with Apple: server-side verification of the identityToken a native
// client receives from ASAuthorizationAppleIDProvider.
//
// This module only verifies the token — it does not (yet) know about
// accounts, sessions, or KV records beyond the JWKS cache. That comes later,
// once this verification step is wired into an actual endpoint.
import { jwksVerifier } from "./jwks-verify.ts";

const defaultVerifier = jwksVerifier({
  providerName: "Apple",
  jwksUrl: "https://appleid.apple.com/auth/keys",
  cacheKey: "apple:jwks",
  issuer: "https://appleid.apple.com",
  audience: "com.yabuko.studiquo",
});

export const getApplePublicKeys = defaultVerifier.getPublicKeys;

/// Apple uses the app bundle identifier as the JWT audience. A separate
/// staging bundle identifier must therefore be verified only by staging.
export function verifyAppleIdentityToken(token: string, env: import("./env.ts").Env) {
  const configured = env.APPLE_OAUTH_CLIENT_ID?.trim();
  // Same rule as Google: a staging Worker without its own client id must not
  // fall back to (and so accept tokens meant for) the production app.
  if (env.DEPLOYMENT_ENVIRONMENT === "staging" && !configured) {
    throw new Error("Staging Apple OAuth client is not configured");
  }
  const audience = configured || "com.yabuko.studiquo";
  return jwksVerifier({
    providerName: "Apple",
    jwksUrl: "https://appleid.apple.com/auth/keys",
    cacheKey: "apple:jwks",
    issuer: "https://appleid.apple.com",
    audience,
  }).verifyIdentityToken(token, env);
}
