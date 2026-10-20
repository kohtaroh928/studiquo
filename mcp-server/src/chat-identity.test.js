import assert from "node:assert/strict";
import test from "node:test";
import { sha256Hex } from "./auth.ts";
import { resolveChatUserKey } from "./chat-identity.ts";
import { takeParsedBody, rememberParsedBody } from "./ai-body.ts";
import { callAnthropicChat, extractDeltaText } from "./anthropic.js";

test("resolveChatUserKey falls back to tokenKey when USER_REGISTRY or sub is absent", async () => {
  assert.equal(await resolveChatUserKey({}, "apple:user-1", "token-key-1"), "token-key-1");
  assert.equal(await resolveChatUserKey({ USER_REGISTRY: {} }, "", "token-key-1"), "token-key-1");
  assert.equal(await resolveChatUserKey({ USER_REGISTRY: {} }, null, "token-key-1"), "token-key-1");
});

test("resolveChatUserKey delegates to the hashed chat-account registry object when present", async () => {
  const calls = [];
  const env = {
    USER_REGISTRY: {
      getByName(name) {
        return {
          async resolveChatKey(identityHash, tokenKey) {
            calls.push({ name, identityHash, tokenKey });
            return "stable-chat-key";
          },
        };
      },
    },
  };

  const result = await resolveChatUserKey(env, "apple:00123", "session-token-hash");
  const expectedHash = await sha256Hex("chat-account:apple:00123");
  assert.equal(result, "stable-chat-key");
  assert.deepEqual(calls, [{ name: expectedHash, identityHash: expectedHash, tokenKey: "session-token-hash" }]);
});

test("rememberParsedBody and takeParsedBody hand off a parsed request body exactly once", () => {
  const req = new Request("https://api.studiquo.app/api/ai/chat", { method: "POST" });
  const payload = { model: "gemini-2.5-flash", turns: [{ role: "user", text: "こんにちは" }] };

  assert.equal(takeParsedBody(req), undefined);
  rememberParsedBody(req, payload);
  assert.equal(takeParsedBody(req), payload);
  assert.equal(takeParsedBody(req), undefined, "second take must return undefined so the body is not retained");
});

test("callAnthropicChat validates API key, attaches images only to a trailing user turn, and extractDeltaText filters SSE events", async () => {
  await assert.rejects(
    () => callAnthropicChat({}, { model: "claude-sonnet-4-20250514", systemInstruction: "sys", turns: [] }),
    /ANTHROPIC_API_KEY is not configured/
  );

  const originalFetch = globalThis.fetch;
  let captured = null;
  globalThis.fetch = async (url, init) => {
    captured = { url: String(url), init };
    return new Response("ok", { status: 200 });
  };

  try {
    await callAnthropicChat(
      { ANTHROPIC_API_KEY: "test-key-never-real" },
      {
        model: "claude-sonnet-4-20250514",
        systemInstruction: "Be concise.",
        turns: [
          { role: "user", text: "first question" },
          { role: "assistant", text: "first answer" },
          { role: "user", text: "second question with image" },
        ],
        images: ["iVBORw0KGgoAAAANSUhEUg=="],
      }
    );

    assert.equal(captured.url, "https://api.anthropic.com/v1/messages");
    assert.equal(captured.init.headers["x-api-key"], "test-key-never-real");
    assert.equal(captured.init.headers["anthropic-version"], "2023-06-01");
    const parsed = JSON.parse(captured.init.body);
    assert.equal(parsed.stream, true);
    assert.equal(parsed.messages[0].content.length, 1);
    assert.equal(parsed.messages[1].content.length, 1);
    assert.equal(parsed.messages[2].content.length, 2);
    assert.deepEqual(parsed.messages[2].content[1], {
      type: "image",
      source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgoAAAANSUhEUg==" },
    });
  } finally {
    globalThis.fetch = originalFetch;
  }

  assert.equal(extractDeltaText({ type: "content_block_delta", delta: { type: "text_delta", text: "解:" } }), "解:");
  assert.equal(extractDeltaText({ type: "content_block_delta", delta: { type: "input_json_delta", partial_json: "{}" } }), "");
  assert.equal(extractDeltaText({ type: "message_start" }), "");
  assert.equal(extractDeltaText(null), "");
});
