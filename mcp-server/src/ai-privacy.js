import { json, readJSONLimited } from "./http.js";
import { allowedModelIds } from "./ai.js";
import { rememberParsedBody } from "./ai-body.js";

// The base provider is OpenAI. Its terms forbid directing the service at, or
// knowingly serving, children under 13, and teens need a guardian's consent,
// so the app asks for the age band before the first send and sends it with
// every request. Missing configuration fails closed on old clients too.
export const AI_CONSENT_VERSION = "openai-v1";
export const AI_AGE_BANDS = new Set(["adult", "teen"]);

export async function aiPrivacyRejection(request, env) {
  if (env.AI_PROVIDER_APPROVED !== "true") {
    return json({ error: "AI機能は公開準備中です。学習資料は送信されません。" }, 503);
  }
  if (request.headers.get("X-Studiquo-AI-Consent") !== AI_CONSENT_VERSION) {
    return json({ error: "設定のプライバシーでAIへのデータ送信を許可してください。" }, 403);
  }
  if (!AI_AGE_BANDS.has(request.headers.get("X-Studiquo-Age") ?? "")) {
    return json({ error: "AIをご利用になるには、年齢の確認(13歳以上・18歳未満は保護者の同意)が必要です。" }, 403);
  }
  // This read contains no study content; it still needs the same consent but
  // has no JSON body to validate.
  if (request.method === "GET") return null;
  // The body is read once, here, and handed to the handler through ai-body.js.
  const body = await readJSONLimited(request, 20_000_000);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Invalid AI request." }, 400);
  }
  const requested = typeof body.model === "string" ? body.model.trim() : body.model;
  if (requested != null && requested !== "" && !allowedModelIds().includes(requested)) {
    return json({ error: "現在利用できるAIの送信先はOpenAIのみです。" }, 403);
  }
  rememberParsedBody(request, body);
  return null;
}
