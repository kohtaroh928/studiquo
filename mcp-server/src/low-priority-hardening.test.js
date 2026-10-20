// The smaller hardening items: IPv6 counted per /64, longer friend codes, the
// operator's maintenance / minimum-build switches, the cross-site check on admin
// writes, and the absolute lifetime of a login.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { register } from "node:module";

// user-registry.ts extends the real DurableObject from "cloudflare:workers",
// which only exists inside the Workers runtime; stand in for that one import
// (the same approach mcp-inbox.test.js takes) so the real class runs here.
register(
  "data:text/javascript," + encodeURIComponent(`
    export function resolve(specifier, context, next) {
      if (specifier === "cloudflare:workers") return { url: "cloudflare-workers-shim:", shortCircuit: true };
      return next(specifier, context);
    }
    export function load(url, context, next) {
      if (url === "cloudflare-workers-shim:") {
        return { format: "module", shortCircuit: true,
          source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }" };
      }
      return next(url, context);
    }
  `),
  import.meta.url
);

const { UserRegistry } = await import("./user-registry.ts");
const { default: worker } = await import("./app.ts");
const { normalizeIP, clientKey } = await import("./rate-limit.ts");
const { appGateRejection } = await import("./app-gate.ts");
const { isCrossSiteWrite } = await import("./access.ts");
const { ACCESS_ENV, ACCESS_HEADERS } = await import("./test-access.ts");

const hash = value => createHash("sha256").update(value).digest("hex");
const noopCtx = { waitUntil() {} };

// ---- IPv6 is counted per /64 ------------------------------------------------

test("an IPv4 address is its own key", () => {
  assert.equal(normalizeIP("203.0.113.5"), "203.0.113.5");
});

test("two IPv6 addresses in one /64 share a key, and another /64 does not", () => {
  const a = normalizeIP("2001:db8:1:2:aaaa:bbbb:cccc:dddd");
  const b = normalizeIP("2001:db8:1:2:1:2:3:4");
  const other = normalizeIP("2001:db8:1:3:aaaa:bbbb:cccc:dddd");
  assert.equal(a, "2001:db8:1:2::/64");
  assert.equal(b, a);
  assert.notEqual(other, a);
});

test("compressed, upper-case and zone-suffixed IPv6 forms reduce to the same prefix", () => {
  assert.equal(normalizeIP("2001:DB8:0:0:1::5"), "2001:db8:0:0::/64");
  assert.equal(normalizeIP("2001:db8::1"), "2001:db8:0:0::/64");
  assert.equal(normalizeIP("fe80::1%en0"), "fe80:0:0:0::/64");
  assert.equal(normalizeIP("::1"), "0:0:0:0::/64");
  assert.equal(normalizeIP("::"), "0:0:0:0::/64");
});

test("an IPv4-mapped IPv6 address is the IPv4 address", () => {
  assert.equal(normalizeIP("::ffff:203.0.113.5"), "203.0.113.5");
});

test("something that is not an address is returned as it came, never guessed at", () => {
  assert.equal(normalizeIP("not:an:address:zz"), "not:an:address:zz");
  assert.equal(normalizeIP("1:2:3:4:5:6:7:8:9"), "1:2:3:4:5:6:7:8:9");
  assert.equal(normalizeIP("1::2::3"), "1::2::3");
  assert.equal(normalizeIP(""), null);
  assert.equal(normalizeIP(undefined), null);
});

test("clientKey applies the /64 rule, and still says unknown without a header", () => {
  const request = ip => new Request("https://example.test/x", { headers: ip ? { "cf-connecting-ip": ip } : {} });
  assert.equal(clientKey(request("2001:db8:9:9:1:1:1:1")), clientKey(request("2001:db8:9:9:2:2:2:2")));
  assert.equal(clientKey(request("203.0.113.5")), "203.0.113.5");
  assert.equal(clientKey(request(null)), "unknown");
});

// ---- Friend codes -----------------------------------------------------------

function registryEnvironment() {
  const values = new Map();
  return {
    values,
    STUDIQUO_DATA: {
      async get(key, type) { const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key, value) { values.set(key, value); },
    },
  };
}

test("a new account gets a 10-character friend code and invite token", async () => {
  const env = registryEnvironment();
  const registry = new UserRegistry({ storage: {}, blockConcurrencyWhile: fn => fn() }, env);
  const user = await registry.ensureUser("account-key", "Alice");
  assert.match(user.code, /^[A-HJ-NP-Z2-9]{10}$/);
  assert.match(user.linkToken, /^[A-HJ-NP-Z2-9]{10}$/);
  assert.notEqual(user.code, user.linkToken);
  assert.equal(env.values.get(`chat:code:${user.code}`), "account-key");
});

test("an account that already has a 7-character code keeps it", async () => {
  const env = registryEnvironment();
  env.values.set("chat:user:old", JSON.stringify({ key: "old", name: "Old", code: "ABCDEFG", linkToken: "HJKLMNP", friends: [] }));
  const registry = new UserRegistry({ storage: {}, blockConcurrencyWhile: fn => fn() }, env);
  const user = await registry.ensureUser("old", "Old");
  assert.equal(user.code, "ABCDEFG");
});

// ---- Maintenance mode and the minimum build ------------------------------------

const gate = (path, { env = {}, userAgent } = {}) =>
  appGateRejection(new Request(`https://example.test${path}`, { headers: userAgent ? { "user-agent": userAgent } : {} }), env, new URL(`https://example.test${path}`));

test("with both switches unset nothing is turned away", () => {
  assert.equal(gate("/api/plan", { userAgent: "studiquo/1 CFNetwork/1 Darwin/27" }), null);
  assert.equal(gate("/mcp"), null);
});

test("maintenance mode answers 503 with Retry-After on app, MCP and OAuth routes", async () => {
  const env = { MAINTENANCE_MODE: "true" };
  for (const path of ["/api/plan", "/api/chat/inbox", "/api/auth/local/login", "/mcp", "/oauth/token", "/api/passkeys/status"]) {
    const response = gate(path, { env });
    assert.equal(response.status, 503, path);
    assert.equal(response.headers.get("retry-after"), "300");
    assert.equal((await response.json()).code, "maintenance");
  }
});

test("maintenance mode leaves the health check, association file, public pages and admin alone", () => {
  const env = { MAINTENANCE_MODE: "true" };
  for (const path of ["/health", "/.well-known/apple-app-site-association", "/invite", "/terms", "/api/announcements", "/api/admin/stats", "/api/admin/revenuecat-webhook", "/admin"]) {
    assert.equal(gate(path, { env }), null, path);
  }
});

test("an app build below MIN_APP_BUILD is told to update; a newer one and other clients are not", async () => {
  const env = { MIN_APP_BUILD: "5" };
  const old = gate("/api/plan", { env, userAgent: "studiquo/4 CFNetwork/3896.100.1.2.1 Darwin/27.0.0" });
  assert.equal(old.status, 426);
  assert.equal((await old.json()).code, "app_update_required");
  assert.equal(gate("/api/plan", { env, userAgent: "studiquo/5 CFNetwork/3896.100.1.2.1 Darwin/27.0.0" }), null);
  assert.equal(gate("/api/plan", { env, userAgent: "studiquo/12 CFNetwork/1 Darwin/27" }), null);
  assert.equal(gate("/api/plan", { env, userAgent: "Mozilla/5.0 (Macintosh)" }), null);
  assert.equal(gate("/api/plan", { env, userAgent: "codex-mcp-client/0.160.1" }), null);
  assert.equal(gate("/api/plan", { env }), null, "no User-Agent at all");
  assert.equal(gate("/mcp", { env, userAgent: "studiquo/1 CFNetwork/1" }), null, "only the app's own API is gated by build");
});

test("a malformed MIN_APP_BUILD turns the check off instead of locking everyone out", () => {
  for (const value of ["abc", "", "0", "-3"]) {
    assert.equal(gate("/api/plan", { env: { MIN_APP_BUILD: value }, userAgent: "studiquo/1 CFNetwork/1" }), null, value);
  }
});

test("the gate runs in front of the whole Worker", async () => {
  const response = await worker.fetch(new Request("https://example.test/api/plan", { headers: { "user-agent": "studiquo/1 CFNetwork/1" } }),
    { MIN_APP_BUILD: "9" }, noopCtx);
  assert.equal(response.status, 426);
  const health = await worker.fetch(new Request("https://example.test/health"), { MAINTENANCE_MODE: "true" }, noopCtx);
  assert.equal(health.status, 200);
});

// ---- Cross-site writes to the admin API -------------------------------------

const urlOf = "https://example.test/api/admin/x";

test("isCrossSiteWrite refuses another origin or a cross-site fetch, and lets reads and origin-less calls through", () => {
  const req = (method, headers = {}) => new Request(urlOf, { method, headers });
  const url = new URL(urlOf);
  assert.equal(isCrossSiteWrite(req("POST", { origin: "https://evil.example" }), url), true);
  assert.equal(isCrossSiteWrite(req("DELETE", { "sec-fetch-site": "cross-site" }), url), true);
  assert.equal(isCrossSiteWrite(req("POST", { "sec-fetch-site": "same-site" }), url), true);
  assert.equal(isCrossSiteWrite(req("POST", { origin: "https://example.test", "sec-fetch-site": "same-origin" }), url), false);
  assert.equal(isCrossSiteWrite(req("POST"), url), false, "curl and scripts name no origin");
  assert.equal(isCrossSiteWrite(req("POST", { "sec-fetch-site": "none" }), url), false, "typed into the address bar / extension");
  assert.equal(isCrossSiteWrite(req("GET", { origin: "https://evil.example" }), url), false);
});

test("an admin write from another origin is refused even with a valid Access login", async () => {
  const env = { ...ACCESS_ENV };
  const post = headers => worker.fetch(new Request("https://example.test/api/admin/issue-reports/import-legacy", {
    method: "POST", headers: { ...ACCESS_HEADERS, ...headers },
  }), env, noopCtx);
  assert.equal((await post({ origin: "https://evil.example" })).status, 403);
  assert.equal((await post({ "sec-fetch-site": "cross-site" })).status, 403);
  // From the dashboard itself the request is not turned away by this check.
  assert.notEqual((await post({ origin: "https://example.test", "sec-fetch-site": "same-origin" })).status, 403);
  assert.notEqual((await post({})).status, 403);
});

// ---- A login has an absolute lifetime -----------------------------------------

const DAY = 24 * 60 * 60 * 1000;

function sessionEnvironment(extra = {}) {
  const values = new Map();
  return {
    values,
    STUDIQUO_DATA: {
      async get(key, type) { const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return { keys: [], list_complete: true }; },
    },
    ...extra,
  };
}

// A login whose current token is `tokenAgeDays` old, descended from one that began `originAgeDays` ago.
async function sessionAged(env, { tokenAgeDays, originAgeDays, withOrigin = true }) {
  const issuedAtMs = Date.now() - tokenAgeDays * DAY;
  const token = `${Math.floor(issuedAtMs / 1000)}.${"t".repeat(40)}`;
  const record = { sub: "person", issuedAt: Math.floor(issuedAtMs / 1000), issuedAtMs };
  if (withOrigin) record.originIssuedAtMs = Date.now() - originAgeDays * DAY;
  env.values.set(`session:${hash(token)}`, JSON.stringify(record));
  return token;
}

const refresh = (env, token) => worker.fetch(new Request("https://example.test/api/session/refresh", {
  method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  body: JSON.stringify({ randomValue: "n".repeat(40) }),
}), env, noopCtx);

test("a login younger than the limit is renewed, and the new token keeps the original start", async () => {
  const env = sessionEnvironment();
  const token = await sessionAged(env, { tokenAgeDays: 10, originAgeDays: 100 });
  const result = await (await refresh(env, token)).json();
  assert.equal(result.refreshed, true);
  const stored = JSON.parse(env.values.get(`session:${hash(result.token)}`));
  const original = JSON.parse(env.values.get(`session:${hash(token)}`));
  assert.equal(stored.originIssuedAtMs, original.originIssuedAtMs, "renewing does not restart the clock");
});

test("a login older than a year is no longer renewed", async () => {
  const env = sessionEnvironment();
  const token = await sessionAged(env, { tokenAgeDays: 10, originAgeDays: 400 });
  const result = await (await refresh(env, token)).json();
  assert.equal(result.refreshed, false);
  assert.equal(result.reason, "session_too_old");
  assert.equal(result.token, undefined);
});

test("SESSION_MAX_DAYS moves the limit", async () => {
  const env = sessionEnvironment({ SESSION_MAX_DAYS: "30" });
  const young = await sessionAged(env, { tokenAgeDays: 8, originAgeDays: 20 });
  assert.equal((await (await refresh(env, young)).json()).refreshed, true);
  const old = await sessionAged(env, { tokenAgeDays: 9, originAgeDays: 45 });
  assert.equal((await (await refresh(env, old)).json()).refreshed, false);
});

test("a session record from before the origin was kept counts from its own issue time", async () => {
  const env = sessionEnvironment();
  const token = await sessionAged(env, { tokenAgeDays: 10, originAgeDays: 0, withOrigin: false });
  const result = await (await refresh(env, token)).json();
  assert.equal(result.refreshed, true);
  const stored = JSON.parse(env.values.get(`session:${hash(result.token)}`));
  const original = JSON.parse(env.values.get(`session:${hash(token)}`));
  assert.equal(stored.originIssuedAtMs, original.issuedAtMs);
});

test("every new login starts its own clock", async () => {
  const { mintSession } = await import("./session.ts");
  const env = sessionEnvironment();
  const token = await mintSession(env, "person", "r".repeat(40));
  const stored = JSON.parse(env.values.get(`session:${hash(token)}`));
  assert.equal(stored.originIssuedAtMs, stored.issuedAtMs);
});
