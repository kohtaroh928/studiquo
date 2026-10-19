import assert from "node:assert/strict";
import test from "node:test";
import { callAnthropicChat, extractDeltaText } from "./anthropic.js";
import { rememberParsedBody, takeParsedBody } from "./ai-body.js";

test("callAnthropicChat throws when ANTHROPIC_API_KEY is missing from env", async () => {
  await assert.rejects(
    () =>
      callAnthropicChat({}, {
        model: "claude-sonnet-4-5",
        systemInstruction: "You are a tutor.",
        turns: [{ role: "user", text: "Hello" }],
      }),
    /ANTHROPIC_API_KEY is not configured/
  );
});

test("callAnthropicChat sends x-api-key header (never in URL), attaches images only to the final user turn, and normalizes roles", async () => {
  const originalFetch = globalThis.fetch;
  let capturedUrl = "";
  let capturedInit = null;
  globalThis.fetch = async (url, init) => {
    capturedUrl = String(url);
    capturedInit = init;
    return new Response("data: {}\n\n", { status: 200 });
  };

  try {
    const fakeEnv = { ANTHROPIC_API_KEY: "test-placeholder-key-not-real" };
    await callAnthropicChat(fakeEnv, {
      model: "claude-sonnet-4-5",
      systemInstruction: "Teach math step by step.",
      turns: [
        { role: "user", text: "First question" },
        { role: "assistant", text: "First answer" },
        { role: "unknown-role", text: "Follow-up with image" },
      ],
      images: ["iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="],
    });

    assert.equal(capturedUrl, "https://api.anthropic.com/v1/messages");
    assert.equal(capturedUrl.includes("test-placeholder-key-not-real"), false);
    assert.equal(capturedInit.method, "POST");
    assert.equal(capturedInit.headers["x-api-key"], "test-placeholder-key-not-real");
    assert.equal(capturedInit.headers["anthropic-version"], "2023-06-01");

    const parsed = JSON.parse(capturedInit.body);
    assert.equal(parsed.model, "claude-sonnet-4-5");
    assert.equal(parsed.system, "Teach math step by step.");
    assert.equal(parsed.max_tokens, 4096);
    assert.equal(parsed.stream, true);
    assert.equal(parsed.messages.length, 3);

    // First user turn must not receive the image attached to the final turn
    assert.deepEqual(parsed.messages[0], {
      role: "user",
      content: [{ type: "text", text: "First question" }],
    });
    assert.deepEqual(parsed.messages[1], {
      role: "assistant",
      content: [{ type: "text", text: "First answer" }],
    });
    // Final user turn receives both text and base64 PNG image block
    assert.equal(parsed.messages[2].role, "user");
    assert.equal(parsed.messages[2].content.length, 2);
    assert.deepEqual(parsed.messages[2].content[0], { type: "text", text: "Follow-up with image" });
    assert.equal(parsed.messages[2].content[1].type, "image");
    assert.equal(parsed.messages[2].content[1].source.media_type, "image/png");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("callAnthropicChat does not attach images if the final turn is an assistant turn", async () => {
  const originalFetch = globalThis.fetch;
  let capturedBody = null;
  globalThis.fetch = async (_url, init) => {
    capturedBody = JSON.parse(init.body);
    return new Response("ok", { status: 200 });
  };

  try {
    await callAnthropicChat(
      { ANTHROPIC_API_KEY: "test-placeholder-key" },
      {
        model: "claude-sonnet-4-5",
        systemInstruction: "System",
        turns: [
          { role: "user", text: "Q" },
          { role: "assistant", text: "A" },
        ],
        images: ["base64png"],
      }
    );

    assert.equal(capturedBody.messages[0].content.length, 1);
    assert.equal(capturedBody.messages[1].content.length, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("extractDeltaText extracts text only from content_block_delta with text_delta", () => {
  assert.equal(
    extractDeltaText({
      type: "content_block_delta",
      delta: { type: "text_delta", text: "∂f/∂x = 2x" },
    }),
    "∂f/∂x = 2x"
  );

  assert.equal(extractDeltaText({ type: "message_start" }), "");
  assert.equal(extractDeltaText({ type: "ping" }), "");
  assert.equal(
    extractDeltaText({
      type: "content_block_delta",
      delta: { type: "input_json_delta", partial_json: "{}" },
    }),
    ""
  );
  assert.equal(extractDeltaText(null), "");
  assert.equal(extractDeltaText(undefined), "");
});

test("rememberParsedBody and takeParsedBody store a parsed body per Request and delete it upon first take", () => {
  const req1 = new Request("https://api.studiquo.app/api/ai/chat", { method: "POST" });
  const req2 = new Request("https://api.studiquo.app/api/ai/chat", { method: "POST" });
  const payload1 = { model: "gemini-2.5-flash", turns: [{ role: "user", text: "Hi" }] };

  assert.equal(takeParsedBody(req1), undefined);
  rememberParsedBody(req1, payload1);

  assert.equal(takeParsedBody(req2), undefined);
  assert.equal(takeParsedBody(req1), payload1);
  assert.equal(takeParsedBody(req1), undefined);
});
