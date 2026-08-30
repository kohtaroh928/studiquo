import assert from "node:assert/strict";
import test from "node:test";
import { handleAI } from "./ai.js";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZkAAAAASUVORK5CYII=";

function environment() {
  const values = new Map();
  return {
    GEMINI_API_KEY: "test-key",
    STUDIQUO_DATA: {
      async get(key) { return values.get(key) ?? null; },
      async put(key, value) { values.set(key, value); },
    },
  };
}

function executionContext() {
  const promises = [];
  return {
    promises,
    waitUntil(promise) { promises.push(promise); },
  };
}

test("chat forwards a required PNG to Gemini and confirms receipt", async () => {
  const originalFetch = globalThis.fetch;
  let upstreamBody;
  globalThis.fetch = async (_url, options) => {
    upstreamBody = JSON.parse(options.body);
    const event = { candidates: [{ content: { parts: [{ text: "画像を確認しました。" }] } }] };
    return new Response(`data: ${JSON.stringify(event)}\n\n`, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  };

  try {
    const ctx = executionContext();
    const request = new Request("https://example.test/api/ai/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        messages: [{ role: "user", text: "この切り抜きを説明して" }],
        images: [PNG],
        requiresImage: true,
      }),
    });
    const response = await handleAI(new URL(request.url), request, environment(), "device", ctx);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-studiquo-images-received"), "1");
    assert.match(await response.text(), /画像を確認しました/);
    await Promise.all(ctx.promises);

    const parts = upstreamBody.contents[0].parts;
    const imagePart = parts.find(part => part.inlineData);
    assert.equal(imagePart.inlineData.mimeType, "image/png");
    assert.equal(imagePart.inlineData.data, PNG);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("chat rejects a request that says an image is required but has none", async () => {
  const ctx = executionContext();
  const request = new Request("https://example.test/api/ai/chat", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [{ role: "user", text: "この切り抜きを説明して" }],
      images: [],
      requiresImage: true,
    }),
  });
  const response = await handleAI(new URL(request.url), request, environment(), "device", ctx);
  assert.equal(response.status, 400);
  assert.match(await response.text(), /画像/);
});
