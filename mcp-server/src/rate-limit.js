// Rate limiting for the endpoints that can be called with no bearer token at
// all (passkey login, Sign in with Apple exchange) and for a few
// already-authenticated but abuse-prone actions (adding a friend, sending a
// chat message, …). Each endpoint's limit itself lives in wrangler.jsonc,
// on the Cloudflare Rate Limiting binding provisioned for it (env.RATE_LIMIT_*).
//
// This used to also bump an independent KV+TTL counter in parallel, as a
// backup for a documented case where the Cloudflare binding can return
// success=true indefinitely for the same key/colo
// (https://community.cloudflare.com/t/workers-rate-limiting-binding-always-returns-success-true-for-the-same-key-and-colo/953250).
// That backup was retired: every one of its KV writes counted against the
// whole Cloudflare account's shared daily KV operation cap, on every single
// rate-limited request across every endpoint — in practice a far more
// common failure than the binding bug it was guarding against.

/** The IP Cloudflare's edge observed for this request. Never trust a
 * client-supplied header for this — `cf-connecting-ip` is set by Cloudflare
 * itself and can't be spoofed by the caller. */
export function clientKey(request) {
  return request.headers.get("cf-connecting-ip") || "unknown";
}

/**
 * @param binding - the Cloudflare Rate Limiting binding for this endpoint (env.RATE_LIMIT_*)
 * @param key - clientKey(request), or a userKey for an already-authenticated endpoint
 */
export async function checkRateLimit(binding, key) {
  const result = await binding.limit({ key });
  return result.success;
}
