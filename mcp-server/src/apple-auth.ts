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
  const audience = env.APPLE_OAUTH_CLIENT_ID?.trim() || "com.yabuko.studiquo";
  return jwksVerifier({
    providerName: "Apple",
    jwksUrl: "https://appleid.apple.com/auth/keys",
    cacheKey: "apple:jwks",
    issuer: "https://appleid.apple.com",
    audience,
  }).verifyIdentityToken(token, env);
}
