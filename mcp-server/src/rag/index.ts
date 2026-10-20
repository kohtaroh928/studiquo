import { sha256Hex } from "../auth.ts";
import { json, readTextLimited } from "../http.ts";
import { accountKey, indexSource, deleteSource, all, ensureIndexSchema, cleanupRAG } from "./storage.ts";
import { sourceReadiness } from "./readiness.ts";
import { controlAvailable, readControl, updateConsent, prepareDocument, invalidateDocument } from "./control.ts";
import { sourceQualification } from "./authorization.ts";
import { validId } from "./query.ts";
export { retrieve } from "./retrieval.ts";
export { deleteAccountRAG } from "./storage.ts";
export async function handleRAG(url: any, request: any, env: any, session: any) {
  if (!url.pathname.startsWith("/api/rag/")) return null;
  if (typeof session?.sub !== "string")
    return json({ error: "unauthorized" }, 401);
  const key = await accountKey(session.sub);
  try {
    const documentId = url.pathname.match(/^\/api\/rag\/documents\/([A-Za-z0-9_-]{1,64})\/state$/)?.[1];
    const management = ['/api/rag/consent', '/api/rag/documents/prepare', '/api/rag/cleanup'].includes(url.pathname) || documentId;
    if (management) {
      if (!env.RATE_LIMIT_RAG_INDEX || (await env.RATE_LIMIT_RAG_INDEX.limit({ key })).success !== true)
        return json({ error: 'rate_limited' }, 429);
      if (!await controlAvailable(env.ADMIN_DB)) return json({ error: 'control_upgrade_required' }, 503);
      if (request.method === 'GET' && url.pathname === '/api/rag/consent') {
        const state = await readControl(env.ADMIN_DB, key);
        return json({ managed: !!state, enabled: state?.enabled === 1, consentEpoch: state?.epoch ?? 0,
          available: env.RAG_ENABLED === 'true' && env.RAG_AUTO_INDEX_ENABLED === 'true' });
      }
      if (request.method === 'GET' && documentId) {
        // Only authorization metadata, never page text. Missing and foreign
        // documents are indistinguishable; this also works with flags off.
        const row = await env.ADMIN_DB.prepare(
          'SELECT document_id AS documentId,state,generation,consent_epoch AS consentEpoch,source_id AS sourceId,source_hash AS sourceHash,title,folder_id AS folderId,total_pages AS totalPages,request_id AS requestId FROM rag_documents WHERE account_key=? AND document_id=?',
        ).bind(key, documentId).first();
        return json(row ?? { documentId, state: 'missing', generation: 0, sourceId: null });
      }
      if (request.method !== 'POST') return json({ error: 'not_found' }, 404);
      const text = await readTextLimited(request, 8192);
      if (text === null) return json({ error: 'request_too_large' }, 413);
      let payload;
      try { payload = JSON.parse(text); } catch { return json({ error: 'invalid_request' }, 400); }
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return json({ error: 'invalid_request' }, 400);
      if (url.pathname === '/api/rag/cleanup') return json(await cleanupRAG(env, key));
      if ((url.pathname === '/api/rag/documents/prepare' || payload.state === 'eligible') &&
          (env.RAG_ENABLED !== 'true' || env.RAG_AUTO_INDEX_ENABLED !== 'true'))
        return json({ error: 'rag_auto_disabled' }, 403);
      await reopenForFreshRegistration(env, key, session);
      if (url.pathname === '/api/rag/consent') return json(await updateConsent(env, key, payload));
      if (url.pathname === '/api/rag/documents/prepare') return json(await prepareDocument(env, key, payload));
      return json(await invalidateDocument(env, key, documentId, payload));
    }
    if (request.method === "GET" && url.pathname === "/api/rag/status")
      return json({
        enabled: env.RAG_ENABLED === "true",
        ...(env.RAG_ENABLED === "true" ? { structuredIngestVersion: (await all(env.ADMIN_DB, "PRAGMA table_info(rag_chunks)")).some((c: any) => c.name === "metadata_json") ? 1 : 0 } : {}),
        sources:
          env.RAG_ENABLED === "true"
            ? await all(
                env.ADMIN_DB,
                `SELECT s.source_id AS sourceId,s.complete,s.total_pages AS totalPages FROM rag_sources s WHERE s.account_key=? AND s.deleted=0${await sourceQualification(env.ADMIN_DB)}`,
                key,
              )
            : [],
      });
    const readinessId = url.pathname.match(/^\/api\/rag\/sources\/([A-Za-z0-9_-]{1,64})\/readiness$/)?.[1];
    if (request.method === "GET" && readinessId) {
      if (env.RAG_ENABLED !== "true") return json({ state: "disabled" });
      // Share the existing registration budget; polling never invokes an AI model.
      if (!env.RATE_LIMIT_RAG_INDEX ||
          (await env.RATE_LIMIT_RAG_INDEX.limit({ key })).success !== true)
        return json({ error: "rate_limited" }, 429);
      return json(await sourceReadiness(env, key, readinessId));
    }
    if (request.method === "DELETE") {
      let id = url.pathname.match(
        /^\/api\/rag\/sources\/([A-Za-z0-9_-]{1,64})$/,
      )?.[1];
      if (url.pathname === "/api/rag/source") {
        const text = await readTextLimited(request, 4096);
        if (text === null) return json({ error: "request_too_large" }, 413);
        try {
          id = JSON.parse(text).sourceId;
        } catch {
          return json({ error: "invalid_request" }, 400);
        }
      }
      if (!validId(id)) return json({ error: "invalid_source" }, 400);
      await deleteSource(env, key, id);
      return json({ deleted: true });
    }
    if (request.method === "POST" && url.pathname === "/api/rag/index") {
      if (env.RAG_ENABLED !== "true")
        return json({ error: "rag_disabled" }, 403);
      if (
        !env.RATE_LIMIT_RAG_INDEX ||
        (await env.RATE_LIMIT_RAG_INDEX.limit({ key })).success !== true
      )
        return json({ error: "rate_limited" }, 429);
      const text = await readTextLimited(request, 512 * 1024);
      if (text === null) return json({ error: "request_too_large" }, 413);
      let payload;
      try {
        payload = JSON.parse(text);
      } catch {
        return json({ error: "invalid_request" }, 400);
      }
      if (!payload || typeof payload !== "object" || Array.isArray(payload))
        return json({ error: "invalid_request" }, 400);
      if (payload.control && env.RAG_AUTO_INDEX_ENABLED !== "true") return json({ error: "rag_auto_disabled" }, 403);
      await ensureIndexSchema(env.ADMIN_DB);
      await reopenForFreshRegistration(env, key, session);
      return json(await indexSource(env, key, payload));
    }
    return json({ error: "not_found" }, 404);
  } catch (error: any) {
    const code = error.message;
    if (
      [
        "invalid_control",
        "invalid_index",
        "invalid_structured_input",
        "invalid_page",
        "locked_source",
        "source_kind_mismatch",
      ].includes(code)
    )
      return json({ error: code }, 400);
    if (["control_conflict", "index_busy", "deletion_busy", "index_cancelled"].includes(code))
      return json({ error: code }, 409);
    if (code === "control_required" || code === "rag_auto_disabled") return json({ error: code }, 403);
    if (code === "control_upgrade_required") return json({ error: code }, 503);
    if (code === "index_upgrade_required") return json({ error: code }, 503);
    if (code === "account_deleted") return json({ error: code }, 403);
    return json({ error: "rag_unavailable" }, 503);
  }
}

// A completed account erasure must not prevent a later verified re-registration.
// Never clear this tombstone for a session issued before erasure or pending cleanup.
export async function reopenForFreshRegistration(env: any, key: any, session: any) {
  const row = await env.ADMIN_DB.prepare(
    "SELECT deleted FROM rag_accounts WHERE account_key=?",
  )
    .bind(key)
    .first();
  if (!row?.deleted) return;
  const hash = await sha256Hex(session.sub);
  const state = await env.STUDIQUO_DATA?.get(
    `account-deletion:${hash}`,
    "json",
  );
  if (
    state?.status !== "deleted" ||
    !Number.isFinite(state.deletedAt) ||
    !Number.isFinite(session.issuedAt) ||
    session.issuedAt * 1000 <= state.deletedAt ||
    (await env.STUDIQUO_DATA.get(`privacy-account-delete:${hash}`))
  )
    return;
  await env.ADMIN_DB.prepare(
    "UPDATE rag_accounts SET deleted=0 WHERE account_key=? AND deleted=1 AND NOT EXISTS(SELECT 1 FROM rag_sources WHERE account_key=?)",
  )
    .bind(key, key)
    .run();
}
