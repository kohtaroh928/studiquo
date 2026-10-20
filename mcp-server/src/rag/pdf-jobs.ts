import {sha256Hex} from '../auth.ts';
import {requireRawPDFIntakeAuthorization} from './pdf-intake.ts';
import {RAW_PDF_CONSENT_VERSION} from './pdf-preflight.ts';
const DAY=86400000, TTL=180000, MEMORY=64*1024*1024, VERSION='raw-pdf-admission-v1';
const id=(v: any)=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(v);
const object=(v: any)=>v&&typeof v==='object'&&!Array.isArray(v);
const snapshot=(v: any)=>object(v)?Object.freeze({...v}):v;
const fail=(code: any)=>{throw new Error(code);};
const stmt=(db: any,sql: any,...args: any[])=>db.prepare(sql).bind(...args);
function now(clock: any){const n=clock();if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-TTL)fail('invalid_pdf_job_clock');return n;}
async function owner(session: any){if(typeof session?.sub!=='string'||!session.sub.length||session.sub.length>512)fail('pdf_job_unauthorized');return sha256Hex(`rag-account:${session.sub}`);}
async function schema(db: any){
 const r=await stmt(db,`SELECT COUNT(*) AS n FROM sqlite_master WHERE
  (type='table' AND name='rag_pdf_jobs') OR (type='trigger' AND name IN ('rag_pdf_jobs_intake_changed','rag_pdf_jobs_intake_deleted'))`).first();
 if(r?.n!==3)fail('pdf_job_upgrade_required');
}
// Old schema/writers remain usable for cancellation and settlement. Unknown
// timestamps are retained by future purge; never backfill them on a retry.
export async function rawPDFJobTimestampsSupported(db: any){
 const columns=await stmt(db,'PRAGMA table_info(rag_pdf_jobs)').all();
 return ['created_at','settled_at'].every(name=>columns.results.some((c: any)=>c.name===name));
}
function policy(input: any){
 const p=snapshot(input),keys=['perOwnerActive','globalActive','globalMemoryBytes','perOwnerDailyUnits','globalDailyUnits','reservationUnits','perOwnerDailyRequests','globalDailyRequests'];
 if(!object(p)||Object.keys(p).length!==keys.length||keys.some(k=>!Number.isSafeInteger(p[k])||p[k]<1||p[k]>1000000000)||
  p.perOwnerActive>p.globalActive||p.globalActive>16||p.globalMemoryBytes<MEMORY||p.globalMemoryBytes>96*1024*1024||
  p.reservationUnits>p.perOwnerDailyUnits||p.reservationUnits>p.globalDailyUnits||
  p.perOwnerDailyRequests>10000||p.globalDailyRequests>100000)fail('pdf_job_policy_required');
 return p;
}
// Recheck within the write, not merely in the preceding asynchronous lookup.
const gate=`EXISTS(SELECT 1 FROM rag_pdf_intakes i JOIN rag_accounts a USING(account_key)
 JOIN rag_controls c USING(account_key) JOIN rag_raw_pdf_consents r USING(account_key)
 WHERE i.account_key=? AND i.intake_id=? AND i.document_id=? AND i.generation=?
 AND i.consent_epoch=? AND i.raw_consent_epoch=? AND i.pdf_sha256=? AND i.byte_length=? AND i.expires_at=?
 AND i.state='pending' AND i.expires_at>? AND a.deleted=0 AND c.enabled=1 AND c.epoch=i.consent_epoch
 AND r.enabled=1 AND r.epoch=i.raw_consent_epoch AND r.rag_consent_epoch=c.epoch AND r.consent_version=?)
 AND NOT EXISTS(SELECT 1 FROM rag_documents WHERE account_key=? AND document_id=?)`;
const gateArgs=(key: any,p: any,n: any)=>[key,p.intakeId,p.documentId,p.generation,p.consentEpoch,p.rawPDFConsentEpoch,
 p.pdfSha256,p.byteLength,p.expiresAt,n,RAW_PDF_CONSENT_VERSION,key,p.documentId];
const fields='job_id,document_id,intake_id,generation,state,ever_dispatched,window_start,reserved_units,settled_units,memory_weight,policy_version,deadline';
function result(r: any){return Object.freeze({jobId:r.job_id,documentId:r.document_id,intakeId:r.intake_id,generation:r.generation,
 state:r.state,everDispatched:r.ever_dispatched===1,windowStart:r.window_start,reservedUnits:r.reserved_units,
 settledUnits:r.settled_units,memoryWeight:r.memory_weight,policyVersion:r.policy_version,deadline:r.deadline});}
async function row(db: any,key: any,jobId: any){if(!id(jobId))fail('invalid_pdf_job');return stmt(db,`SELECT ${fields} FROM rag_pdf_jobs WHERE account_key=? AND job_id=?`,key,jobId).first();}
async function reserve(env: any,session: any,input: any,limits: any,clock: any){
 session=snapshot(session);const p=policy(limits),proof=snapshot(input),key=await owner(session);
 const verified=await requireRawPDFIntakeAuthorization(env,session,proof,{clock});
 const db=env.ADMIN_DB;await schema(db);
 const find=()=>stmt(db,`SELECT ${fields} FROM rag_pdf_jobs WHERE account_key=? AND intake_id=?`,key,verified.intakeId).first();
 const existing=await find();if(existing)return result(existing);
 const n=now(clock),window=Math.floor(n/DAY)*DAY,deadline=Math.min(verified.expiresAt,n+TTL),jobId=crypto.randomUUID();
 const timed=await rawPDFJobTimestampsSupported(db);
 const columns=await stmt(db,'PRAGMA table_info(rag_pdf_jobs)').all();
 const versioned=columns.results.some((c: any)=>c.name==='writer_version');
 const r=await stmt(db,`INSERT OR IGNORE INTO rag_pdf_jobs
 (job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,state,window_start,reserved_units,memory_weight,policy_version,deadline${timed?',created_at':''}${versioned?',writer_version':''})
 SELECT ?,?,?,?,?,?,?,'reserved',?,?,?,?,?${timed?',?':''}${versioned?",'floor-v2'":''} WHERE ${gate}
 AND (SELECT COUNT(*) FROM rag_pdf_jobs WHERE account_key=? AND state!='settled')<?
 AND (SELECT COUNT(*) FROM rag_pdf_jobs WHERE state!='settled')<?
 AND (SELECT COALESCE(SUM(memory_weight),0) FROM rag_pdf_jobs WHERE state!='settled')+?<=?
 AND (SELECT COUNT(*) FROM rag_pdf_jobs WHERE account_key=? AND window_start=?)<?
 AND (SELECT COUNT(*) FROM rag_pdf_jobs WHERE window_start=?)<?
 AND (SELECT COALESCE(SUM(COALESCE(settled_units,reserved_units)),0) FROM rag_pdf_jobs WHERE account_key=? AND window_start=?)+?<=?
 AND (SELECT COALESCE(SUM(COALESCE(settled_units,reserved_units)),0) FROM rag_pdf_jobs WHERE window_start=?)+?<=?`,
 jobId,key,verified.documentId,verified.intakeId,verified.generation,verified.consentEpoch,verified.rawPDFConsentEpoch,
 window,p.reservationUnits,MEMORY,VERSION,deadline,...(timed?[n]:[]),...gateArgs(key,verified,n),key,p.perOwnerActive,p.globalActive,
 MEMORY,p.globalMemoryBytes,key,window,p.perOwnerDailyRequests,window,p.globalDailyRequests,
 key,window,p.reservationUnits,p.perOwnerDailyUnits,window,p.reservationUnits,p.globalDailyUnits).run();
 const saved=await find();if(!saved)fail('pdf_job_admission_denied');
 if(r?.meta?.changes!==1 && saved.intake_id!==verified.intakeId)fail('pdf_job_admission_denied');
 return result(saved);
}
async function claim(env: any,session: any,input: any,jobId: any,clock: any){
 session=snapshot(session);const proof=snapshot(input),key=await owner(session);
 if(!id(jobId))fail('invalid_pdf_job');const p=await requireRawPDFIntakeAuthorization(env,session,proof,{clock});
 const db=env.ADMIN_DB;await schema(db);const token=crypto.randomUUID(),tokenHash=await sha256Hex(token),n=now(clock);
 const r=await stmt(db,`UPDATE rag_pdf_jobs SET state='receiving',token_hash=?
 WHERE account_key=? AND job_id=? AND intake_id=? AND state='reserved' AND token_hash IS NULL AND deadline>?
 AND ${gate}`,tokenHash,key,jobId,p.intakeId,n,...gateArgs(key,p,n)).run();
 if(r?.meta?.changes!==1)fail('pdf_job_claim_conflict');
 return Object.freeze({jobId,executionToken:token});
}
async function dispatch(env: any,session: any,input: any,jobId: any,token: any,clock: any){
 session=snapshot(session);const proof=snapshot(input),key=await owner(session);
 if(!id(jobId)||!id(token))fail('invalid_pdf_job');const p=await requireRawPDFIntakeAuthorization(env,session,proof,{clock});
 const db=env.ADMIN_DB;await schema(db);const tokenHash=await sha256Hex(token),n=now(clock);
 const r=await stmt(db,`UPDATE rag_pdf_jobs SET state='dispatched',ever_dispatched=1
 WHERE account_key=? AND job_id=? AND intake_id=? AND token_hash=? AND state='receiving'
 AND ever_dispatched=0 AND deadline>? AND ${gate}`,key,jobId,p.intakeId,tokenHash,n,...gateArgs(key,p,n)).run();
 if(r?.meta?.changes!==1)fail('pdf_job_dispatch_conflict');return {dispatch:true};
}
async function stop(env: any,session: any,jobId: any){
 session=snapshot(session);const key=await owner(session),db=env.ADMIN_DB;await schema(db);
 if(!id(jobId))fail('invalid_pdf_job');
 await stmt(db,`UPDATE rag_pdf_jobs SET state='stop_requested' WHERE account_key=? AND job_id=? AND state!='settled'`,key,jobId).run();
 const saved=await row(db,key,jobId);if(!saved)fail('pdf_job_not_found');return result(saved);
}
async function expire(env: any,clock: any,limit: any){
 if(!Number.isSafeInteger(limit)||limit<1||limit>100)fail('invalid_pdf_job');
 const db=env.ADMIN_DB;await schema(db);const n=now(clock);
 const r=await stmt(db,`UPDATE rag_pdf_jobs SET state='stop_requested' WHERE job_id IN
 (SELECT job_id FROM rag_pdf_jobs WHERE deadline<=? AND state IN ('reserved','receiving','dispatched') ORDER BY deadline LIMIT ?)
 AND deadline<=? AND state IN ('reserved','receiving','dispatched')`,n,limit,n).run();
 return {requested:r?.meta?.changes??0};
}
async function closeUnclaimed(env: any,session: any,jobId: any,clock: any){
 session=snapshot(session);const key=await owner(session),db=env.ADMIN_DB;await schema(db);if(!id(jobId))fail('invalid_pdf_job');
 const timed=await rawPDFJobTimestampsSupported(db),at=now(clock);
 // DB execution can finish long after capture/timeout. Round DB time upward;
 // a conservative settlement timestamp must never start retention too early.
 await stmt(db,`UPDATE rag_pdf_jobs SET state='settled',settled_units=0${timed?",settled_at=MAX(?,CAST(strftime('%s','now') AS INTEGER)*1000+1000)":''}
 WHERE account_key=? AND job_id=? AND state='stop_requested' AND token_hash IS NULL AND ever_dispatched=0`,...(timed?[at]:[]),key,jobId).run();
 const saved=await row(db,key,jobId);
 if(!saved||saved.state!=='settled'||saved.ever_dispatched!==0)fail('pdf_job_stop_unconfirmed');
 // A claimed job settled by its executor must not be accepted by this no-token path.
 const untouched=await stmt(db,'SELECT 1 AS ok FROM rag_pdf_jobs WHERE account_key=? AND job_id=? AND token_hash IS NULL',key,jobId).first();
 if(!untouched)fail('pdf_job_stop_unconfirmed');return result(saved);
}
// Trusted executor ONLY: stopConfirmed must reflect completed reader/VM cleanup,
// never a client's claim. Unknown stopping/DB state must retain the reservation.
async function settle(env: any,jobId: any,token: any,stopConfirmed: any,clock: any){
 if(!id(jobId)||!id(token))fail('invalid_pdf_job');if(stopConfirmed!==true)fail('pdf_job_stop_unconfirmed');
 const db=env.ADMIN_DB;await schema(db);const tokenHash=await sha256Hex(token);
 const timed=await rawPDFJobTimestampsSupported(db),at=now(clock);
 await stmt(db,`UPDATE rag_pdf_jobs SET state='settled',settled_units=CASE WHEN ever_dispatched=1 THEN reserved_units ELSE 0 END${timed?",settled_at=MAX(?,CAST(strftime('%s','now') AS INTEGER)*1000+1000)":''}
 WHERE job_id=? AND token_hash=? AND state IN ('receiving','dispatched','stop_requested')`,...(timed?[at]:[]),jobId,tokenHash).run();
 const saved=await stmt(db,`SELECT ${fields} FROM rag_pdf_jobs WHERE job_id=? AND token_hash=? AND state='settled'`,jobId,tokenHash).first();
 if(!saved)fail('pdf_job_stop_unconfirmed');return result(saved);
}
const errors=new Set(['invalid_pdf_job_clock','pdf_job_unauthorized','pdf_job_upgrade_required','pdf_job_policy_required',
 'invalid_pdf_job','pdf_job_admission_denied','pdf_job_claim_conflict','pdf_job_dispatch_conflict','pdf_job_not_found','pdf_job_stop_unconfirmed',
 'pdf_intake_unauthorized','pdf_intake_upgrade_required','pdf_intake_disabled','invalid_pdf_intake_proof','pdf_intake_not_authorized','invalid_pdf_intake_clock']);
async function guarded(work: any){try{return await work();}catch(e: any){throw new Error(errors.has(e?.message)?e.message:'pdf_job_unavailable');}}
export const reserveRawPDFJob=(env: any,session: any,proof: any,limits: any,{clock=Date.now}: any={})=>guarded(()=>reserve(env,session,proof,limits,clock));
export const claimRawPDFJob=(env: any,session: any,proof: any,jobId: any,{clock=Date.now}: any={})=>guarded(()=>claim(env,session,proof,jobId,clock));
export const markRawPDFJobDispatched=(env: any,session: any,proof: any,jobId: any,token: any,{clock=Date.now}: any={})=>guarded(()=>dispatch(env,session,proof,jobId,token,clock));
export const requestRawPDFJobStop=(env: any,session: any,jobId: any)=>guarded(()=>stop(env,session,jobId));
export const requestExpiredRawPDFJobsStop=(env: any,{clock=Date.now,limit=100}: any={})=>guarded(()=>expire(env,clock,limit));
export const closeUnclaimedRawPDFJob=(env: any,session: any,jobId: any,{clock=Date.now}: any={})=>guarded(()=>closeUnclaimed(env,session,jobId,clock));
export const settleRawPDFJob=(env: any,jobId: any,token: any,{stopConfirmed=false,clock=Date.now}: any={})=>guarded(()=>settle(env,jobId,token,stopConfirmed,clock));

// Internal executor guard, including job-only cancellation. A settled success may
// be checked immediately before result return, but it is never a new execution grant.
export const requireRawPDFJobExecution=(env: any,session: any,proof: any,jobId: any,token: any,{clock=Date.now,settled=false}: any={})=>guarded(async()=>{
 session=snapshot(session);proof=snapshot(proof);const key=await owner(session);
 if(!id(jobId)||!id(token)||typeof settled!=='boolean')fail('invalid_pdf_job');
 const p=await requireRawPDFIntakeAuthorization(env,session,proof,{clock});
 const db=env.ADMIN_DB;await schema(db);const tokenHash=await sha256Hex(token),n=now(clock);
 const found=await stmt(db,`SELECT ${fields} FROM rag_pdf_jobs WHERE account_key=? AND job_id=? AND intake_id=?
  AND token_hash=? AND deadline>? AND ${settled?"state='settled' AND ever_dispatched=1":"state IN ('receiving','dispatched')"}
  AND ${gate}`,key,jobId,p.intakeId,tokenHash,n,...gateArgs(key,p,n)).first();
 if(!found)fail('pdf_job_claim_conflict');return result(found);
});
