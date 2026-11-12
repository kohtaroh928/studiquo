import { sourceQualification } from "./authorization.ts";
import { all, getVectors } from "./storage.ts";

// Bounded, read-only readiness check. Upsert acceptance is not search visibility.
// Up to MAX_CHUNKS chunks are each looked up; a larger source is checked on a sample (see `snapshot`).
const MAX_CHUNKS = 1000;
async function snapshot(db: any, key: any, id: any, maxChunks: number) {
  const qualification = await sourceQualification(db);
  const source = await db.prepare(
    `SELECT s.source_hash,s.context_hash,s.title,s.index_version,s.folder_id,s.total_pages,s.complete,s.lease_until FROM rag_sources s JOIN rag_accounts a USING(account_key) WHERE s.account_key=? AND s.source_id=? AND s.deleted=0 AND a.deleted=0${qualification}`,
  ).bind(key, id).first();
  if (!source) return null;
  // Every chunk is counted and its ready flag checked in SQL, however large the source is.
  const totals: any = await db.prepare(
    "SELECT count(*) AS n,coalesce(sum(CASE WHEN ready=1 THEN 0 ELSE 1 END),0) AS notReady,min(page_number) AS firstPage,max(page_number) AS lastPage,count(DISTINCT page_number) AS pageCount FROM rag_chunks WHERE account_key=? AND source_id=?",
  ).bind(key, id).first();
  const total = Number(totals?.n ?? 0);
  if (total <= maxChunks) {
    const chunks = await all(db,
      "SELECT chunk_id,page_number,ready,vector_folder FROM rag_chunks WHERE account_key=? AND source_id=? ORDER BY chunk_id LIMIT ?",
      key, id, maxChunks + 1);
    return { source, chunks, total, notReady: Number(totals.notReady), };
  }
  // A source too large to look up chunk by chunk (each Vectorize lookup is a subrequest): check the first,
  // middle and last pages completely plus an even spread over the rest. The probes below then run on
  // those pages. This is a bounded check, not proof that every page is searchable.
  const middle: any = await db.prepare(
    "SELECT DISTINCT page_number FROM rag_chunks WHERE account_key=? AND source_id=? ORDER BY page_number LIMIT 1 OFFSET ?",
  ).bind(key, id, Math.floor(Number(totals.pageCount) / 2)).first();
  const stride = Math.max(2, Math.ceil(total / Math.max(1, Math.floor(maxChunks / 2))));
  const chunks = await all(db,
    "SELECT chunk_id,page_number,ready,vector_folder FROM rag_chunks WHERE account_key=? AND source_id=? AND (page_number IN (?,?,?) OR rowid % ? = 0) ORDER BY chunk_id LIMIT ?",
    key, id, totals.firstPage, middle?.page_number ?? totals.firstPage, totals.lastPage, stride, maxChunks);
  return { source, chunks, total, notReady: Number(totals.notReady), };
}
export async function sourceReadiness(env: any, key: any, id: any, maxChunks: number = MAX_CHUNKS) {
  const before = await snapshot(env.ADMIN_DB, key, id, maxChunks);
  if (!before) return { state: "missing" }; // Same response for absent and foreign source.
  const { source, chunks, total, notReady } = before;
  const pending = (reason: any) => ({ state: "waiting", reason, sourceHash: source.source_hash });
  if (!source.complete || source.lease_until > Date.now() || notReady > 0 || chunks.some((c: any) => c.ready !== 1))
    return pending("upload_incomplete");
  if (!total) return { state: "empty", sourceHash: source.source_hash };
  const pages = [...new Set(chunks.map((c: any) => c.page_number))].sort((a: any, b: any) => a - b);
  const probePages = [...new Set([pages[0], pages[Math.floor(pages.length / 2)], pages.at(-1)])];
  const seeds = new Map();
  for (let offset = 0; offset < chunks.length; offset += 100) {
    const batch = chunks.slice(offset, offset + 100);
    const vectors = await getVectors(env, batch.map((c: any) => c.chunk_id));
    const visible = new Map(vectors.map(v => [v.id, v]));
    for (const chunk of batch) {
      const v = visible.get(chunk.chunk_id);
      if (v?.metadata?.accountKey !== key || v.metadata.sourceId !== id ||
          v.metadata.pageNumber !== chunk.page_number ||
          v.metadata.folderId !== (source.folder_id ?? "") ||
          chunk.vector_folder !== source.folder_id ||
          !v.values || v.values.length !== 1024 || !Array.from(v.values).every(Number.isFinite))
        return pending("vector_pending");
      if (probePages.includes(chunk.page_number) && !seeds.has(chunk.page_number)) seeds.set(chunk.page_number, v.values);
    }
  }
  // Probe distributed pages, not just an arbitrary source seed. Identical
  // vectors may displace the seed, but the hit must belong to the probed page.
  // These bounded probes do not certify every page or real-question ANN recall.
  const probes = await Promise.all(probePages.map(async pageNumber => {
    const result = await env.RAG_VECTORIZE.query(seeds.get(pageNumber), {
      topK: 1, returnValues: false, returnMetadata: "none",
      filter: { accountKey: key, sourceId: id, folderId: source.folder_id ?? "", pageNumber },
    });
    const currentIds = new Set(chunks.filter((c: any) => c.page_number === pageNumber).map((c: any) => c.chunk_id));
    return result.matches?.some((m: any) => currentIds.has(m.id));
  }));
  if (!probes.every(Boolean)) return pending("query_pending");
  // Deletion, edits, moves or a new writer during external awaits invalidate proof.
  const after = await snapshot(env.ADMIN_DB, key, id, maxChunks);
  if (!after) return { state: "missing" };
  if (JSON.stringify(before) !== JSON.stringify(after)) return pending("source_changed");
  return { state: "ready", sourceHash: source.source_hash };
}
