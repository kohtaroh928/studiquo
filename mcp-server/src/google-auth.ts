// Google Sign-In: server-side verification of the idToken a native client
// receives from the GoogleSignIn iOS SDK.
//
// Mirrors apple-auth.ts exactly (both share jwks-verify.ts) — just pointed at
// Google's own issuer/keys/audience. The audience is studiquo's *server*
// OAuth client ID (not the iOS client ID): the iOS app sets that as its
// `GIDServerClientID`, which is what makes Google mint an idToken addressed
// to this audience instead of the app's own client ID.
import { jwksVerifier } from "./jwks-verify.ts";

// Google issues both forms across its token population; accepting either is
// Google's own documented guidance for verifying ID tokens.
const ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

const defaultVerifier = jwksVerifier({
  providerName: "Google",
  jwksUrl: "https://www.googleapis.com/oauth2/v3/certs",
  cacheKey: "google:jwks",
  issuer: ISSUERS,
  audience: "812858933445-q6j9uih0o702884hemnk2okiet26gv1j.apps.googleusercontent.com",
});

export const getGooglePublicKeys = defaultVerifier.getPublicKeys;

/// The staging app has its own OAuth client. The JWT audience therefore has
/// to be selected from the Worker environment rather than compiled in.
export function verifyGoogleIdentityToken(token: string, env: import("./env.ts").Env) {
  const configured = env.GOOGLE_OAUTH_SERVER_CLIENT_ID?.trim();
  if (env.DEPLOYMENT_ENVIRONMENT === "staging" && !configured) {
    throw new Error("Staging Google OAuth client is not configured");
  }
  const audience = configured || "812858933445-q6j9uih0o702884hemnk2okiet26gv1j.apps.googleusercontent.com";
  return jwksVerifier({
    providerName: "Google",
    jwksUrl: "https://www.googleapis.com/oauth2/v3/certs",
    cacheKey: "google:jwks",
    issuer: ISSUERS,
    audience,
  }).verifyIdentityToken(token, env);
}
