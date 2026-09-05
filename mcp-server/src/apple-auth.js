// Sign in with Apple: server-side verification of the identityToken a native
// client receives from ASAuthorizationAppleIDProvider.
//
// This module only verifies the token — it does not (yet) know about
// accounts, sessions, or KV records beyond the JWKS cache. That comes later,
// once this verification step is wired into an actual endpoint.
import { jwksVerifier } from "./jwks-verify.js";

const { getPublicKeys: getApplePublicKeys, verifyIdentityToken: verifyAppleIdentityToken } = jwksVerifier({
  providerName: "Apple",
  jwksUrl: "https://appleid.apple.com/auth/keys",
  cacheKey: "apple:jwks",
  issuer: "https://appleid.apple.com",
  audience: "com.yabuko.studiquo",
});

export { getApplePublicKeys, verifyAppleIdentityToken };
