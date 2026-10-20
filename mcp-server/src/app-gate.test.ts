import assert from "node:assert/strict";
import test from "node:test";
import { appGateRejection } from "./app-gate.ts";
import { partialEnv } from "./test-env.ts";

function callGate(pathname, { env = {}, userAgent }: { env?: any; userAgent?: string } = {}) {
  const headers = new Headers();
  if (userAgent !== undefined) headers.set("user-agent", userAgent);
  const url = new URL(`https://api.studiquo.app${pathname}`);
  const request = new Request(url, { headers });
  return appGateRejection(request, env, url);
}

test("returns null for all routes when both switches are unset", () => {
  for (const path of ["/api/ai/chat", "/mcp", "/oauth/authorize", "/api/admin/stats", "/api/announcements", "/privacy"]) {
    assert.equal(callGate(path, { userAgent: "studiquo/1 CFNetwork/1400" }), null);
  }
});

test("MAINTENANCE_MODE blocks app, MCP, and OAuth routes with 503 and Retry-After but keeps admin, announcements, and public pages up", async () => {
  const env = partialEnv({ MAINTENANCE_MODE: "true" });

  for (const guarded of ["/api/ai/chat", "/api/passkeys/login/options", "/mcp", "/oauth/token"]) {
    const response = callGate(guarded, { env });
    assert.ok(response, `expected ${guarded} to be gated`);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("retry-after"), "300");
    const body = await response.json();
    assert.equal(body.code, "maintenance");
  }

  for (const exempt of ["/api/admin/issue-reports", "/api/announcements", "/privacy", "/terms", "/invite/ABC123", "/.well-known/apple-app-site-association"]) {
    assert.equal(callGate(exempt, { env }), null, `expected ${exempt} to stay open during maintenance`);
  }
});

test("MIN_APP_BUILD rejects older iOS app builds with 426 and allows current or newer builds and non-app clients", async () => {
  const env = partialEnv({ MIN_APP_BUILD: "42" });

  const oldBuild = callGate("/api/ai/chat", { env, userAgent: "studiquo/41 CFNetwork/1498.700.2 Darwin/23.6.0" });
  assert.ok(oldBuild);
  assert.equal(oldBuild.status, 426);
  assert.equal((await oldBuild.json()).code, "app_update_required");

  const exactBuild = callGate("/api/ai/chat", { env, userAgent: "studiquo/42 CFNetwork/1498.700.2" });
  assert.equal(exactBuild, null);

  const newerBuild = callGate("/api/ai/chat", { env, userAgent: "studiquo/100" });
  assert.equal(newerBuild, null);

  const browserOrMcpClient = callGate("/api/ai/chat", { env, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X)" });
  assert.equal(browserOrMcpClient, null);

  const mcpRouteWithOldHeader = callGate("/mcp", { env, userAgent: "studiquo/1" });
  assert.equal(mcpRouteWithOldHeader, null, "MIN_APP_BUILD only gates /api/* routes");
});
