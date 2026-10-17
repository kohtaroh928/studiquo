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
  return normalizeIP(request.headers.get("cf-connecting-ip")) || "unknown";
}

/**
 * The key one client is counted under. An IPv4 address is its own key. An IPv6
 * address is reduced to its /64 prefix: a single customer is normally given a
 * whole /64, so counting each address separately would let one machine rotate
 * through billions of "different" clients and never reach a limit. An IPv4-mapped
 * IPv6 address (`::ffff:1.2.3.4`) is the IPv4 address. Anything that cannot be
 * read as an address is returned unchanged rather than guessed at.
 */
export function normalizeIP(value) {
  const text = String(value ?? "").trim();
  if (!text) return null;
  if (!text.includes(":")) return text;
  let address = text.split("%")[0].toLowerCase();
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(address);
  if (mapped) return mapped[1];
  const dotted = /^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(address);
  if (dotted) {
    const [a, b, c, d] = dotted.slice(2).map(Number);
    if ([a, b, c, d].some(part => part > 255)) return text;
    address = `${dotted[1]}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = address.split("::");
  if (halves.length > 2) return text;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const filler = halves.length === 2 ? 8 - head.length - tail.length : 0;
  if (filler < (halves.length === 2 ? 1 : 0)) return text;
  const groups = [...head, ...Array(filler).fill("0"), ...tail];
  if (groups.length !== 8 || groups.some(group => !/^[0-9a-f]{1,4}$/.test(group))) return text;
  return `${groups.slice(0, 4).map(group => parseInt(group, 16).toString(16)).join(":")}::/64`;
}

/**
 * @param binding - the Cloudflare Rate Limiting binding for this endpoint (env.RATE_LIMIT_*)
 * @param key - clientKey(request), or a userKey for an already-authenticated endpoint
 */
export async function checkRateLimit(binding, key) {
  const result = await binding.limit({ key });
  return result.success;
}
