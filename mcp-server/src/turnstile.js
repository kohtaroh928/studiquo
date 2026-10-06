// Cloudflare Turnstile (CAPTCHA) verification for the endpoints that can be
// worked by a script: signing in after failed attempts, and sending a
// verification code.
//
// The app shows the Turnstile widget and gets back a one-time token; this
// module only checks that token with Cloudflare. Turnstile is optional until
// configured: with no TURNSTILE_SECRET + TURNSTILE_SITE_KEY nothing asks for a
// challenge, so deploying this code before the keys exist changes nothing.
//
// Once it IS configured it fails closed — if Cloudflare can't be reached the
// answer is "unavailable", never "let it through" — because an attacker can't
// make Cloudflare's own service go down on demand, and a silent bypass during
// an outage would be the worst time to have one.

const SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const TIMEOUT_MS = 3_000;
// Cloudflare documents tokens as at most 2048 characters.
const MAX_TOKEN_LENGTH = 2_048;

let warnedHalfConfigured = false;

/** Test hook: lets the once-per-isolate warning fire again. */
export function resetCaptchaWarnings() {
  warnedHalfConfigured = false;
}

export function captchaEnabled(env) {
  const enabled = Boolean(env.TURNSTILE_SECRET && env.TURNSTILE_SITE_KEY);
  // One of the two set and not the other almost always means a deploy dropped
  // one (vars in wrangler.jsonc overwrite the dashboard on every deploy), and
  // the protection silently went off. Say so, once per isolate.
  if (!enabled && Boolean(env.TURNSTILE_SECRET) !== Boolean(env.TURNSTILE_SITE_KEY) && !warnedHalfConfigured) {
    warnedHalfConfigured = true;
    console.error(JSON.stringify({ message: "turnstile is half-configured, so CAPTCHA is OFF: set both TURNSTILE_SECRET and TURNSTILE_SITE_KEY" }));
  }
  return enabled;
}

/**
 * @returns {Promise<{ ok: true } | { ok: false, code: "captcha_required" | "captcha_failed" | "captcha_unavailable" }>}
 *   `action` binds the token to the endpoint it was minted for ("login",
 *   "send-code"), so one solved for a cheap endpoint can't be spent on another.
 */
export async function verifyCaptcha(env, token, { action, ip }) {
  if (typeof token !== "string" || token.length === 0) return { ok: false, code: "captcha_required" };
  if (token.length > MAX_TOKEN_LENGTH) return { ok: false, code: "captcha_failed" };
  try {
    const form = new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token });
    if (ip && ip !== "unknown") form.set("remoteip", ip);
    const fetchImpl = typeof env.TURNSTILE_FETCH === "function" ? env.TURNSTILE_FETCH : fetch;
    const response = await fetchImpl(SITEVERIFY_URL, {
      method: "POST",
      body: form,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`siteverify responded ${response.status}`);
    const result = await response.json();
    if (result?.success !== true) {
      const codes = Array.isArray(result?.["error-codes"]) ? result["error-codes"] : [];
      // A bad token or a reused one is just a failed attempt. But a bad or
      // missing secret, or a malformed request, is OUR configuration being
      // wrong and would refuse every real user: report it as an outage and
      // log it, instead of an endless run of unexplained 403s.
      const misconfigured = codes.some(code => ["invalid-input-secret", "missing-input-secret", "bad-request", "internal-error"].includes(code));
      if (misconfigured) {
        console.error(JSON.stringify({ message: "turnstile verification misconfigured", errorCodes: codes }));
        return { ok: false, code: "captcha_unavailable" };
      }
      return { ok: false, code: "captcha_failed" };
    }
    // Real keys always echo the widget's action. Cloudflare's published test
    // keys never do (they mark the result instead), so only those may omit it.
    const isTestingKey = result.metadata?.result_with_testing_key === true;
    if (result.action !== action && !(isTestingKey && result.action === undefined)) {
      return { ok: false, code: "captcha_failed" };
    }
    // Optional second lock: the widget's allowed hostnames in the dashboard
    // are the real control, this just double-checks them when configured.
    if (env.TURNSTILE_HOSTNAME && !isTestingKey && result.hostname !== env.TURNSTILE_HOSTNAME) {
      return { ok: false, code: "captcha_failed" };
    }
    return { ok: true };
  } catch (error) {
    console.error(JSON.stringify({ message: "turnstile verification unavailable", error: error instanceof Error ? error.message : String(error) }));
    return { ok: false, code: "captcha_unavailable" };
  }
}

/** The JSON body for a refused request: what went wrong, and the public site key the app needs to show the widget. */
export function captchaRefusal(env, code) {
  const message = code === "captcha_unavailable"
    ? "The verification service is unavailable. Please try again shortly."
    : "Verification is required. If this keeps happening, update Studiquo to the latest version.";
  return {
    status: code === "captcha_unavailable" ? 503 : 403,
    body: { error: message, code, siteKey: env.TURNSTILE_SITE_KEY },
  };
}
