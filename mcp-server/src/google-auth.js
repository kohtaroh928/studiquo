// Google Sign-In: server-side verification of the idToken a native client
// receives from the GoogleSignIn iOS SDK.
//
// Mirrors apple-auth.js exactly (both share jwks-verify.js) — just pointed at
// Google's own issuer/keys/audience. The audience is studiquo's *server*
// OAuth client ID (not the iOS client ID): the iOS app sets that as its
// `GIDServerClientID`, which is what makes Google mint an idToken addressed
// to this audience instead of the app's own client ID.
import { jwksVerifier } from "./jwks-verify.js";

// Google issues both forms across its token population; accepting either is
// Google's own documented guidance for verifying ID tokens.
const ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

const { getPublicKeys: getGooglePublicKeys, verifyIdentityToken: verifyGoogleIdentityToken } = jwksVerifier({
  providerName: "Google",
  jwksUrl: "https://www.googleapis.com/oauth2/v3/certs",
  cacheKey: "google:jwks",
  issuer: ISSUERS,
  audience: "812858933445-q6j9uih0o702884hemnk2okiet26gv1j.apps.googleusercontent.com",
});

export { getGooglePublicKeys, verifyGoogleIdentityToken };
