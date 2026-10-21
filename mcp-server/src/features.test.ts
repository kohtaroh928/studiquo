import assert from "node:assert/strict";
import test from "node:test";
import { register } from "node:module";
import { partialCtx, partialEnv, type LooseEnv, type Untyped } from "./test-env.ts";

// app.ts pulls in Durable Object classes that extend "cloudflare:workers", which
// only exists in the Workers runtime; stand in for that one import (as
// low-priority-hardening.test.js does).
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

const { FEATURES, disabledFeatures, featureDisabled, featureForPath, featureGateRejection } = await import("./features.ts");
const { appGateRejection } = await import("./app-gate.ts");
const { default: worker } = await import("./app.ts");
const { sendPush } = await import("./push.ts");
const { sendVerificationCode } = await import("./email-verification.ts");
const { sendPasskeyNotice } = await import("./passkey-policy.ts");

const noopCtx = partialCtx({ waitUntil() {}, passThroughOnException() {} });
const gate = (path: string, env: Untyped) => appGateRejection(new Request(`https://example.test${path}`, { method: "POST" }), env, new URL(`https://example.test${path}`));

test("an unset or empty DISABLED_FEATURES stops nothing", () => {
  for (const env of [{}, { DISABLED_FEATURES: "" }, { DISABLED_FEATURES: " , " }, undefined]) {
    assert.equal(disabledFeatures(partialEnv(env!)).size, 0);
  }
  for (const path of ["/api/chat/inbox", "/api/ai/chat", "/mcp", "/api/auth/local/login"]) assert.equal(gate(path, {}), null, path);
});

test("names are case-insensitive, trimmed, and unknown names are ignored", () => {
  assert.deepEqual([...disabledFeatures(partialEnv({ DISABLED_FEATURES: " Chat , EMAIL,nonsense,,push " }))].sort(), ["chat", "email", "push"]);
  assert.equal(featureDisabled(partialEnv({ DISABLED_FEATURES: "CHAT" }), "chat"), true);
  assert.equal(featureDisabled(partialEnv({ DISABLED_FEATURES: "chat" }), "ai"), false);
});

test("every route belongs to the feature it should", () => {
  const table = {
    "/api/ai/chat": "ai", "/api/ai/rubric": "ai", "/api/ai/usage": "ai",
    "/api/chat/inbox": "chat", "/api/chat/groups": "chat", "/api/chat/devices": "chat",
    "/api/document/invites": "collab", "/api/document/abc/ws": "collab",
    "/mcp": "mcp", "/oauth/token": "mcp", "/oauth/authorize": "mcp", "/api/mcp/pairing-code": "mcp", "/api/mcp/inbox": "mcp",
    "/api/auth/apple": "signin", "/api/auth/google": "signin", "/api/auth/local/login": "signin",
    "/api/auth/email/confirm-code": "signin", "/api/passkeys/login/options": "signin", "/api/passkeys/login/verify": "signin",
    "/api/auth/email/send-code": "email",
  };
  for (const [path, feature] of Object.entries(table)) assert.equal(featureForPath(path), feature, path);
  assert.ok(Object.values(table).every(feature => FEATURES.includes(feature)));
});

test("the account's own exits and the public pages are never covered", () => {
  for (const path of [
    "/health", "/api/account", "/api/account/library-id", "/api/session/revoke", "/api/session/refresh",
    "/api/plan", "/api/snapshot", "/api/announcements", "/api/admin/stats", "/api/passkeys/status",
    "/api/passkeys/register/options", "/api/passkeys/remove-all", "/privacy", "/terms", "/invite",
    "/.well-known/apple-app-site-association",
  ]) {
    assert.equal(featureForPath(path), null, path);
    assert.equal(gate(path, { DISABLED_FEATURES: FEATURES.join(",") }), null, path);
  }
});

test("a stopped feature answers 503 feature_disabled with its name and Retry-After; the others keep working", async () => {
  const env = partialEnv({ DISABLED_FEATURES: "chat" });
  const response = gate("/api/chat/inbox", env);
  assert.equal(response!.status, 503);
  assert.equal(response!.headers.get("retry-after"), "300");
  assert.deepEqual(await response!.json(), {
    error: "この機能は一時的に停止しています。しばらくしてからもう一度お試しください。",
    code: "feature_disabled",
    feature: "chat",
  });
  for (const path of ["/api/ai/chat", "/mcp", "/api/auth/local/login", "/api/document/invites", "/api/auth/email/send-code"]) {
    assert.equal(gate(path, env), null, path);
  }
});

test("each feature stops only its own routes", async () => {
  const probes = { ai: "/api/ai/chat", chat: "/api/chat/inbox", collab: "/api/document/invites", mcp: "/mcp", signin: "/api/auth/google", email: "/api/auth/email/send-code" };
  for (const [feature, path] of Object.entries(probes)) {
    const env = partialEnv({ DISABLED_FEATURES: feature });
    assert.equal((await gate(path, env)!.json()).feature, feature);
    for (const [other, otherPath] of Object.entries(probes)) {
      if (other !== feature) assert.equal(gate(otherPath, env), null, `${feature} must not stop ${other}`);
    }
  }
});

test("maintenance mode comes first, and a stopped feature does not outrank the update prompt", async () => {
  const both = gate("/api/chat/inbox", { MAINTENANCE_MODE: "true", DISABLED_FEATURES: "chat" });
  assert.equal((await both!.json()).code, "maintenance");
  assert.equal(featureGateRejection(partialEnv({ DISABLED_FEATURES: "chat" }), "/api/plan"), null);
});

test("/health lists only the features that took effect, and the Worker enforces the switch", async () => {
  const health = await worker.fetch(new Request("https://example.test/health"), partialEnv({ DISABLED_FEATURES: "chat, bogus ,push" }), noopCtx);
  assert.equal(health.status, 200);
  assert.deepEqual((await health.json()).disabledFeatures.sort(), ["chat", "push"]);
  const plain = await (await worker.fetch(new Request("https://example.test/health"), partialEnv({}), noopCtx)).json();
  assert.equal("disabledFeatures" in plain, false, "nothing is added to /health when nothing is stopped");

  const stopped = await worker.fetch(new Request("https://example.test/api/chat/inbox", { headers: { authorization: "Bearer x" } }), partialEnv({ DISABLED_FEATURES: "chat" }), noopCtx);
  assert.equal(stopped.status, 503);
  assert.equal((await stopped.json()).code, "feature_disabled");
  const other = await worker.fetch(new Request("https://example.test/api/plan"), partialEnv({ DISABLED_FEATURES: "chat" }), noopCtx);
  assert.equal(other.status, 401, "an unrelated route still reaches its own checks");
});

test("a stopped push sends nothing and reads nothing", async () => {
  const env = partialEnv({
    DISABLED_FEATURES: "push", APNS_TEAM_ID: "T", APNS_TOPIC: "x",
    STUDIQUO_DATA: { get() { throw new Error("must not read devices"); }, list() { throw new Error("no"); } },
  });
  assert.deepEqual(await sendPush(env, "user", { title: "t", body: "b" }, { fetchImpl: () => { throw new Error("must not send"); } }), []);
});

test("stopped email sends nothing and stores no code", async () => {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = (...args) => { calls.push(args); throw new Error("must not send"); };
  try {
    const env = partialEnv({ DISABLED_FEATURES: "email", RESEND_API_KEY: "k", STUDIQUO_DATA: { put() { throw new Error("must not store a code"); } } });
    await assert.rejects(sendVerificationCode(env, "someone@example.com"), /paused/);
    await sendPasskeyNotice(env, "someone@example.com", "subject", ["line"]);
    assert.equal(calls.length, 0);
  } finally {
    globalThis.fetch = original;
  }
});

test("disconnecting an AI app stays possible while mcp is stopped, and nothing else under /api/mcp does", () => {
  assert.equal(featureForPath("/api/mcp/connections/abc", "DELETE"), null);
  assert.equal(featureForPath("/api/mcp/connections/abc", "GET"), "mcp");
  assert.equal(featureForPath("/api/mcp/connections", "GET"), "mcp");
  assert.equal(featureForPath("/api/mcp/pairing-code", "POST"), "mcp");
  const env = partialEnv({ DISABLED_FEATURES: "mcp" });
  const request = new Request("https://example.test/api/mcp/connections/abc", { method: "DELETE" });
  assert.equal(appGateRejection(request, env, new URL(request.url)), null);
});

test("a name that stops nothing is logged once and does not take effect", () => {
  const lines: any[] = [];
  const original = console.warn;
  console.warn = line => lines.push(line);
  try {
    assert.equal(disabledFeatures(partialEnv({ DISABLED_FEATURES: "chats" })).size, 0);
    assert.equal(disabledFeatures(partialEnv({ DISABLED_FEATURES: "chats" })).size, 0);
    assert.equal(disabledFeatures(partialEnv({ DISABLED_FEATURES: "chat,Chats" })).has("chat"), true);
  } finally {
    console.warn = original;
  }
  assert.equal(lines.length, 1, "once per name");
  assert.equal(JSON.parse(lines[0]).name, "chats");
});

test("the account's exits go through the Worker while every feature is stopped", async () => {
  const env = partialEnv({ DISABLED_FEATURES: FEATURES.join(",") });
  for (const [method, path] of [["DELETE", "/api/account"], ["POST", "/api/session/revoke"], ["POST", "/api/session/refresh"]]) {
    const response = await worker.fetch(new Request(`https://example.test${path}`, { method }), env, noopCtx);
    assert.equal(response.status, 401, `${method} ${path} must reach its own auth check, not a 503`);
  }
});

test("the AI switch is separate from the provider approval and either one stops AI", async () => {
  const request = new Request("https://example.test/api/ai/chat", { method: "POST" });
  const url = new URL(request.url);
  assert.equal((await appGateRejection(request, partialEnv({ DISABLED_FEATURES: "ai", AI_PROVIDER_APPROVED: "true" }), url)!.json()).feature, "ai");
  assert.equal(appGateRejection(request, partialEnv({ AI_PROVIDER_APPROVED: "false" }), url), null, "the approval flag answers later, in the AI handler");
});
