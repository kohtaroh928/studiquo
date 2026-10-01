/**
 * Anthropic proxy, the same shape as ai.js's own `callGemini`: the app
 * never holds `ANTHROPIC_API_KEY`, only this Worker does, and this file
 * knows nothing about plans or quotas — ai.js decides which plan may use
 * which model (its `PLAN_MODELS`) and only calls here once that's settled.
 *
 * `callAnthropicChat` returns the raw upstream `Response`; ai.js re-emits
 * its SSE body through its own `streamNormalizedText`, using
 * `extractDeltaText` below to pull incremental text out of each event —
 * the same two-piece split (fetch here, pump there) `callGemini`/`textOf`
 * already use for Gemini.
 */

const API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MAX_OUTPUT_TOKENS = 4096;

/** One turn's content blocks: its text, plus any images attached to it. */
function contentBlocks(turn, images) {
  const blocks = [{ type: "text", text: String(turn.text ?? "") }];
  for (const image of images) {
    blocks.push({ type: "image", source: { type: "base64", media_type: "image/png", data: image } });
  }
  return blocks;
}

/**
 * `turns` is the same provider-agnostic shape ai.js's chat handler already
 * builds for Gemini (`{ role: "user" | "assistant", text }`), so this file
 * doesn't need its own copy of the chat-history trimming/escaping logic.
 * `images` (already-validated PNG base64 strings) are attached to the last
 * turn only, matching how the app's own screenshot-attach flow works —
 * there is always at most one turn with an attachment, the one just sent.
 */
export async function callAnthropicChat(env, { model, systemInstruction, turns, images = [] }) {
  const key = env.ANTHROPIC_API_KEY;
  if (!key) throw new Error("ANTHROPIC_API_KEY is not configured on this Worker.");

  const lastIndex = turns.length - 1;
  const messages = turns.map((turn, index) => ({
    role: turn.role === "assistant" ? "assistant" : "user",
    content: contentBlocks(turn, index === lastIndex && turn.role !== "assistant" ? images : []),
  }));

  return fetch(API_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      // Sent as a header, not a query parameter, so it never lands in a
      // URL where logs or error traces could capture it — same reasoning
      // as callGemini's x-goog-api-key.
      "x-api-key": key,
      "anthropic-version": ANTHROPIC_VERSION,
    },
    body: JSON.stringify({
      model,
      system: systemInstruction,
      max_tokens: MAX_OUTPUT_TOKENS,
      stream: true,
      messages,
    }),
  });
}

/**
 * Pulls the incremental text out of one parsed Anthropic SSE event. Most
 * event types the stream sends (`message_start`, `content_block_start`,
 * `ping`, `content_block_stop`, `message_delta`, `message_stop`, …) carry
 * no new text and resolve to "" — only a `content_block_delta` whose delta
 * is a `text_delta` does.
 */
export function extractDeltaText(event) {
  if (event?.type !== "content_block_delta") return "";
  const delta = event?.delta;
  return delta?.type === "text_delta" ? String(delta.text ?? "") : "";
}
