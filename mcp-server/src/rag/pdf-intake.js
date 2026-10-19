import { sha256Hex } from '../auth.js';
import { MAX_RAW_PDF_BYTES, RAW_PDF_CONSENT_VERSION } from './pdf-preflight.js';

const TTL = 10 * 60 * 1000;
const MAX = Number.MAX_SAFE_INTEGER;
const integer = v => Number.isSafeInteger(v) && v >= 0;
const id = v => typeof v === 'string' && /^[A-Za-z0-9_-]{1,64}$/u.test(v);
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(v);
const hash = v => typeof v === 'string' && /^[a-f0-9]{64}$/u.test(v);
const object = v => v && typeof v === 'object' && !Array.isArray(v);
const copy = v => object(v) ? Object.freeze({ ...v }) : v;
const fail = code => { throw new Error(code); };
const stmt = (db, sql, ...args) => db.prepare(sql).bind(...args);
const flags = env => ['AI_PROVIDER_APPROVED','RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED'].every(k => env[k] === 'true');

// Only call with a verified canonical session and primary ADMIN_DB binding.
async function owner(session) {
  if (typeof session?.sub !== 'string' || !session.sub.length || session.sub.length > 512) fail('pdf_intake_unauthorized');
  return sha256Hex(`rag-account:${session.sub}`);
}
function time(clock) {
  const now = clock();
  if (!integer(now) || now > MAX - TTL) fail('invalid_pdf_intake_clock');
  return now;
}
async function schema(db) {
  const row = await stmt(db, `SELECT COUNT(*) AS n FROM sqlite_master WHERE
    (type='table' AND name IN ('rag_pdf_intakes','rag_raw_pdf_consents')) OR
    (type='trigger' AND name IN ('rag_raw_pdf_control_changed','rag_raw_pdf_control_deleted','rag_raw_pdf_account_deleted',
      'rag_pdf_intakes_raw_changed','rag_pdf_intakes_raw_deleted','rag_pdf_intakes_document_inserted',
      'rag_pdf_intakes_document_changed','rag_pdf_intakes_document_deleted','rag_pdf_intakes_account_removed'))`).first();
  if (row?.n !== 11) fail('pdf_intake_upgrade_required');
}
const consent = `EXISTS(SELECT 1 FROM rag_accounts a JOIN rag_controls c USING(account_key)
 JOIN rag_raw_pdf_consents r USING(account_key) WHERE a.account_key=? AND a.deleted=0
 AND c.enabled=1 AND c.epoch=? AND r.enabled=1 AND r.epoch=?
 AND r.rag_consent_epoch=c.epoch AND r.consent_version=?)
 AND NOT EXISTS(SELECT 1 FROM rag_documents WHERE account_key=? AND document_id=?)`;
const consentArgs = (key,p) => [key,p.consentEpoch,p.rawPDFConsentEpoch,RAW_PDF_CONSENT_VERSION,key,p.documentId];
function snapshot(row) {
  return Object.freeze({ documentId:row.document_id, intakeId:row.intake_id, generation:row.generation,
    consentEpoch:row.consent_epoch, rawPDFConsentEpoch:row.raw_consent_epoch,
    pdfSha256:row.pdf_sha256, byteLength:row.byte_length, expiresAt:row.expires_at });
}
function validateProof(p) {
  if (!object(p) || Object.keys(p).some(k => !['documentId','intakeId','generation','consentEpoch','rawPDFConsentEpoch','pdfSha256','byteLength','expiresAt'].includes(k)) ||
      !id(p.documentId) || !uuid(p.intakeId) || !integer(p.generation) || p.generation<1 ||
      !integer(p.consentEpoch) || !integer(p.rawPDFConsentEpoch) || !hash(p.pdfSha256) ||
      !integer(p.byteLength) || p.byteLength<5 || p.byteLength>MAX_RAW_PDF_BYTES || !integer(p.expiresAt)) fail('invalid_pdf_intake_proof');
}
async function retry(db,key,p,now) {
  const row = await stmt(db, `SELECT * FROM rag_pdf_intakes WHERE account_key=? AND document_id=?
    AND request_id=? AND generation=? AND state='pending' AND pdf_sha256=? AND byte_length=?
    AND consent_epoch=? AND raw_consent_epoch=? AND expires_at>? AND ${consent}`,
    key,p.documentId,p.requestId,p.expectedGeneration+1,p.pdfSha256,p.byteLength,
    p.consentEpoch,p.rawPDFConsentEpoch,now,...consentArgs(key,p)).first();
  return row ? snapshot(row) : null;
}

function intakeLimits(input) {
 const p=copy(input),keys=['ownerRows','globalRows','ownerPending','globalPending'];
 if(!object(p)||Object.keys(p).length!==keys.length||keys.some(k=>!Number.isSafeInteger(p[k])||p[k]<1||p[k]>1000000)||
  p.ownerRows>p.globalRows||p.ownerPending>p.ownerRows||p.globalPending>p.globalRows||p.ownerPending>p.globalPending)
  fail('pdf_intake_limits_required');
 return p;
}
async function prepare(env,session,input,clock,limits) {
  const cap=limits===undefined?null:intakeLimits(limits);
  const p=copy(input), key=await owner(session);
  if (!object(p) || Object.keys(p).some(k => !['documentId','requestId','expectedGeneration','pdfSha256','byteLength','consentEpoch','rawPDFConsentEpoch'].includes(k)) ||
      !id(p.documentId) || !id(p.requestId) || !integer(p.expectedGeneration) || p.expectedGeneration>=MAX ||
      !hash(p.pdfSha256) || !integer(p.byteLength) || p.byteLength<5 || p.byteLength>MAX_RAW_PDF_BYTES ||
      !integer(p.consentEpoch) || !integer(p.rawPDFConsentEpoch)) fail('invalid_pdf_intake');
  if (!flags(env)) fail('pdf_intake_disabled');
  const db=env.ADMIN_DB; await schema(db);
  let now=time(clock);
  const previous=await retry(db,key,p,now);
  if (previous) return previous;
  const intakeId=crypto.randomUUID(); now=time(clock);
  const expiresAt=now+TTL, generation=p.expectedGeneration+1;
  const result=await stmt(db, `INSERT INTO rag_pdf_intakes
    (account_key,document_id,intake_id,request_id,generation,consent_epoch,raw_consent_epoch,state,pdf_sha256,byte_length,expires_at)
    SELECT ?,?,?,?,?,?,?,'pending',?,?,? WHERE ${consent}
      AND (?=0 OR EXISTS(SELECT 1 FROM rag_pdf_intakes WHERE account_key=? AND document_id=? AND generation=?))
    ${cap?`AND (SELECT COUNT(*) FROM rag_pdf_intakes WHERE account_key=? AND document_id!=?)<?
      AND (SELECT COUNT(*) FROM rag_pdf_intakes WHERE NOT(account_key=? AND document_id=?))<?
      AND (SELECT COUNT(*) FROM rag_pdf_intakes WHERE account_key=? AND document_id!=? AND state='pending' AND expires_at>?)<?
      AND (SELECT COUNT(*) FROM rag_pdf_intakes WHERE NOT(account_key=? AND document_id=?) AND state='pending' AND expires_at>?)<?`:''}
    ON CONFLICT(account_key,document_id) DO UPDATE SET intake_id=excluded.intake_id,request_id=excluded.request_id,
      generation=excluded.generation,consent_epoch=excluded.consent_epoch,raw_consent_epoch=excluded.raw_consent_epoch,
      state='pending',pdf_sha256=excluded.pdf_sha256,byte_length=excluded.byte_length,expires_at=excluded.expires_at
    WHERE rag_pdf_intakes.generation=? AND rag_pdf_intakes.request_id!=excluded.request_id`,
    key,p.documentId,intakeId,p.requestId,generation,p.consentEpoch,p.rawPDFConsentEpoch,p.pdfSha256,p.byteLength,expiresAt,
    ...consentArgs(key,p),p.expectedGeneration,key,p.documentId,p.expectedGeneration,
    ...(cap?[key,p.documentId,cap.ownerRows,key,p.documentId,cap.globalRows,
      key,p.documentId,now,cap.ownerPending,key,p.documentId,now,cap.globalPending]:[]),p.expectedGeneration).run();
  if (result?.meta?.changes !== 1) {
    const winner=await retry(db,key,p,time(clock));
    if (winner) return winner;
    fail('pdf_intake_conflict');
  }
  return Object.freeze({documentId:p.documentId,intakeId,generation,consentEpoch:p.consentEpoch,
    rawPDFConsentEpoch:p.rawPDFConsentEpoch,pdfSha256:p.pdfSha256,byteLength:p.byteLength,expiresAt});
}

async function authorize(env,session,input,clock) {
  const p=copy(input), key=await owner(session); validateProof(p);
  if (!flags(env)) fail('pdf_intake_disabled');
  const db=env.ADMIN_DB; await schema(db);
  const row=await stmt(db, `SELECT * FROM rag_pdf_intakes WHERE account_key=? AND document_id=? AND intake_id=?
    AND generation=? AND consent_epoch=? AND raw_consent_epoch=? AND pdf_sha256=? AND byte_length=?
    AND expires_at=? AND expires_at>? AND state='pending' AND ${consent}`,
    key,p.documentId,p.intakeId,p.generation,p.consentEpoch,p.rawPDFConsentEpoch,p.pdfSha256,p.byteLength,
    p.expiresAt,time(clock),...consentArgs(key,p)).first();
  if (!row) fail('pdf_intake_not_authorized');
  return snapshot(row);
}

async function cancel(env,session,input) {
  const p=copy(input), key=await owner(session);
  if (!object(p) || Object.keys(p).some(k => !['documentId','intakeId','generation'].includes(k)) ||
      !id(p.documentId) || !uuid(p.intakeId) || !integer(p.generation) || p.generation<1) fail('invalid_pdf_intake_proof');
  const db=env.ADMIN_DB; await schema(db);
  const result=await stmt(db, `UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
    WHERE account_key=? AND document_id=? AND intake_id=? AND generation=?`,key,p.documentId,p.intakeId,p.generation).run();
  if (result?.meta?.changes!==1) fail('pdf_intake_not_authorized');
  return {cancelled:true};
}

// Input must come from the bounded reader AFTER admission. No body reader, dispatch,
// budget reservation or once-only claim is wired here. Caller must dispatch THESE
// returned bytes, then reauthorize again before sending/adopting any parsed result.
async function verify(env,session,input,pdfBytes,clock) {
  const p=copy(input); validateProof(p);
  if (!(pdfBytes instanceof Uint8Array) || !(pdfBytes.buffer instanceof ArrayBuffer) ||
      pdfBytes.byteLength!==p.byteLength || pdfBytes.byteLength>MAX_RAW_PDF_BYTES) fail('pdf_intake_bytes_mismatch');
  // Copy before the first await: external mutation cannot replace the bytes we hash/return.
  const bytes=new Uint8Array(pdfBytes);
  if (![37,80,68,70,45].every((v,i)=>bytes[i]===v)) fail('pdf_intake_bytes_mismatch');
  await authorize(env,session,p,clock);
  const digest=await crypto.subtle.digest('SHA-256',bytes);
  const actual=Array.from(new Uint8Array(digest),v=>v.toString(16).padStart(2,'0')).join('');
  if (actual!==p.pdfSha256) fail('pdf_intake_bytes_mismatch');
  const authorization=await authorize(env,session,p,clock);
  return {authorization,bytes};
}
const codes=new Set(['pdf_intake_unauthorized','pdf_intake_upgrade_required','invalid_pdf_intake_clock','invalid_pdf_intake',
  'pdf_intake_limits_required','pdf_intake_disabled','invalid_pdf_intake_proof','pdf_intake_conflict','pdf_intake_not_authorized','pdf_intake_bytes_mismatch']);
async function guarded(work) {
  try {return await work();} catch(error) {throw new Error(codes.has(error?.message)?error.message:'pdf_intake_unavailable');}
}
// clock is trusted server-side injection, never a request field.
export const prepareRawPDFIntake=(env,session,payload,{clock=Date.now}={})=>guarded(()=>prepare(env,session,payload,clock));
export const requireRawPDFIntakeAuthorization=(env,session,proof,{clock=Date.now}={})=>guarded(()=>authorize(env,session,proof,clock));
export const cancelRawPDFIntake=(env,session,proof)=>guarded(()=>cancel(env,session,proof));
export const verifyRawPDFIntakeBytes=(env,session,proof,bytes,{clock=Date.now}={})=>guarded(()=>verify(env,session,proof,bytes,clock));

// Future public intake registration MUST use this bounded variant plus rate limiting.
// The unbounded primitive above remains internal for existing fixtures/caller compatibility.
export const prepareLimitedRawPDFIntake=(env,session,payload,limits,{clock=Date.now}={})=>guarded(()=>{
 const checked=intakeLimits(limits);return prepare(env,session,payload,clock,checked);
});
