import { json, readJSONLimited } from "./http.js";

// Contract/age suitability must be reviewed before enabling the initial
// single-provider release. Missing configuration fails closed on old clients too.
export const AI_CONSENT_VERSION = "google-v2";
export async function aiPrivacyRejection(request, env) {
  if (env.AI_PROVIDER_APPROVED !== "true") {
    return json({ error: "AI機能は公開準備中です。学習資料は送信されません。" }, 503);
  }
  if (request.headers.get("X-Studiquo-AI-Consent") !== AI_CONSENT_VERSION) {
    return json({ error: "設定のプライバシーでAIへのデータ送信を許可してください。" }, 403);
  }
  // Inspect a bounded clone so the existing handler can read its own body.
  const body = await readJSONLimited(request.clone(), 20_000_000);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Invalid AI request." }, 400);
  }
  if (body.model != null && body.model !== "gemini-3.5-flash-lite") {
    return json({ error: "現在利用できるAIの送信先はGoogleのみです。" }, 403);
  }
  return null;
}
