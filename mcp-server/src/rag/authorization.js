import { boundedSearch } from "./search-branches.js";
import { sha256Hex } from "../auth.js";
import { controlAvailable, readControl } from "./control.js";

// A controls row is a permanent protocol upgrade. Flags cannot restore legacy access.
export async function sourceQualification(db, alias = "s") {
  if (!(await controlAvailable(db))) return "";
  return ` AND (NOT EXISTS(SELECT 1 FROM rag_controls rc WHERE rc.account_key=${alias}.account_key) OR EXISTS(SELECT 1 FROM rag_controls rc JOIN rag_documents rd ON rd.account_key=rc.account_key WHERE rc.account_key=${alias}.account_key AND rc.enabled=1 AND rd.source_id=${alias}.source_id AND rd.state='eligible' AND rd.consent_epoch=rc.epoch))`;
}

export async function indexAuthorization(db, key, payload) {
  const available = await controlAvailable(db);
  const control = available ? await readControl(db, key) : null;
  if (!control) {
    if (payload.control !== undefined) throw new Error("control_required");
    return { sql: available ? " AND NOT EXISTS(SELECT 1 FROM rag_controls WHERE account_key=?)" : "", args: available ? [key] : [] };
  }
  const proof = payload.control;
  if (!proof || typeof proof !== "object" || Array.isArray(proof) ||
      !Number.isSafeInteger(proof.consentEpoch) || !Number.isSafeInteger(proof.generation))
    throw new Error("control_required");
  const document = await db.prepare("SELECT * FROM rag_documents WHERE account_key=? AND document_id=?")
    .bind(key, proof.documentId ?? "").first();
  if (!document || control.enabled !== 1 || control.epoch !== proof.consentEpoch ||
      document.consent_epoch !== proof.consentEpoch || document.generation !== proof.generation ||
      document.state !== "eligible" || document.source_id !== payload.sourceId)
    throw new Error("control_conflict");
  if (payload.kind !== "pdf" || payload.title !== document.title ||
      payload.sourceHash !== document.source_hash || (payload.folderId ?? null) !== document.folder_id ||
      payload.totalPages !== document.total_pages)
    throw new Error("control_conflict");
  return {
    sql: " AND EXISTS(SELECT 1 FROM rag_controls rc JOIN rag_documents rd ON rd.account_key=rc.account_key WHERE rc.account_key=? AND rc.enabled=1 AND rc.epoch=? AND rd.document_id=? AND rd.source_id=? AND rd.generation=? AND rd.consent_epoch=rc.epoch AND rd.state='eligible')",
    args: [key, proof.consentEpoch, proof.documentId, payload.sourceId, proof.generation],
  };
}

export async function sourceContextColumn(db) {
  const columns = (await db.prepare("PRAGMA table_info(rag_sources)").bind().all()).results ?? [];
  return columns.some(c => c.name === 'context_hash') ? 's.context_hash' : "'' AS context_hash";
}
// One owner-scoped SQL snapshot validates every excerpt and all its neighbors.
// Separate reads could validate A, observe a revocation while reading B, then
// still send the stale A. No per-reference asynchronous authorization loop.
export async function referencesAuthorized(env, key, references) {
  if (!references.length) return true;
  const db = env.ADMIN_DB, qualification = await sourceQualification(db);
  const contextColumn = await sourceContextColumn(db);
  const ids = [...new Set(references.flatMap(r => r.chunkIds ?? [r.citation.chunkId]))];
  if (!ids.length || ids.length > 100) return false;
  const rows = (await db.prepare(
    `WITH requested(chunk_id) AS (VALUES ${ids.map(() => '(?)').join(',')}) SELECT c.chunk_id,c.source_id,c.page_number,s.title,s.source_hash,${contextColumn},s.folder_id FROM requested JOIN rag_chunks c ON c.chunk_id=requested.chunk_id JOIN rag_sources s ON s.account_key=c.account_key AND s.source_id=c.source_id JOIN rag_accounts a ON a.account_key=c.account_key WHERE c.account_key=? AND c.ready=1 AND s.complete=1 AND s.deleted=0 AND a.deleted=0${qualification}`,
  ).bind(...ids, key).all()).results ?? [];
  const byId = new Map(rows.map(row => [row.chunk_id, row]));
  return references.every(reference => (reference.chunkIds ?? [reference.citation.chunkId]).every(id => {
    const row = byId.get(id);
    if (!row || row.source_id !== reference.citation.sourceId || row.page_number !== reference.citation.pageNumber) return false;
    return JSON.stringify({ title: row.title, source_hash: row.source_hash, context_hash: row.context_hash, folder_id: row.folder_id }) === JSON.stringify(reference.sourceSnapshot);
  }));
}

export async function revalidateRetrieval(env, session, result) {
  if (!result.context) return result;
  try {
    if (!result.authorization || result.authorization.key !== await sha256Hex(`rag-account:${session?.sub}`) || !await boundedSearch(() => referencesAuthorized(env, result.authorization.key, result.authorization.references), 2000))
      return { context: "", citations: [], status: "fallback" };
    return result;
  } catch {
    return { context: "", citations: [], status: "fallback" };
  }
}
