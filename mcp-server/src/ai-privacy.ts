import { json, readJSONLimited } from "./http.ts";
import { allowedModelIds } from "./ai.ts";
import { rememberParsedBody } from "./ai-body.ts";
import type { Env } from "./env.ts";

// The base provider is OpenAI. Its terms forbid directing the service at, or
// knowingly serving, children under 13, and teens need a guardian's consent,
// so the app asks for the age band before the first send and sends it with
// every request. Missing configuration fails closed on old clients too.
export const AI_CONSENT_VERSION = "openai-v1";
export const AI_AGE_BANDS = new Set(["adult", "teen"]);

/** The approval, consent and age checks that need only the request headers (also used before a raw PDF body is read). */
export function aiPrivacyHeadersRejection(headers: Headers, env: Env) {
  if (env.AI_PROVIDER_APPROVED !== "true") {
    return json({ error: "AI機能は公開準備中です。学習資料は送信されません。" }, 503);
  }
  if (headers.get("X-Studiquo-AI-Consent") !== AI_CONSENT_VERSION) {
    return json({ error: "設定のプライバシーでAIへのデータ送信を許可してください。" }, 403);
  }
  if (!AI_AGE_BANDS.has(headers.get("X-Studiquo-Age") ?? "")) {
    return json({ error: "AIをご利用になるには、年齢の確認(13歳以上・18歳未満は保護者の同意)が必要です。" }, 403);
  }
  return null;
}

export async function aiPrivacyRejection(request: Request, env: Env) {
  if (env.AI_PROVIDER_APPROVED !== "true") {
    return json({ error: "AI機能は公開準備中です。学習資料は送信されません。" }, 503);
  }
  // Without the paywall every new account is a standard one, so anyone could
  // open accounts until the service-wide daily AI limits are used up for all.
  // The AI is therefore not opened unless billing is on too.
  if (env.PAYWALL_ENABLED !== "true") {
    console.error(JSON.stringify({ event: "ai_requires_paywall", message: "AI_PROVIDER_APPROVED is true but PAYWALL_ENABLED is not" }));
    return json({ error: "AI機能は公開準備中です。学習資料は送信されません。" }, 503);
  }
  const headerRejection = aiPrivacyHeadersRejection(request.headers, env);
  if (headerRejection) return headerRejection;
  // This read contains no study content; it still needs the same consent but
  // has no JSON body to validate.
  if (request.method === "GET") return null;
  // The body is read once, here, and handed to the handler through ai-body.ts.
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

/** Gates only RAG writes that enable sending/indexing; revocation and deletion stay usable. */
export async function ragPrivacyRejection(request: Request, env: Env, pathname: string) {
 if(request.method !== 'POST') return null;
 let sends = ['/api/rag/index', '/api/rag/documents/prepare'].includes(pathname);
 if(pathname === '/api/rag/consent' || /^\/api\/rag\/documents\/([A-Za-z0-9_-]{1,64})\/state$/u.test(pathname)) {
  const body = await readJSONLimited(request.clone(), 8192);
  if(!body || typeof body !== 'object' || Array.isArray(body)) return json({error:'Invalid RAG request.'},400);
  sends = body.enabled === true || body.state === 'eligible';
 }
 if(!sends) return null;
 if(request.headers.get('X-Studiquo-RAG-Consent') !== 'rag-openai-v1') return json({error:'Renewed RAG storage and OpenAI consent is required.'},403);
 // Inspect a clone: the RAG handler reads its own body afterwards.
 return aiPrivacyRejection(request.clone(), env);
}
