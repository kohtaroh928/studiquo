import { sha256Hex } from '../auth.js';
import { RAW_PDF_CONSENT_VERSION } from './pdf-preflight.js';

const MAX_EPOCH = Number.MAX_SAFE_INTEGER;
const validEpoch = value => Number.isSafeInteger(value) && value >= 0;
const validId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/u.test(value);
const fail = code => { throw new Error(code); };
const statement = (db, sql, ...args) => db.prepare(sql).bind(...args);
const active = `EXISTS(SELECT 1 FROM rag_accounts a WHERE a.account_key=? AND a.deleted=0)`;

// session MUST already be authenticated by the caller. This does not validate JWTs.
// Never accept a client-supplied account key. Use the primary ADMIN_DB binding,
// not a caller-created replica session, for each authorization snapshot.
async function owner(session) {
  if (typeof session?.sub !== 'string' || !session.sub.length || session.sub.length > 512)
    fail('raw_pdf_unauthorized');
  return sha256Hex(`rag-account:${session.sub}`);
}
async function requireSchema(db) {
  const row = await statement(db, "SELECT COUNT(*) AS n FROM sqlite_master WHERE (type='table' AND name='rag_raw_pdf_consents') OR (type='trigger' AND name IN ('rag_raw_pdf_control_changed','rag_raw_pdf_control_deleted','rag_raw_pdf_account_deleted'))").first();
  if (row?.n !== 4) fail('raw_pdf_upgrade_required');
}
function grantsEnabled(env) {
  return ['AI_PROVIDER_APPROVED', 'RAG_ENABLED', 'RAG_AUTO_INDEX_ENABLED', 'RAG_PDF_PROCESSING_ENABLED']
    .every(key => env[key] === 'true');
}

async function readConsent(env, session) {
  const key = await owner(session), db = env.ADMIN_DB;
  await requireSchema(db);
  const row = await statement(db, `SELECT r.epoch,r.enabled,r.rag_consent_epoch,r.consent_version,
    a.deleted,c.enabled AS rag_enabled,c.epoch AS rag_epoch
    FROM rag_raw_pdf_consents r LEFT JOIN rag_accounts a USING(account_key)
    LEFT JOIN rag_controls c USING(account_key) WHERE r.account_key=?`, key).first();
  return {
    enabled: !!row && row.enabled === 1 && row.deleted === 0 && row.rag_enabled === 1 &&
      row.rag_consent_epoch === row.rag_epoch && row.consent_version === RAW_PDF_CONSENT_VERSION,
    rawPDFConsentEpoch: row?.epoch ?? 0,
    consentEpoch: row?.rag_consent_epoch ?? null,
  };
}

/** Internal CAS operation only. Future grant route must check current privacy headers
 * and explicit user consent; no route is wired by this module. Revocation needs no flags.
 */
async function updateConsent(env, session, payload) {
  payload = payload && typeof payload === 'object' && !Array.isArray(payload) ? { ...payload } : payload;
  const key = await owner(session);
  if (!payload || typeof payload !== 'object' || Array.isArray(payload) ||
      Object.keys(payload).some(k => !['enabled','expectedEpoch','consentEpoch','consentVersion'].includes(k)) ||
      typeof payload.enabled !== 'boolean' || !validEpoch(payload.expectedEpoch)) fail('invalid_raw_pdf_consent');
  if (payload.enabled && (!validEpoch(payload.consentEpoch) || payload.consentVersion !== RAW_PDF_CONSENT_VERSION))
    fail('invalid_raw_pdf_consent');
  if (payload.enabled && !grantsEnabled(env)) fail('raw_pdf_disabled');
  if (payload.enabled && payload.expectedEpoch === MAX_EPOCH) fail('raw_pdf_epoch_exhausted');
  const db = env.ADMIN_DB; await requireSchema(db);
  const gate = payload.enabled
    ? ` AND ${active} AND EXISTS(SELECT 1 FROM rag_controls c WHERE c.account_key=? AND c.enabled=1 AND c.epoch=?)`
    : '';
  const gateArgs = payload.enabled ? [key, key, payload.consentEpoch] : [];
  const next = Math.min(MAX_EPOCH, payload.expectedEpoch + 1);
  const results = await db.batch([
    statement(db, `INSERT OR IGNORE INTO rag_raw_pdf_consents(account_key,epoch,enabled)
      SELECT ?,0,0 WHERE ?=0 AND ${active}`, key, payload.expectedEpoch, key),
    statement(db, `UPDATE rag_raw_pdf_consents SET epoch=?,enabled=?,rag_consent_epoch=?,consent_version=?
      WHERE account_key=? AND epoch=?${gate}`, next, Number(payload.enabled),
      payload.enabled ? payload.consentEpoch : null, payload.enabled ? RAW_PDF_CONSENT_VERSION : null,
      key, payload.expectedEpoch, ...gateArgs),
  ]);
  if (results[1]?.meta?.changes !== 1) fail('raw_pdf_consent_conflict');
  return { enabled: payload.enabled, rawPDFConsentEpoch: next, consentEpoch: payload.enabled ? payload.consentEpoch : null };
}

/** One DB snapshot only, NOT a processing lease or budget admission. Recheck before
 * dispatch and result adoption. sourceHash is extracted text identity, NOT raw PDF SHA256.
 */
async function requireAuthorization(env, session, proof) {
  proof = proof && typeof proof === 'object' && !Array.isArray(proof) ? Object.freeze({ ...proof }) : proof;
  const key = await owner(session);
  if (!proof || typeof proof !== 'object' || Array.isArray(proof) ||
      Object.keys(proof).some(k => !['documentId','sourceId','sourceHash','generation','consentEpoch','rawPDFConsentEpoch'].includes(k)) ||
      !validId(proof.documentId) || !validId(proof.sourceId) || !validEpoch(proof.generation) ||
      !validEpoch(proof.consentEpoch) || !validEpoch(proof.rawPDFConsentEpoch) ||
      typeof proof.sourceHash !== 'string' || !/^[a-f0-9]{64}$/iu.test(proof.sourceHash))
    fail('invalid_raw_pdf_proof');
  if (!grantsEnabled(env)) fail('raw_pdf_disabled');
  const db = env.ADMIN_DB; await requireSchema(db);
  const row = await statement(db, `SELECT 1 AS authorized FROM rag_accounts a
    JOIN rag_controls c USING(account_key) JOIN rag_raw_pdf_consents r USING(account_key)
    JOIN rag_documents d USING(account_key)
    WHERE a.account_key=? AND a.deleted=0 AND c.enabled=1 AND c.epoch=?
      AND r.enabled=1 AND r.epoch=? AND r.rag_consent_epoch=c.epoch AND r.consent_version=?
      AND d.document_id=? AND d.source_id=? AND d.generation=? AND d.consent_epoch=c.epoch
      AND d.state='eligible' AND d.source_hash=?`, key, proof.consentEpoch, proof.rawPDFConsentEpoch,
      RAW_PDF_CONSENT_VERSION, proof.documentId, proof.sourceId, proof.generation, proof.sourceHash).first();
  if (!row) fail('raw_pdf_not_authorized');
  // Return the exact verified tuple; no text/title/bytes or globally reusable grant.
  return Object.freeze({ accountKey: key, documentId: proof.documentId, sourceId: proof.sourceId,
    generation: proof.generation, sourceHash: proof.sourceHash,
    consentEpoch: proof.consentEpoch, rawPDFConsentEpoch: proof.rawPDFConsentEpoch });
}

const publicErrors = new Set(['raw_pdf_unauthorized','raw_pdf_upgrade_required',
  'invalid_raw_pdf_consent','raw_pdf_disabled','raw_pdf_epoch_exhausted',
  'raw_pdf_consent_conflict','invalid_raw_pdf_proof','raw_pdf_not_authorized']);
async function guarded(work) {
  try { return await work(); }
  catch (error) {
    // Never propagate SQL, binding errors, or caller values across this boundary.
    throw new Error(publicErrors.has(error?.message) ? error.message : 'raw_pdf_unavailable');
  }
}
export const readRawPDFConsent = (env, session) => guarded(() => readConsent(env, session));
export const updateRawPDFConsent = (env, session, payload) => guarded(() => updateConsent(env, session, payload));
export const requireRawPDFDocumentAuthorization = (env, session, proof) => guarded(() => requireAuthorization(env, session, proof));
