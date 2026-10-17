// Verifies the Cloudflare Access login on /api/admin/* requests.
//
// Fails closed: without ACCESS_AUD / ACCESS_TEAM_DOMAIN every request is
// refused. /api/admin/* is NOT reliably covered by the Access application that
// guards the /admin pages (stats used to be readable with no login at all), so
// this check — not the edge — is what keeps strangers out. The pages' own
// fetches carry the signed-in session as the CF_Authorization cookie, so that
// is accepted alongside the Cf-Access-Jwt-Assertion header Access adds itself.
import { createRemoteJWKSet, jwtVerify } from "jose";

export async function accessAllowed(request, env) {
  if (!env.ACCESS_AUD || !env.ACCESS_TEAM_DOMAIN) return false;
  const cookie = (request.headers.get("cookie") ?? "")
    .split(";").map(part => part.trim()).find(part => part.startsWith("CF_Authorization="));
  const token = request.headers.get("cf-access-jwt-assertion") ?? cookie?.slice("CF_Authorization=".length);
  if (!token) return false;
  try {
    const issuer = `https://${env.ACCESS_TEAM_DOMAIN}`;
    const jwks = env.ACCESS_JWKS ?? createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
    await jwtVerify(token, jwks, { issuer, audience: env.ACCESS_AUD });
    return true;
  } catch {
    return false;
  }
}

/**
 * Whether a state-changing request to the admin API came from another site. The
 * Access login can arrive as a cookie, which a browser attaches to a request a
 * hostile page makes; such a request names its own origin, so one that does not
 * match this Worker's origin is refused. A request that names no origin (a
 * script or curl) is not a browser acting on someone's behalf and is let through.
 */
export function isCrossSiteWrite(request, url) {
  const method = request.method.toUpperCase();
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") return false;
  const site = request.headers.get("sec-fetch-site");
  if (site && site !== "same-origin" && site !== "none") return true;
  const origin = request.headers.get("origin");
  return Boolean(origin) && origin !== url.origin;
}

// Every /api/admin/* route except RevenueCat's webhook, which RevenueCat's
// servers call (no Access login) and which carries its own shared secret.
export function isAccessGuardedPath(pathname) {
  return pathname.startsWith("/api/admin/") && pathname !== "/api/admin/revenuecat-webhook";
}
