// Control transactions store authorization state only; embeddings and deletion are separate.
const states = new Set(['eligible', 'locked', 'excluded', 'trashed', 'deleted']);
const id = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
const statement = (db, sql, args = []) => db.prepare(sql).bind(...args);
const fail = message => { throw new Error(message); };
const active = `EXISTS(SELECT 1 FROM rag_accounts a WHERE a.account_key=? AND a.deleted=0)`;

export async function controlAvailable(db) {
  const tables = (await statement(db, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('rag_controls','rag_documents','rag_cleanup_jobs','rag_cleanup_vectors')").all()).results ?? [];
  if (!tables.length) return false; // Pre-0008 legacy database only.
  if (tables.length !== 4) fail('control_upgrade_required');
  return true;
}
export async function readControl(db, key) {
  if (!(await controlAvailable(db))) return null;
  return statement(db, 'SELECT epoch,enabled FROM rag_controls WHERE account_key=?', [key]).first();
}
async function requireSchema(db) {
  if (!(await controlAvailable(db))) fail('control_upgrade_required');
}
async function ensureAccount(db, key) {
  await statement(db, 'INSERT OR IGNORE INTO rag_accounts(account_key) VALUES(?)', [key]).run();
  const row = await statement(db, 'SELECT deleted FROM rag_accounts WHERE account_key=?', [key]).first();
  if (!row || row.deleted !== 0) fail('account_deleted');
}
// A unique operation marker makes dependent statements conditional on this CAS winning.
function invalidateStatements(db, key, condition, args) {
  return [
    statement(db, `INSERT OR IGNORE INTO rag_cleanup_jobs(account_key,source_id)
      SELECT account_key,source_id FROM rag_sources WHERE account_key=? AND ${condition}`, [key, ...args]),
    statement(db, `UPDATE rag_sources SET deleted=1,complete=0
      WHERE account_key=? AND ${condition}`, [key, ...args]),
  ];
}
export async function updateConsent(env, key, payload) {
  if (!payload || typeof payload.enabled !== 'boolean' || !integer(payload.expectedEpoch)) fail('invalid_control');
  if (payload.enabled && (env.RAG_ENABLED !== 'true' || env.RAG_AUTO_INDEX_ENABLED !== 'true')) fail('rag_auto_disabled');
  const db = env.ADMIN_DB; await requireSchema(db); await ensureAccount(db, key);
  const operation = crypto.randomUUID();
  const gate = `EXISTS(SELECT 1 FROM rag_controls c WHERE c.account_key=? AND c.operation_id=?)`;
  const results = await db.batch([
    statement(db, `INSERT OR IGNORE INTO rag_controls(account_key,epoch,enabled,operation_id)
      SELECT ?,0,0,'' WHERE ?=0 AND ${active}`, [key, payload.expectedEpoch, key]),
    statement(db, `UPDATE rag_controls SET epoch=epoch+1,enabled=?,operation_id=?
      WHERE account_key=? AND epoch=? AND ${active}`, [Number(payload.enabled), operation, key, payload.expectedEpoch, key]),
    ...invalidateStatements(db, key, gate, [key, operation]),
    statement(db, `UPDATE rag_documents SET source_id=NULL,operation_id=?
      WHERE account_key=? AND ${gate}`, [operation, key, key, operation]),
  ]);
  if (!results[1]?.meta?.changes) fail('control_conflict');
  return { enabled: payload.enabled, consentEpoch: payload.expectedEpoch + 1 };
}
function consentGate() {
  return `EXISTS(SELECT 1 FROM rag_controls c WHERE c.account_key=? AND c.enabled=1 AND c.epoch=?) AND ${active}`;
}
export async function prepareDocument(env, key, payload) {
  if (!payload || !id(payload.documentId) || !id(payload.requestId) || !integer(payload.expectedGeneration) || !integer(payload.consentEpoch)
    || typeof payload.sourceHash !== 'string' || !/^[a-f0-9]{64}$/i.test(payload.sourceHash)
    || typeof payload.title !== 'string' || !payload.title.trim() || payload.title.length > 300
    || !(payload.folderId == null || id(payload.folderId))
    || !Number.isInteger(payload.totalPages) || payload.totalPages < 1 || payload.totalPages > 10000) fail('invalid_control');
  const db = env.ADMIN_DB; await requireSchema(db); await ensureAccount(db, key);
  const retry = await statement(db, `SELECT * FROM rag_documents WHERE account_key=? AND document_id=? AND request_id=?
    AND generation=? AND state='eligible' AND source_id IS NOT NULL AND ${consentGate()}`,
    [key, payload.documentId, payload.requestId, payload.expectedGeneration + 1, key, payload.consentEpoch, key]).first();
  if (retry) {
    if (retry.consent_epoch !== payload.consentEpoch || retry.source_hash !== payload.sourceHash
      || retry.title !== payload.title || retry.folder_id !== (payload.folderId ?? null) || retry.total_pages !== payload.totalPages) fail('control_conflict');
    return { sourceId: retry.source_id, documentId: payload.documentId, consentEpoch: payload.consentEpoch, generation: retry.generation };
  }
  const sourceId = crypto.randomUUID(), operation = crypto.randomUUID();
  const guard = `account_key=? AND document_id=? AND generation=? AND state='eligible' AND ${consentGate()}`;
  const args = [key, payload.documentId, payload.expectedGeneration, key, payload.consentEpoch, key];
  const results = await db.batch([
    statement(db, `INSERT OR IGNORE INTO rag_documents(account_key,document_id,source_id,generation,consent_epoch,state,source_hash,title,folder_id,total_pages,operation_id)
      SELECT ?,?,NULL,0,?,'eligible',?,?,?, ?,'' WHERE ?=0 AND ${consentGate()}`,
      [key, payload.documentId, payload.consentEpoch, payload.sourceHash, payload.title, payload.folderId ?? null,
        payload.totalPages, payload.expectedGeneration, key, payload.consentEpoch, key]),
    statement(db, `INSERT OR IGNORE INTO rag_cleanup_jobs(account_key,source_id)
      SELECT account_key,source_id FROM rag_documents WHERE ${guard} AND source_id IS NOT NULL`, args),
    statement(db, `UPDATE rag_sources SET deleted=1,complete=0 WHERE account_key=? AND source_id IN
      (SELECT source_id FROM rag_documents WHERE ${guard})`, [key, ...args]),
    statement(db, `UPDATE rag_documents SET source_id=?,generation=generation+1,consent_epoch=?,source_hash=?,title=?,folder_id=?,total_pages=?,operation_id=?,request_id=?
      WHERE ${guard}`, [sourceId, payload.consentEpoch, payload.sourceHash, payload.title, payload.folderId ?? null,
        payload.totalPages, operation, payload.requestId, ...args]),
  ]);
  if (!results[3]?.meta?.changes) fail('control_conflict');
  return { sourceId, documentId: payload.documentId, consentEpoch: payload.consentEpoch, generation: payload.expectedGeneration + 1 };
}
export async function invalidateDocument(env, key, documentId, payload) {
  if (!id(documentId) || !payload || !states.has(payload.state) || !integer(payload.expectedGeneration)
    || !integer(payload.consentEpoch)) fail('invalid_control');
  const db = env.ADMIN_DB; await requireSchema(db); await ensureAccount(db, key);
  const operation = crypto.randomUUID();
  // Blocking is allowed while consent is disabled. Restoration needs current enabled consent.
  const control = payload.state === 'eligible' ? consentGate()
    : `EXISTS(SELECT 1 FROM rag_controls c WHERE c.account_key=? AND c.epoch=?) AND ${active}`;
  const guard = `account_key=? AND document_id=? AND generation=? AND state!='deleted' AND ${control}`;
  const args = [key, documentId, payload.expectedGeneration, key, payload.consentEpoch, key];
  const results = await db.batch([
    statement(db, `INSERT OR IGNORE INTO rag_documents(account_key,document_id,source_id,generation,consent_epoch,state,source_hash,title,folder_id,total_pages,operation_id)
      SELECT ?,?,NULL,0,?,?,'','',NULL,0,'' WHERE ?=0 AND ?!='eligible' AND ${control}`,
      [key, documentId, payload.consentEpoch, 'excluded', payload.expectedGeneration, payload.state, key, payload.consentEpoch, key]),
    statement(db, `INSERT OR IGNORE INTO rag_cleanup_jobs(account_key,source_id)
      SELECT account_key,source_id FROM rag_documents WHERE ${guard} AND source_id IS NOT NULL`, args),
    statement(db, `UPDATE rag_sources SET deleted=1,complete=0 WHERE account_key=? AND source_id IN
      (SELECT source_id FROM rag_documents WHERE ${guard})`, [key, ...args]),
    statement(db, `UPDATE rag_documents SET state=?,generation=generation+1,source_id=NULL,title=CASE WHEN ?='deleted' THEN '' ELSE title END,source_hash=CASE WHEN ?='deleted' THEN '' ELSE source_hash END,folder_id=CASE WHEN ?='deleted' THEN NULL ELSE folder_id END,operation_id=? WHERE ${guard}`,
      [payload.state, payload.state, payload.state, payload.state, operation, ...args]),
  ]);
  if (!results[3]?.meta?.changes) fail('control_conflict');
  return { documentId, state: payload.state, generation: payload.expectedGeneration + 1, consentEpoch: payload.consentEpoch };
}
export async function invalidateSourceControl(env, key, sourceId) {
  const db = env.ADMIN_DB;
  if (!(await controlAvailable(db))) return;
  await db.batch([
    statement(db, `INSERT OR IGNORE INTO rag_cleanup_jobs(account_key,source_id)
      SELECT account_key,source_id FROM rag_sources WHERE account_key=? AND source_id=?`, [key, sourceId]),
    statement(db, `UPDATE rag_sources SET deleted=1,complete=0 WHERE account_key=? AND source_id=?`, [key, sourceId]),
    statement(db, `UPDATE rag_documents SET state='deleted',generation=generation+1,source_id=NULL,title='',source_hash='',folder_id=NULL,total_pages=0,operation_id=?
      WHERE account_key=? AND source_id=?`, [crypto.randomUUID(), key, sourceId]),
  ]);
}
export async function invalidateAccountControl(env, key) {
  const db = env.ADMIN_DB;
  if (!(await controlAvailable(db))) return;
  await db.batch([
    statement(db, `UPDATE rag_controls SET enabled=0,epoch=epoch+1,operation_id=? WHERE account_key=?`, [crypto.randomUUID(), key]),
    ...invalidateStatements(db, key, '1=1', []),
    statement(db, `UPDATE rag_documents SET state='deleted',generation=generation+1,source_id=NULL,title='',source_hash='',folder_id=NULL,total_pages=0,operation_id=? WHERE account_key=?`, [crypto.randomUUID(), key]),
  ]);
}
export async function cleanupPending(env, key, limit = 10) {
  const bounded = Number.isInteger(limit) ? Math.max(1, Math.min(100, limit)) : 10;
  return (await statement(env.ADMIN_DB, 'SELECT source_id FROM rag_cleanup_jobs WHERE account_key=? LIMIT ?', [key, bounded]).all()).results ?? [];
}
