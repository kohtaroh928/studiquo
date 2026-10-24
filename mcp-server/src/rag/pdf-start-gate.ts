import {RAW_PDF_CONSENT_VERSION} from './pdf-preflight.ts';
// Unconnected trusted component. No HTTP/RPC export, VM start or token input.
export const RAW_PDF_START_PROTOCOL='one-shot-v1';
const flags=['AI_PROVIDER_APPROVED','RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED','RAG_PDF_START_GATE_ENABLED'];
const uuid=(v: any)=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(v);
const fail=(code: any)=>{throw Error(code);};
const stmt=(db: any,sql: any,...args: any[])=>db.prepare(sql).bind(...args);
export function requireRawPDFStartEnabled(env: any){if(!flags.every((k: any)=>env[k]==='true'))fail('pdf_start_disabled');}
export async function requireRawPDFStartSchema(db: any): Promise<any> {
 const cols=await stmt(db,'PRAGMA table_info(rag_pdf_jobs)').all();
 const found=await stmt(db,`SELECT COUNT(*) AS n FROM sqlite_master WHERE
  (type='trigger' AND name IN ('rag_pdf_start_insert','rag_pdf_start_update','rag_pdf_start_parent_kept',
   'rag_pdf_jobs_rpc_insert','rag_pdf_jobs_rpc_update','rag_pdf_retention_floor_monotonic','rag_pdf_retention_control_kept','rag_pdf_retention_control_no_replace'))
  OR (type='table' AND name='rag_pdf_retention_control')`).first();
 if(!['start_protocol','start_claim_id','start_claimed_at','rpc_version','rpc_pdf_sha256','rpc_not_after'].every((n: any)=>cols.results.some((c: any)=>c.name===n))||found?.n!==9)
  fail('pdf_start_upgrade_required');
}
const allowed=new Set(['invalid_pdf_start','pdf_start_disabled','pdf_start_upgrade_required','pdf_start_denied','pdf_start_timeout']);
// The complete schema+CAS operation is bounded. A timed-out DB operation may
// still commit, but must never return a late grant or reset the consumed right.
export async function claimRawPDFStart(env: any,input: any,startClaimId: any,{clock=Date.now,timeoutMs=2000}: any={}): Promise<any> {
 let timer: any,closed=false;
 try{
  const begun=performance.now(),p=input&&typeof input==='object'&&!Array.isArray(input)?Object.freeze({...input}):null;
  if(!p||Reflect.ownKeys(p).length!==4||!['version','jobId','pdfSha256','notAfter'].every((k: any)=>Object.hasOwn(p,k))||p.version!==2||!uuid(p.jobId)||
   typeof p.pdfSha256!=='string'||!/^[0-9a-f]{64}$/u.test(p.pdfSha256)||!Number.isSafeInteger(p.notAfter)||p.notAfter<1||
   p.notAfter>Number.MAX_SAFE_INTEGER-180000||!uuid(startClaimId)||typeof clock!=='function'||
   !Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>2000)fail('invalid_pdf_start');
  const time=()=>{const n=clock();if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-180000)fail('invalid_pdf_start');return n;};
  const check=()=>{
   requireRawPDFStartEnabled(env);
   if(closed||performance.now()-begun>=timeoutMs)fail('pdf_start_timeout');
   const n=time();if(n>=p.notAfter||p.notAfter>n+180000)fail('pdf_start_denied');return n;
  };
  check();
  const work=async(): Promise<any> =>{
   const db=env.ADMIN_DB;await requireRawPDFStartSchema(db);const n=check();
   const dbNow="CAST(strftime('%s','now') AS INTEGER)*1000";
   const r=await stmt(db,`UPDATE rag_pdf_jobs SET start_claim_id=?,start_claimed_at=MAX(?,${dbNow}+1000)
    WHERE job_id=? AND start_protocol='one-shot-v1' AND start_claim_id IS NULL AND start_claimed_at IS NULL
     AND rpc_version=2 AND rpc_pdf_sha256=? AND rpc_not_after=? AND rpc_not_after=deadline
     AND state='dispatched' AND ever_dispatched=1 AND token_hash IS NOT NULL AND claim_protocol='stop-proof-v1'
     AND deadline>MAX(?,${dbNow}+1000) AND ABS(?-${dbNow})<=5000
     AND EXISTS(SELECT 1 FROM rag_pdf_retention_control f WHERE f.singleton=1 AND f.policy_version='raw-pdf-retention-v1'
      AND rag_pdf_jobs.window_start>=f.min_admission_window)
     AND EXISTS(SELECT 1 FROM rag_pdf_intakes i JOIN rag_accounts a USING(account_key)
      JOIN rag_controls c USING(account_key) JOIN rag_raw_pdf_consents raw USING(account_key)
      WHERE i.account_key=rag_pdf_jobs.account_key AND i.intake_id=rag_pdf_jobs.intake_id
       AND i.document_id=rag_pdf_jobs.document_id AND i.generation=rag_pdf_jobs.generation
       AND i.consent_epoch=rag_pdf_jobs.consent_epoch AND i.raw_consent_epoch=rag_pdf_jobs.raw_consent_epoch
       AND i.pdf_sha256=rag_pdf_jobs.rpc_pdf_sha256 AND i.state='pending' AND i.expires_at>MAX(?,${dbNow}+1000)
       AND a.deleted=0 AND c.enabled=1 AND c.epoch=i.consent_epoch AND raw.enabled=1 AND raw.epoch=i.raw_consent_epoch
       AND raw.rag_consent_epoch=c.epoch AND raw.consent_version=?)
     AND NOT EXISTS(SELECT 1 FROM rag_documents d WHERE d.account_key=rag_pdf_jobs.account_key AND d.document_id=rag_pdf_jobs.document_id)
    RETURNING start_claim_id`,startClaimId,n,p.jobId,p.pdfSha256,p.notAfter,n,n,n,RAW_PDF_CONSENT_VERSION).all();
   check();
   if(r.results.length!==1||r.results[0].start_claim_id!==startClaimId)fail('pdf_start_denied');
   return Object.freeze({granted:true,startClaimId});
  };
  return await Promise.race([work(),new Promise((_: any,reject: any)=>{timer=setTimeout(()=>{closed=true;reject(Error('pdf_start_timeout'));},Math.max(1,timeoutMs-(performance.now()-begun)));})]);
 }catch(e: any){throw Error(allowed.has(e?.message)?e.message:'pdf_start_unavailable');}
 finally{closed=true;clearTimeout(timer);}
}
