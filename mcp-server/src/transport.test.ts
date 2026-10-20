// @ts-nocheck 型の付け方は docs/notes/ts-migration.md の「テストの型検査」を参照。
import assert from "node:assert/strict";
import test from "node:test";
import { register } from "node:module";

// app.ts reaches Durable Object classes that extend "cloudflare:workers"
// (see features.test.js for the same stand-in).
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

const { HSTS_VALUE, plainHttpResponse, withTransportHeaders } = await import("./transport.ts");
const { default: worker } = await import("./app.ts");
const noopCtx = { waitUntil() {} };

test("every kind of response from the Worker carries Strict-Transport-Security", async () => {
  for (const path of ["/health", "/invite?token=ABCD1234", "/invite", "/api/plan", "/no-such-route", "/terms", "/.well-known/apple-app-site-association"]) {
    const response = await worker.fetch(new Request(`https://example.test${path}`), {}, noopCtx);
    assert.equal(response.headers.get("strict-transport-security"), HSTS_VALUE, path);
  }
  assert.equal(HSTS_VALUE, "max-age=31536000", "no includeSubDomains and no preload");
});

test("a response whose headers cannot be changed is copied, and a WebSocket handshake is left alone", async () => {
  const frozen = Response.redirect("https://example.test/x", 302); // headers of this one are immutable
  const copied = withTransportHeaders(frozen);
  assert.equal(copied.headers.get("strict-transport-security"), HSTS_VALUE);
  assert.equal(copied.status, 302);
  assert.equal(copied.headers.get("location"), "https://example.test/x");

  const upgrade = { status: 101, headers: new Headers(), webSocket: {} };
  assert.equal(withTransportHeaders(upgrade), upgrade, "rebuilding a 101 would drop its socket");
  assert.equal(upgrade.headers.has("strict-transport-security"), false);

  const already = new Response("x", { headers: { "strict-transport-security": "max-age=1" } });
  assert.equal(withTransportHeaders(already).headers.get("strict-transport-security"), "max-age=1", "an existing header is kept");
});

test("plain http is answered before the handler runs: GET goes to https, anything else is refused", async () => {
  const get = await worker.fetch(new Request("http://api.example.test/api/plan?x=1", { headers: { authorization: "Bearer secret" } }), {}, noopCtx);
  assert.equal(get.status, 308);
  assert.equal(get.headers.get("location"), "https://api.example.test/api/plan?x=1");
  assert.equal(get.headers.get("strict-transport-security"), HSTS_VALUE);

  for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
    const response = await worker.fetch(new Request("http://api.example.test/api/chat/inbox", { method, headers: { authorization: "Bearer secret" } }), {}, noopCtx);
    assert.equal(response.status, 403, method);
    assert.equal((await response.json()).code, "https_required");
  }
});

test("plain http to /health is also sent to https, and local development over http is untouched", async () => {
  assert.equal((await worker.fetch(new Request("http://api.example.test/health"), {}, noopCtx)).status, 308);
  for (const host of ["localhost:8787", "127.0.0.1:8787", "[::1]:8787", "dev.localhost:8787"]) {
    const response = await worker.fetch(new Request(`http://${host}/health`), {}, noopCtx);
    assert.equal(response.status, 200, host);
  }
  const request = new Request("http://api.example.test/health");
  assert.equal(plainHttpResponse(new Request("https://api.example.test/health"), new URL("https://api.example.test/health")), null);
  assert.notEqual(plainHttpResponse(request, new URL(request.url)), null);
});

test("HEAD over plain http is sent to https like GET", async () => {
  const response = await worker.fetch(new Request("http://api.example.test/api/plan", { method: "HEAD" }), {}, noopCtx);
  assert.equal(response.status, 308);
  assert.equal(response.headers.get("location"), "https://api.example.test/api/plan");
});

test("a failing handler still answers with the transport header", async () => {
  const broken = { STUDIQUO_DATA: { get() { throw new Error("KV down"); }, put() { throw new Error("KV down"); } } };
  const original = console.error;
  console.error = () => {};
  try {
    const response = await worker.fetch(new Request("https://example.test/api/plan", { headers: { authorization: "Bearer x.y" } }), broken, noopCtx);
    assert.ok(response.status >= 400);
    assert.equal(response.headers.get("strict-transport-security"), HSTS_VALUE);
  } finally {
    console.error = original;
  }
});

test("a streamed response is passed through unbuffered, immutable headers or not", async () => {
  const chunks = ["data: one\n\n", "data: two\n\n"];
  const encoder = new TextEncoder();
  let pulled = 0;
  const body = new ReadableStream({
    pull(controller) {
      if (pulled < chunks.length) controller.enqueue(encoder.encode(chunks[pulled++]));
      else controller.close();
    },
  });
  const wrapped = withTransportHeaders(new Response(body, { headers: { "content-type": "text/event-stream" } }));
  assert.equal(wrapped.headers.get("content-type"), "text/event-stream");
  assert.equal(wrapped.headers.get("strict-transport-security"), HSTS_VALUE);
  assert.equal(pulled, 0, "nothing was read while the header was added");
  assert.equal(await wrapped.text(), chunks.join(""));
});

test("other methods over plain http are refused too, and the refusal says why", async () => {
  const response = await worker.fetch(new Request("http://api.example.test/api/chat/inbox", { method: "OPTIONS" }), {}, noopCtx);
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "https_required");
  const upper = await worker.fetch(new Request("HTTP://API.EXAMPLE.TEST:80/health"), {}, noopCtx);
  assert.equal(upper.status, 308);
  assert.equal(upper.headers.get("location"), "https://api.example.test/health");
});
