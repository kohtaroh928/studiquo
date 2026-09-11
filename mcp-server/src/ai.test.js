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

test("review streams back a structured result for a study question", async () => {
  const originalFetch = globalThis.fetch;
  let upstreamBody;
  globalThis.fetch = async (_url, options) => {
    upstreamBody = JSON.parse(options.body);
    const resultJSON = JSON.stringify({
      isStudyRelevant: true,
      explanationMarkdown: "# 三角関数の加法定理\n- sin(a+b) = sin a cos b + cos a sin b",
      quiz: [{ question: "sin(a+b) の展開は？", answer: "sin a cos b + cos a sin b" }],
    });
    const event = { candidates: [{ content: { parts: [{ text: resultJSON }] } }] };
    return new Response(`data: ${JSON.stringify(event)}\n\n`, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  };

  try {
    const ctx = executionContext();
    const request = new Request("https://example.test/api/ai/review", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: "加法定理の証明を教えて" }),
    });
    const response = await handleAI(new URL(request.url), request, environment(), "device", ctx);
    assert.equal(response.status, 200);
    const body = await response.text();
    await Promise.all(ctx.promises);
    assert.match(body, /isStudyRelevant.*true/s);
    assert.match(body, /加法定理/);

    assert.equal(upstreamBody.generationConfig.responseMimeType, "application/json");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("review rejects a request with no question", async () => {
  const ctx = executionContext();
  const request = new Request("https://example.test/api/ai/review", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ question: "" }),
  });
  const response = await handleAI(new URL(request.url), request, environment(), "device", ctx);
  assert.equal(response.status, 400);
});

test("review enforces its own daily quota independently of chat", async () => {
  const env = environment();
  const ctx = executionContext();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    const event = { candidates: [{ content: { parts: [{ text: '{"isStudyRelevant":false,"explanationMarkdown":"","quiz":[]}' }] } }] };
    return new Response(`data: ${JSON.stringify(event)}\n\n`, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  };

  try {
    env.REVIEW_DAILY_LIMIT = "1";
    const makeRequest = () => new Request("https://example.test/api/ai/review", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: "テスト" }),
    });

    const first = await handleAI(new URL(makeRequest().url), makeRequest(), env, "device", ctx);
    assert.equal(first.status, 200);
    await first.text();
    await Promise.all(ctx.promises);

    const second = await handleAI(new URL(makeRequest().url), makeRequest(), env, "device", ctx);
    assert.equal(second.status, 429);

    // The review bucket is exhausted, but chat must be unaffected — a
    // student mid-lesson shouldn't lose AI replies because the review
    // feature (a background extra) hit its own separate cap.
    globalThis.fetch = async () => {
      const event = { candidates: [{ content: { parts: [{ text: "こんにちは" }] } }] };
      return new Response(`data: ${JSON.stringify(event)}\n\n`, {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      });
    };
    const chatRequest = new Request("https://example.test/api/ai/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", text: "こんにちは" }] }),
    });
    const chatResponse = await handleAI(new URL(chatRequest.url), chatRequest, env, "device", ctx);
    assert.equal(chatResponse.status, 200);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
