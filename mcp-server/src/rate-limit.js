// Defense-in-depth rate limiting for the endpoints that can be called with no
// bearer token at all (passkey login, Sign in with Apple exchange).
//
// The Cloudflare Rate Limiting binding is fast but explicitly documented as
// "permissive, eventually consistent, and intentionally designed to not be
// used as an accurate accounting system" — and at least one unresolved
// community report claims it can return success=true indefinitely for the
// same key/colo (https://community.cloudflare.com/t/workers-rate-limiting-binding-always-returns-success-true-for-the-same-key-and-colo/953250).
// A second, independent KV+TTL counter — the same bump() shape ai.js already
// uses for AI usage quotas — runs alongside it. A request is allowed only if
// BOTH agree it is within the limit, so a failure of either mechanism alone
// still leaves the other one enforcing the limit.
const WINDOW_SECONDS = 60;

function currentWindowBucket() {
  return Math.floor(Date.now() / 1000 / WINDOW_SECONDS);
}

/** The IP Cloudflare's edge observed for this request. Never trust a
 * client-supplied header for this — `cf-connecting-ip` is set by Cloudflare
 * itself and can't be spoofed by the caller. */
export function clientKey(request) {
  return request.headers.get("cf-connecting-ip") || "unknown";
}

async function bumpKVCounter(env, kvKey, limit) {
  const used = Number(await env.STUDIQUO_DATA.get(kvKey)) || 0;
  if (used >= limit) return false;
  // Expires on its own well after the window it covers, so old counters
  // never accumulate.
  await env.STUDIQUO_DATA.put(kvKey, String(used + 1), { expirationTtl: WINDOW_SECONDS * 2 });
  return true;
}

/**
 * Checks both layers in parallel and allows the request only if neither has
 * hit `limit` within the current 60-second window for `key`.
 *
 * @param env - the Worker environment, for the KV fallback counter
 * @param binding - the Cloudflare Rate Limiting binding for this endpoint (env.RATE_LIMIT_*)
 * @param kvPrefix - a short string unique to the calling endpoint, so its KV counters can't collide with another endpoint's
 * @param key - clientKey(request), or a userKey for an already-authenticated endpoint
 * @param limit - max requests per 60-second window
 */
export async function checkRateLimit(env, binding, kvPrefix, key, limit) {
  const kvKey = `ratelimit:${kvPrefix}:${key}:${currentWindowBucket()}`;
  const [cfResult, kvAllowed] = await Promise.all([
    binding.limit({ key }),
    bumpKVCounter(env, kvKey, limit),
  ]);
  return cfResult.success && kvAllowed;
}
