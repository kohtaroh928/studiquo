/**
 * OpenAI proxy, the Chat Completions streaming endpoint — the same shape as
 * ai.js's `callGemini` and anthropic.js's `callAnthropicChat`: the app
 * never holds `OPENAI_API_KEY`, only this Worker does.
 *
 * Model IDs are deliberately NOT hardcoded here. OpenAI's current
 * flagship/mid-tier model names were not confirmed at the time this file
 * was written, so the two "openai-mid"/"openai-flagship" logical models in
 * ai.js's `PLAN_MODELS` are resolved to real model ids via
 * `env.OPENAI_MID_MODEL` / `env.OPENAI_FLAGSHIP_MODEL` instead of a
 * constant in this file. Before enabling either logical model, check
 * OpenAI's current model documentation for the right id and set it with
 * `wrangler secret put OPENAI_MID_MODEL` (or as a plain `vars` entry in
 * wrangler.jsonc, since a model name by itself isn't sensitive — only
 * `OPENAI_API_KEY` needs to stay a secret).
 */

const API_URL = "https://api.openai.com/v1/chat/completions";
const MAX_OUTPUT_TOKENS = 4096;

/** One turn's content parts: its text, plus any images attached to it. */
function contentParts(turn, images) {
  const parts = [{ type: "text", text: String(turn.text ?? "") }];
  for (const image of images) {
    parts.push({ type: "image_url", image_url: { url: `data:image/png;base64,${image}` } });
  }
  return parts;
}

/**
 * `turns` is the same provider-agnostic shape ai.js's chat handler already
 * builds for Gemini (`{ role: "user" | "assistant", text }`). `images`
 * (already-validated PNG base64 strings) are attached to the last turn
 * only, matching how the app's own screenshot-attach flow works.
 */
export async function callOpenAIChat(env, { model, systemInstruction, turns, images = [] }) {
  const key = env.OPENAI_API_KEY;
  if (!key) throw new Error("OPENAI_API_KEY is not configured on this Worker.");

  const lastIndex = turns.length - 1;
  const messages = [
    { role: "system", content: systemInstruction },
    ...turns.map((turn, index) => ({
      role: turn.role === "assistant" ? "assistant" : "user",
      content: contentParts(turn, index === lastIndex && turn.role !== "assistant" ? images : []),
    })),
  ];

  return fetch(API_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${key}`,
    },
    body: JSON.stringify({
      model,
      max_tokens: MAX_OUTPUT_TOKENS,
      stream: true,
      messages,
    }),
  });
}

/**
 * Pulls the incremental text out of one parsed Chat Completions SSE chunk.
 * The terminal `data: [DONE]` line never reaches here — ai.js's generic SSE
 * pump already skips it, the same way it already skips Gemini's.
 */
export function extractDeltaText(event) {
  const content = event?.choices?.[0]?.delta?.content;
  return typeof content === "string" ? content : "";
}
