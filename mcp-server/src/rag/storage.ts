import { sha256Hex } from "../auth.ts";
import { stripInvisible } from "./sanitize.ts";
import { MODELS } from "./limits.ts";
import { contextualChildren, INDEX_FORMAT_VERSION, searchText } from "./chunking.ts";
import { prepareStructuredInput } from "./structured-input.ts";
import { validId } from "./query.ts";
import { indexAuthorization } from "./authorization.ts";
import { invalidateSourceControl, invalidateAccountControl, controlAvailable } from "./control.ts";
export const accountKey = (sub: any) => sha256Hex(`rag-account:${sub}`);
const rows = async (statement: any) => (await statement.all()).results ?? [];
export const all = (db: any, sql: any, ...args: any[]) => rows(db.prepare(sql).bind(...args));
const run = (db: any, sql: any, ...args: any[]) =>
  db
    .prepare(sql)
    .bind(...args)
    .run();
// Vectorize's live ID lookup accepts at most 20 IDs per call.
export async function getVectors(env: any, ids: any) {
  const vectors = [];
  for (let offset = 0; offset < ids.length; offset += 20)
    vectors.push(...await env.RAG_VECTORIZE.getByIds(ids.slice(offset, offset + 20)));
  return vectors;
}
export async function embeddings(env: any, text: any) {
  const response = await env.AI.run(MODELS.embedding, { text });
  const values = response?.data;
  if (
    !Array.isArray(values) ||
    values.length !== text.length ||
    values.some(
      (v) =>
        !Array.isArray(v) ||
        v.length !== 1024 ||
        v.some((n) => !Number.isFinite(n)),
    )
  )
    throw new Error("embedding_unavailable");
  return values;
}
export async function ensureIndexSchema(db: any) {
  const columns = await all(db, "PRAGMA table_info(rag_chunks)");
  if (!columns.some((c: any) => c.name === "embedding_hash")) throw new Error("index_upgrade_required");
}
export async function indexSource(env: any, key: any, payload: any) {
  const db = env.ADMIN_DB;
  const {
    sourceId,
    title,
    kind,
    folderId = null,
    sourceHash,
    pages,
    totalPages,
  } = payload;
  if (payload.locked === true || payload.isLocked === true)
    throw new Error("locked_source");
  if (
    !validId(sourceId) ||
    typeof title !== "string" ||
    title.length > 300 ||
    !["pdf", "notebook"].includes(kind) ||
    !(folderId === null || validId(folderId)) ||
    !/^([a-f0-9]{64})$/i.test(sourceHash ?? "") ||
    !Number.isInteger(totalPages) ||
    totalPages < 1 ||
    totalPages > 10000 ||
    !Array.isArray(pages) ||
    pages.length < 1 ||
    pages.length > 10
  )
    throw new Error("invalid_index");
  await ensureIndexSchema(db);
  const structured = await prepareStructuredInput(payload);
  const metadataAvailable = (await all(db, "PRAGMA table_info(rag_chunks)")).some((c: any) => c.name === "metadata_json");
  if (structured && !metadataAvailable) throw new Error("index_upgrade_required");
  const authorization = await indexAuthorization(db, key, payload);
  const contextHash = await sha256Hex(`${INDEX_FORMAT_VERSION}:${title}${structured ? ':' + structured.contextBinding : ''}`);
  const pageSet = new Set();
  for (const page of pages) {
    if (
      !Number.isInteger(page.pageNumber) ||
      page.pageNumber < 1 ||
      page.pageNumber > totalPages ||
      typeof page.text !== "string" ||
      page.text.length > 100000 ||
      pageSet.has(page.pageNumber)
    )
      throw new Error("invalid_page");
    pageSet.add(page.pageNumber);
  }
  await run(
    db,
    "INSERT OR IGNORE INTO rag_accounts(account_key) VALUES(?)",
    key,
  );
  if (
    (
      await db
        .prepare("SELECT deleted FROM rag_accounts WHERE account_key=?")
        .bind(key)
        .first()
    )?.deleted
  )
    throw new Error("account_deleted");
  await run(
    db,
    "INSERT OR IGNORE INTO rag_sources(account_key,source_id,title,kind,folder_id,source_hash,total_pages) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM rag_accounts WHERE account_key=? AND deleted=0)" + authorization.sql,
    key,
    sourceId,
    title,
    kind,
    folderId,
    sourceHash,
    totalPages,
    key,
    ...authorization.args,
  );
  const lease = crypto.randomUUID();
  const now = Date.now();
  const acquired = await run(
    db,
    "UPDATE rag_sources SET lease=?,lease_until=? WHERE account_key=? AND source_id=? AND deleted=0 AND lease_until<? AND EXISTS(SELECT 1 FROM rag_accounts WHERE account_key=? AND deleted=0)" + authorization.sql,
    lease,
    now + 120000,
    key,
    sourceId,
    now,
    key,
    ...authorization.args,
  );
  if (!acquired.meta?.changes) throw new Error("index_busy");
  const alive = async () =>
    Boolean(
      await db
        .prepare(
          "SELECT 1 FROM rag_sources s JOIN rag_accounts a USING(account_key) WHERE s.account_key=? AND s.source_id=? AND s.lease=? AND s.deleted=0 AND a.deleted=0 AND s.lease_until>?" + authorization.sql,
        )
        .bind(key, sourceId, lease, Date.now(), ...authorization.args)
        .first(),
    );
  const guardSQL =
    " AND EXISTS(SELECT 1 FROM rag_sources guard_source JOIN rag_accounts guard_account USING(account_key) WHERE guard_source.account_key=? AND guard_source.source_id=? AND guard_source.lease=? AND guard_source.lease_until>? AND guard_source.deleted=0 AND guard_account.deleted=0)" + authorization.sql;
  const guarded = (sql: any, ...args: any[]) =>
    db.prepare(sql + guardSQL).bind(...args, key, sourceId, lease, Date.now(), ...authorization.args);
  let embedded = 0,
    skipped = 0;
  const cachedVectors = new Map();
  const cacheExisting = async (rows: any) => {
    const relevant = rows.filter((r: any) => pageSet.has(r.page_number));
    for (let i = 0; i < relevant.length; i += 100) {
      const batch = relevant.slice(i, i + 100);
      const vectors = await getVectors(env, batch.map((r: any) => r.chunk_id));
      if (!(await alive())) throw new Error("index_cancelled");
      const hashes = new Map(batch.filter((r: any) => r.index_version === INDEX_FORMAT_VERSION && r.embedding_hash).map((r: any) => [r.chunk_id, r.embedding_hash]));
      for (const v of vectors)
        if (
          Array.isArray(v.values) &&
          v.values.length === 1024 &&
          v.values.every(Number.isFinite)
        )
          if (hashes.has(v.id)) cachedVectors.set(hashes.get(v.id), v.values);
    }
  };
  const retire = async (ids: any) => {
    if (ids.length)
      await db.batch(
        ids.map((id: any) =>
          guarded(
            "UPDATE rag_chunks SET ready=0 WHERE chunk_id=? AND account_key=?",
            id,
            key,
          ),
        ),
      );
    if (!(await alive())) throw new Error("index_cancelled");
    await deleteVectors(env, ids);
    if (!(await alive())) throw new Error("index_cancelled");
  };
  try {
    const source = await db
      .prepare("SELECT * FROM rag_sources WHERE account_key=? AND source_id=?")
      .bind(key, sourceId)
      .first();
    await guarded(
      "UPDATE rag_sources SET complete=0 WHERE account_key=? AND source_id=?",
      key,
      sourceId,
    ).run();
    if (source.kind !== kind) throw new Error("source_kind_mismatch");
    // PDF replacement removes all pages first; incomplete batches never count as idempotent.
    if (kind === "pdf" && source.source_hash !== sourceHash) {
      const old = await all(
        db,
        "SELECT chunk_id,chunk_hash,embedding_hash,index_version,page_number FROM rag_chunks WHERE account_key=? AND source_id=?",
        key,
        sourceId,
      );
      await cacheExisting(old);
      await retire(old.map((r: any) => r.chunk_id));
      await db.batch([
        guarded(
          "DELETE FROM rag_chunks WHERE account_key=? AND source_id=?",
          key,
          sourceId,
        ),
        guarded(
          "DELETE FROM rag_pages WHERE account_key=? AND source_id=?",
          key,
          sourceId,
        ),
      ]);
    }
    // Copy embeddings to generation-specific IDs for metadata moves. A delayed writer
    // can only mutate its own generation, never overwrite the next writer's vectors.
    const moved = await all(
      db,
      "SELECT chunk_id FROM rag_chunks WHERE account_key=? AND source_id=? AND ready=1 AND vector_folder IS NOT ?",
      key,
      sourceId,
      folderId,
    );
    for (let i = 0; i < moved.length; i += 100) {
      if (!(await alive())) throw new Error("index_cancelled");
      const requested = moved.slice(i, i + 100).map((r: any) => r.chunk_id);
      const vectors = await getVectors(env, requested);
      if (!(await alive())) throw new Error("index_cancelled");
      if (vectors.length !== requested.length)
        throw new Error("vectorize_not_visible_yet");
      const clones = [];
      for (const v of vectors)
        clones.push({
          ...v,
          id: await sha256Hex(`${v.id}:${lease}:${folderId ?? ""}`),
          oldId: v.id,
          metadata: {
            ...v.metadata,
            accountKey: key,
            sourceId,
            folderId: folderId ?? "",
          },
        });
      await db.batch(
        clones.map((v) =>
          guarded(
            `INSERT OR IGNORE INTO rag_chunks(chunk_id,account_key,source_id,page_number,ordinal,page_hash,chunk_hash,text,search_text,vector_folder,index_version,embedding_hash,heading_context${metadataAvailable ? ",metadata_json" : ""}) SELECT ?,account_key,source_id,page_number,ordinal,page_hash,chunk_hash,text,search_text,?,index_version,embedding_hash,heading_context${metadataAvailable ? ",metadata_json" : ""} FROM rag_chunks WHERE chunk_id=? AND account_key=?`,
            v.id,
            folderId,
            v.oldId,
            key,
          ),
        ),
      );
      if (!(await alive())) throw new Error("index_cancelled");
      await journaledUpsert(env, key, sourceId, lease, clones.map(({ oldId, ...v }) => v), alive);
      if (!(await alive())) {
        await compensateVectors(env, key, sourceId, clones.map((v) => v.id));
        throw new Error("index_cancelled");
      }
      await db.batch(
        clones.flatMap((v) => [
          ...(authorization.sql ? [guarded("DELETE FROM rag_cleanup_vectors WHERE account_key=? AND chunk_id=? AND writer_lease=?", key, v.id, lease)] : []),
          guarded(
            "UPDATE rag_chunks SET ready=1 WHERE chunk_id=? AND account_key=?",
            v.id,
            key,
          ),
          guarded(
            "DELETE FROM rag_chunks WHERE chunk_id=? AND account_key=?",
            v.oldId,
            key,
          ),
        ]),
      );
      await guarded(
        "UPDATE rag_sources SET folder_id=? WHERE account_key=? AND source_id=?",
        folderId,
        key,
        sourceId,
      ).run();
      if (!(await alive())) throw new Error("index_cancelled");
      await deleteVectors(env, requested);
      if (!(await alive())) throw new Error("index_cancelled");
    }
    await guarded(
      "UPDATE rag_sources SET title=?,folder_id=?,source_hash=?,total_pages=?,index_version=2,context_hash=?,complete=0 WHERE account_key=? AND source_id=?",
      title,
      folderId,
      sourceHash,
      totalPages,
      contextHash,
      key,
      sourceId,
    ).run();
    for (const page of pages) {
      if (!(await alive())) throw new Error("index_cancelled");
      const pageHash = structured?.pages.get(page.pageNumber).pageHash ?? await sha256Hex(page.text);
      const existing = await db
        .prepare(
          "SELECT page_hash,source_hash,index_version,context_hash FROM rag_pages WHERE account_key=? AND source_id=? AND page_number=?",
        )
        .bind(key, sourceId, page.pageNumber)
        .first();
      const old = await all(
        db,
        "SELECT chunk_id,ready,chunk_hash,embedding_hash,index_version,page_number FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number=?",
        key,
        sourceId,
        page.pageNumber,
      );
      if (
        existing?.page_hash === pageHash &&
        existing.index_version === INDEX_FORMAT_VERSION && existing.context_hash === contextHash &&
        (kind !== "pdf" || existing.source_hash === sourceHash) &&
        old.every((r: any) => r.ready === 1)
      ) {
        skipped++;
        continue;
      }
      await cacheExisting(old);
      const children = structured?.pages.get(page.pageNumber).children ?? contextualChildren(stripInvisible(page.text).text, title);
      const chunks = [];
      for (let ordinal = 0; ordinal < children.length; ordinal++) {
        const { text, headingContext, embeddingText, metadataJSON = null } = children[ordinal],
          chunkHash = await sha256Hex(text),
          embeddingHash = await sha256Hex(embeddingText),
          id = await sha256Hex(
            `${key}:${sourceId}:${page.pageNumber}:${ordinal}:${embeddingHash}:${lease}`,
          );
        chunks.push({ id, text, chunkHash, embeddingHash, headingContext, embeddingText, ordinal, metadataJSON });
      }
      // Durable pending IDs precede external mutations, allowing deletion retries to clean them.
      if (chunks.length)
        await db.batch(
          chunks.map((c) =>
            guarded(
              `INSERT OR IGNORE INTO rag_chunks(chunk_id,account_key,source_id,page_number,ordinal,page_hash,chunk_hash,text,search_text,vector_folder,index_version,embedding_hash,heading_context${metadataAvailable ? ",metadata_json" : ""}) SELECT ?,?,?,?,?,?,?,?,?,?,?,?,?${metadataAvailable ? ",?" : ""} WHERE 1=1`,
              c.id,
              key,
              sourceId,
              page.pageNumber,
              c.ordinal,
              pageHash,
              c.chunkHash,
              c.text,
              searchText(`${title}\n${c.headingContext}\n${c.text}`),
              folderId,
              INDEX_FORMAT_VERSION,
              c.embeddingHash,
              c.headingContext,
              ...(metadataAvailable ? [c.metadataJSON] : []),
            ),
          ),
        );
      const pending = await all(
        db,
        "SELECT chunk_id FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number=? AND ready=0",
        key,
        sourceId,
        page.pageNumber,
      );
      const needed = new Set(pending.map((c: any) => c.chunk_id));
      const toEmbed = chunks.filter((c) => needed.has(c.id));
      // Bound model calls; no page body or embedding input is ever logged.
      for (let i = 0; i < toEmbed.length; i += 16) {
        const batch = toEmbed.slice(i, i + 16);
        const missing = batch.filter((c) => !cachedVectors.has(c.embeddingHash));
        if (!(await alive())) throw new Error("index_cancelled");
        const generated = missing.length
          ? await embeddings(
              env,
              missing.map((c) => c.embeddingText),
            )
          : [];
        const fresh = new Map(missing.map((c, j) => [c.id, generated[j]]));
        const values = batch.map(
          (c) => cachedVectors.get(c.embeddingHash) ?? fresh.get(c.id),
        );
        if (!(await alive())) throw new Error("index_cancelled");
        await journaledUpsert(env, key, sourceId, lease,
          batch.map((c, j) => ({
            id: c.id,
            values: values[j],
            metadata: {
              accountKey: key,
              sourceId,
              folderId: folderId ?? "",
              pageNumber: page.pageNumber,
            },
          })),
          alive,
        );
        if (!(await alive())) {
          await compensateVectors(env, key, sourceId, batch.map((c) => c.id));
          throw new Error("index_cancelled");
        }
        await db.batch(
          batch.flatMap((c) => [
            ...(authorization.sql ? [guarded("DELETE FROM rag_cleanup_vectors WHERE account_key=? AND chunk_id=? AND writer_lease=?", key, c.id, lease)] : []),
            guarded(
              "UPDATE rag_chunks SET ready=1 WHERE chunk_id=? AND account_key=?",
              c.id,
              key,
            ),
          ]),
        );
        embedded += missing.length;
      }
      const keep = new Set(chunks.map((c) => c.id));
      const obsolete = old.filter((c: any) => !keep.has(c.chunk_id));
      await retire(obsolete.map((c: any) => c.chunk_id));
      if (obsolete.length)
        await db.batch(
          obsolete.map((c: any) =>
            guarded(
              "DELETE FROM rag_chunks WHERE chunk_id=? AND account_key=?",
              c.chunk_id,
              key,
            ),
          ),
        );
      if (!(await alive())) throw new Error("index_cancelled");
      await guarded(
        "INSERT OR REPLACE INTO rag_pages(account_key,source_id,page_number,page_hash,source_hash,index_version,context_hash) SELECT ?,?,?,?,?,?,? WHERE 1=1",
        key,
        sourceId,
        page.pageNumber,
        pageHash,
        sourceHash,
        INDEX_FORMAT_VERSION,
        contextHash,
      ).run();
    }
    // Drop pages removed by a shorter revision.
    const excess = await all(
      db,
      "SELECT chunk_id FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number>?",
      key,
      sourceId,
      totalPages,
    );
    await retire(excess.map((c: any) => c.chunk_id));
    await db.batch([
      guarded(
        "DELETE FROM rag_chunks WHERE account_key=? AND source_id=? AND page_number>?",
        key,
        sourceId,
        totalPages,
      ),
      guarded(
        "DELETE FROM rag_pages WHERE account_key=? AND source_id=? AND page_number>?",
        key,
        sourceId,
        totalPages,
      ),
    ]);
    await guarded(
      "UPDATE rag_sources SET complete=(SELECT count(*) FROM rag_pages WHERE account_key=? AND source_id=? AND (?='notebook' OR source_hash=?) AND index_version=2 AND context_hash=?)=? AND NOT EXISTS(SELECT 1 FROM rag_chunks WHERE account_key=? AND source_id=? AND ready=0) WHERE account_key=? AND source_id=?",
      key,
      sourceId,
      kind,
      sourceHash,
      contextHash,
      totalPages,
      key,
      sourceId,
      key,
      sourceId,
    ).run();
    if (!(await alive())) throw new Error("index_cancelled");
    return { embedded, skipped, sourceId };
  } finally {
    await run(
      db,
      "UPDATE rag_sources SET lease=NULL,lease_until=0 WHERE account_key=? AND source_id=? AND lease=?",
      key,
      sourceId,
      lease,
    );
  }
}
export async function deleteVectors(env: any, ids: any) {
  if (ids.length && !env.RAG_VECTORIZE)
    throw new Error("vectorize_unavailable");
  for (let i = 0; i < ids.length; i += 1000)
    await env.RAG_VECTORIZE.deleteByIds(ids.slice(i, i + 1000));
}
// Record every possible external write before dispatch. Unsettled writes survive
// Worker termination and are never erased by cleanup's first delete attempt.
async function journaledUpsert(env: any, key: any, sourceId: any, lease: any, values: any, alive: any) {
  const db = env.ADMIN_DB, available = await controlAvailable(db);
  if (available) await db.batch(values.map((v: any) => db.prepare(
    "INSERT OR IGNORE INTO rag_cleanup_vectors(account_key,source_id,chunk_id,writer_lease) VALUES(?,?,?,?)",
  ).bind(key, sourceId, v.id, lease)));
  try {
    if (!(await alive())) throw new Error("index_cancelled");
    return await env.RAG_VECTORIZE.upsert(values);
  }
  finally {
    if (available) await db.batch(values.map((v: any) => db.prepare(
      "UPDATE rag_cleanup_vectors SET settled=1 WHERE account_key=? AND source_id=? AND chunk_id=? AND writer_lease=?",
    ).bind(key, sourceId, v.id, lease)));
  }
}
async function compensateVectors(env: any, key: any, sourceId: any, ids: any) {
  // Generation-specific IDs only. Never revoke a successful successor source.
  await deleteVectors(env, ids);
}
async function cleanupVectorJournal(env: any, key: any, sourceId: any) {
  const db = env.ADMIN_DB;
  const journal = await all(db, `SELECT v.* FROM rag_cleanup_vectors v WHERE v.account_key=? AND v.source_id=?
    AND NOT EXISTS(SELECT 1 FROM rag_sources s WHERE s.account_key=v.account_key AND s.source_id=v.source_id
      AND s.deleted=0 AND s.lease=v.writer_lease AND s.lease_until>?)`, key, sourceId, Date.now());
  if (!journal.length) return;
  await db.batch(journal.map((v: any) => db.prepare("UPDATE rag_cleanup_vectors SET last_attempt_at=? WHERE account_key=? AND source_id=? AND chunk_id=?").bind(Date.now(), key, sourceId, v.chunk_id)));
  await deleteVectors(env, journal.map((v: any) => v.chunk_id));
  await db.batch(journal.filter((v: any) => v.settled === 1).flatMap((v: any) => [
    db.prepare("DELETE FROM rag_chunks WHERE account_key=? AND source_id=? AND chunk_id=? AND ready=0").bind(key, sourceId, v.chunk_id),
    db.prepare("DELETE FROM rag_cleanup_vectors WHERE account_key=? AND source_id=? AND chunk_id=? AND settled=1").bind(key, sourceId, v.chunk_id),
  ]));
}
export async function deleteSource(env: any, key: any, id: any) {
  const db = env.ADMIN_DB;
  await invalidateSourceControl(env, key, id);
  const contextColumn = (await all(db, "PRAGMA table_info(rag_sources)")).some((c: any) => c.name === "context_hash");
  await run(
    db,
    `UPDATE rag_sources SET deleted=1,complete=0,title='',folder_id=NULL,source_hash=''${contextColumn ? ",context_hash=''" : ""} WHERE account_key=? AND source_id=?`,
    key,
    id,
  );
  const source = await db
    .prepare(
      "SELECT lease_until FROM rag_sources WHERE account_key=? AND source_id=?",
    )
    .bind(key, id)
    .first();
  if (source?.lease_until > Date.now()) throw new Error("deletion_busy");
  const chunks = await all(
    db,
    "SELECT chunk_id FROM rag_chunks WHERE account_key=? AND source_id=?",
    key,
    id,
  );
  const journal = await controlAvailable(db) ? await all(db, "SELECT chunk_id,settled FROM rag_cleanup_vectors WHERE account_key=? AND source_id=?", key, id) : [];
  await deleteVectors(env, [...new Set([...chunks, ...journal].map(c => c.chunk_id))]);
  await db.batch([
    db
      .prepare("DELETE FROM rag_chunks WHERE account_key=? AND source_id=?")
      .bind(key, id),
    db
      .prepare("DELETE FROM rag_pages WHERE account_key=? AND source_id=?")
      .bind(key, id),
    db
      .prepare("UPDATE rag_sources SET kind='notebook',total_pages=0,lease=NULL,lease_until=0 WHERE account_key=? AND source_id=? AND deleted=1")
      .bind(key, id),
  ]);
  if (await controlAvailable(db)) await db.batch([
    ...journal.filter((row: any) => row.settled === 1).map((row: any) => db.prepare("DELETE FROM rag_cleanup_vectors WHERE account_key=? AND source_id=? AND chunk_id=? AND settled=1").bind(key, id, row.chunk_id)),
    db.prepare("DELETE FROM rag_cleanup_jobs WHERE account_key=? AND source_id=? AND NOT EXISTS(SELECT 1 FROM rag_cleanup_vectors WHERE account_key=? AND source_id=?)").bind(key, id, key, id),
  ]);
  // Tombstone remains so delayed client uploads cannot resurrect a deleted source.
}
export async function deleteAccountRAG(env: any, sub: any) {
  if (!env.ADMIN_DB) {
    if (env.RAG_ENABLED !== "true") return;
    throw new Error("rag_database_unavailable");
  }
  if (
    env.RAG_ENABLED !== "true" &&
    !(
      await all(
        env.ADMIN_DB,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='rag_accounts'",
      )
    ).length
  )
    return;
  const key = await accountKey(sub);
  const db = env.ADMIN_DB;
  await run(
    db,
    "INSERT INTO rag_accounts(account_key,deleted) VALUES(?,1) ON CONFLICT(account_key) DO UPDATE SET deleted=1",
    key,
  );
  await invalidateAccountControl(env, key);
  await run(
    db,
    "UPDATE rag_sources SET deleted=1,complete=0 WHERE account_key=?",
    key,
  );
  if (
    await db
      .prepare(
        "SELECT 1 FROM rag_sources WHERE account_key=? AND lease_until>? LIMIT 1",
      )
      .bind(key, Date.now())
      .first()
  )
    throw new Error("deletion_busy");
  const chunks = await all(
    db,
    "SELECT chunk_id FROM rag_chunks WHERE account_key=?",
    key,
  );
  const journal = await controlAvailable(db) ? await all(db, "SELECT chunk_id,settled FROM rag_cleanup_vectors WHERE account_key=?", key) : [];
  await deleteVectors(env, [...new Set([...chunks, ...journal].map(c => c.chunk_id))]);
  if (journal.some((v: any) => v.settled !== 1)) throw new Error("deletion_busy");
  await db.batch([
    db.prepare("DELETE FROM rag_chunks WHERE account_key=?").bind(key),
    db.prepare("DELETE FROM rag_pages WHERE account_key=?").bind(key),
    db.prepare("DELETE FROM rag_sources WHERE account_key=?").bind(key),
  ]);
  if (await controlAvailable(db)) await db.batch([
    ...journal.map((row: any) => db.prepare("DELETE FROM rag_cleanup_vectors WHERE account_key=? AND chunk_id=?").bind(key, row.chunk_id)),
    db.prepare("DELETE FROM rag_cleanup_jobs WHERE account_key=? AND NOT EXISTS(SELECT 1 FROM rag_cleanup_vectors v WHERE v.account_key=rag_cleanup_jobs.account_key AND v.source_id=rag_cleanup_jobs.source_id)").bind(key),
  ]);
}

// Persistent jobs survive Vectorize outages and active writer leases. Flags never
// disable erasure. A caller can retry a bounded owner-scoped batch without text.
async function cleanupOne(env: any, key: any, sourceId: any) {
  const explicit = await env.ADMIN_DB.prepare("SELECT 1 FROM rag_cleanup_jobs WHERE account_key=? AND source_id=?").bind(key, sourceId).first();
  if (explicit) {
    await run(env.ADMIN_DB, "UPDATE rag_cleanup_jobs SET last_attempt_at=? WHERE account_key=? AND source_id=?", Date.now(), key, sourceId);
    await deleteSource(env, key, sourceId);
  } else await cleanupVectorJournal(env, key, sourceId);
}
const cleanupCandidates = `SELECT account_key,source_id,min(last_attempt_at) AS attempted FROM (
  SELECT account_key,source_id,last_attempt_at FROM rag_cleanup_jobs UNION ALL
  SELECT account_key,source_id,last_attempt_at FROM rag_cleanup_vectors
) GROUP BY account_key,source_id`;
export async function cleanupRAG(env: any, key: any, limit = 10) {
  if (!(await controlAvailable(env.ADMIN_DB))) return { pending: 0 };
  const jobs = await all(env.ADMIN_DB, `SELECT * FROM (${cleanupCandidates}) WHERE account_key=? ORDER BY attempted,source_id LIMIT ?`, key, limit);
  let removed = 0;
  for (const job of jobs) {
    try { await cleanupOne(env, key, job.source_id); removed++; }
    catch { /* Durable jobs and D1 denial remain; no content logs. */ }
  }
  const row = await env.ADMIN_DB.prepare(`SELECT count(*) AS pending FROM (${cleanupCandidates}) WHERE account_key=?`).bind(key).first();
  return { removed, pending: row.pending };
}
export async function cleanupScheduledRAG(env: any) {
  if (!env.ADMIN_DB || !await controlAvailable(env.ADMIN_DB)) return;
  const jobs = await all(env.ADMIN_DB, `SELECT * FROM (${cleanupCandidates}) ORDER BY attempted,source_id LIMIT 10`);
  for (const job of jobs) {
    try { await cleanupOne(env, job.account_key, job.source_id); } catch { /* Retry even when flags are disabled. */ }
  }
}
