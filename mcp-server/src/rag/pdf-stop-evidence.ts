import {cancelRawPDFProcessor} from './pdf-rpc.ts';
import {sha256Hex} from '../auth.ts';
import {claimRawPDFJobWithStopProtocol} from './pdf-jobs.ts';

const PROTOCOL='stop-proof-v1',MAX_MS=10000;
const stmt=(db: any,sql: any,...args: any[])=>db.prepare(sql).bind(...args);
const fail=(code: any)=>{throw new Error(code);};
const validId=(id: any)=>typeof id==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(id);
const dbTime="MAX(?,CAST(strftime('%s','now') AS INTEGER)*1000+1000)";
const errors=new Set(['invalid_pdf_stop_options','pdf_stop_disabled','pdf_stop_upgrade_required','pdf_stop_timeout',
 'pdf_stop_evidence_incomplete','pdf_stop_scope_sealed','pdf_stop_task_invalid','pdf_stop_claim_failed']);
async function guarded(work: any): Promise<any> {try{return await work();}catch(e: any){throw new Error(errors.has(e?.message)?e.message:'pdf_stop_unavailable');}}
function context({clock=Date.now,timeoutMs=MAX_MS}: any={}){
 if(typeof clock!=='function'||!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>MAX_MS)fail('invalid_pdf_stop_options');
 const end=performance.now()+timeoutMs;
 const now=()=>{const n=clock();if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-MAX_MS)fail('invalid_pdf_stop_options');return n;};
 now();
 const within=async (work: any): Promise<any> =>{
  const remaining=end-performance.now();if(remaining<=0)fail('pdf_stop_timeout');let timer: any;
  try{return await Promise.race([Promise.resolve().then(work),new Promise((_: any,reject: any)=>{
   timer=setTimeout(()=>reject(new Error('pdf_stop_timeout')),remaining);
  })]);}finally{clearTimeout(timer);}
 };
 return {now,within};
}
async function schema(db: any,within: any): Promise<any> {
 const r=await within(()=>stmt(db,`SELECT COUNT(*) AS n FROM sqlite_master WHERE
  (type='table' AND name='rag_pdf_execution_evidence') OR (type='trigger' AND name IN
   ('rag_pdf_evidence_claim_bind','rag_pdf_evidence_claimed','rag_pdf_evidence_no_replace','rag_pdf_evidence_monotonic',
    'rag_pdf_evidence_no_delete','rag_pdf_evidence_execution_fenced','rag_pdf_evidence_settle_guard'))`).first());
 if(r?.n!==8)fail('pdf_stop_upgrade_required');
}

// Opt-in executor capability, created with the winning claim. No raw local
// assertion/boolean API is exported. Integration MUST route actual work through
// run(), register reader cleanup, stop its monitor before sealing, and retain no
// payload outside its tracked tasks. No production orchestrator uses this yet.
export const beginRawPDFStopEvidence=(env: any,session: any,proof: any,jobId: any,options: any={})=>guarded(async(): Promise<any> =>{
 if(!validId(jobId))fail('invalid_pdf_stop_options');
 if(env.RAG_PDF_STOP_EVIDENCE_ENABLED!=='true')fail('pdf_stop_disabled');
 const {within}=context(options),db=env.ADMIN_DB;await schema(db,within);
 let claim: any;
 try{claim=await within(()=>claimRawPDFJobWithStopProtocol(env,session,proof,jobId,options));}
 catch{fail('pdf_stop_claim_failed');}
 const claimHash=await within(()=>sha256Hex(claim.executionToken));
 const tasks=new Set(),cleanups=new Set();let sealed=false,cleanupClosed=false,unsafeResult=false,cleanupFailed=false;
 function run(work: any){
  if(sealed)return Promise.reject(new Error('pdf_stop_scope_sealed'));
  if(typeof work!=='function')return Promise.reject(new Error('pdf_stop_task_invalid'));
  const task=Promise.resolve().then(async(): Promise<any> =>{
   if(sealed)fail('pdf_stop_scope_sealed');
   try{if(await work()!==undefined){unsafeResult=true;fail('pdf_stop_task_invalid');}}
   catch{throw new Error('pdf_stop_task_invalid');}
  });
  tasks.add(task);task.then(()=>tasks.delete(task),()=>tasks.delete(task));return task;
 }
 function registerCleanup(promise: any){
  // A task's finally may register its actual reader cancellation AFTER starts
  // are sealed. Keep this phase open until every already-started task has ended.
  if(cleanupClosed){cleanupFailed=true;fail('pdf_stop_scope_sealed');}
  if(!promise||typeof promise.then!=='function')fail('pdf_stop_task_invalid');
  const cleanup=Promise.resolve(promise).then((value: any)=>{if(value!==true)cleanupFailed=true;},()=>{cleanupFailed=true;});
  cleanups.add(cleanup);cleanup.then(()=>cleanups.delete(cleanup));
 }
 const sealAndRecord=(opts: any)=>guarded(async(): Promise<any> =>{
  const {within,now}=context(opts);sealed=true;
  // These are the original promises, not timeout races. A timed-out wait never
  // chains a later SQL write. Explicit retries may wait again, never rerun work.
  await within(()=>Promise.allSettled([...tasks]));
  cleanupClosed=true;
  await within(()=>Promise.allSettled([...cleanups]));
  if(unsafeResult||cleanupFailed)fail('pdf_stop_evidence_incomplete');
  await schema(db,within);
  const at=now();
  await within(()=>db.batch([
   stmt(db,`UPDATE rag_pdf_jobs SET state='stop_requested' WHERE job_id=? AND token_hash=?
    AND claim_protocol=? AND state IN ('receiving','dispatched','stop_requested')`,jobId,claimHash,PROTOCOL),
   stmt(db,`UPDATE rag_pdf_execution_evidence SET local_stopped_at=${dbTime}
    WHERE job_id=? AND claim_hash=? AND protocol=? AND local_stopped_at IS NULL
    AND EXISTS(SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=? AND j.token_hash=? AND j.claim_protocol=? AND j.state='stop_requested')`,
    at,jobId,claimHash,PROTOCOL,jobId,claimHash,PROTOCOL),
  ]));
  const found=await within(()=>stmt(db,`SELECT 1 AS ok FROM rag_pdf_execution_evidence
   WHERE job_id=? AND claim_hash=? AND protocol=? AND local_stopped_at IS NOT NULL`,jobId,claimHash,PROTOCOL).first());
  if(!found)fail('pdf_stop_evidence_incomplete');return Object.freeze({localRecorded:true});
 });
 return Object.freeze({jobId,executionToken:claim.executionToken,run,registerCleanup,sealAndRecord});
});

// Trusted internal service-binding adapter. Accepts no caller-supplied ack or
// token. A remote stop alone never proves local quiescence or releases a slot.
export const confirmRawPDFRemoteStop=(env: any,jobId: any,options: any={})=>guarded(async(): Promise<any> =>{
 if(!validId(jobId)||(options.timeoutMs??2000)>2000||(options.rpcV2!==undefined&&typeof options.rpcV2!=='boolean'))fail('invalid_pdf_stop_options');
 const {within,now}=context({...options,timeoutMs:options.timeoutMs??2000}),db=env.ADMIN_DB;
 await schema(db,within);
 const row=await within(()=>stmt(db,`SELECT e.claim_hash,e.remote_stopped_at FROM rag_pdf_execution_evidence e JOIN rag_pdf_jobs j USING(job_id)
  WHERE e.job_id=? AND e.protocol=? AND j.claim_protocol=e.protocol AND j.token_hash=e.claim_hash`,jobId,PROTOCOL).first());
 if(!row)fail('pdf_stop_evidence_incomplete');
 if(row.remote_stopped_at!==null)return Object.freeze({remoteRecorded:true});
 const ack=await within(()=>cancelRawPDFProcessor(env,jobId,{v2:options.rpcV2??false}));
 if(!ack||typeof ack!=='object'||Array.isArray(ack)||Object.keys(ack).length!==1||ack.cancelled!==true)fail('pdf_stop_evidence_incomplete');
 await within(()=>stmt(db,`UPDATE rag_pdf_execution_evidence SET remote_stopped_at=${dbTime},remote_kind='cancel_confirmed'
  WHERE job_id=? AND claim_hash=? AND protocol=? AND remote_stopped_at IS NULL
  AND EXISTS(SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=? AND j.token_hash=? AND j.claim_protocol=?)`,
  now(),jobId,row.claim_hash,PROTOCOL,jobId,row.claim_hash,PROTOCOL).run());
 return Object.freeze({remoteRecorded:true});
});

// Token-free recovery only for already durable evidence bound to the original
// claim. No flags/consent are required for stopping a previously admitted job.
export const settleRawPDFJobFromEvidence=(env: any,jobId: any,options: any={})=>guarded(async(): Promise<any> =>{
 if(!validId(jobId))fail('invalid_pdf_stop_options');const {within,now}=context(options),db=env.ADMIN_DB;
 await schema(db,within);const at=now();
 await within(()=>db.batch([
  stmt(db,`UPDATE rag_pdf_execution_evidence SET remote_stopped_at=${dbTime},remote_kind='not_dispatched'
   WHERE job_id=? AND protocol=? AND local_stopped_at IS NOT NULL AND remote_stopped_at IS NULL
   AND EXISTS(SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=? AND j.claim_protocol=? AND j.token_hash=claim_hash
    AND j.state='stop_requested' AND j.ever_dispatched=0)`,at,jobId,PROTOCOL,jobId,PROTOCOL),
  stmt(db,`UPDATE rag_pdf_jobs SET state='settled',settled_units=CASE WHEN ever_dispatched=1 THEN reserved_units ELSE 0 END,
   settled_at=${dbTime} WHERE job_id=? AND claim_protocol=? AND state='stop_requested'
   AND NOT EXISTS(SELECT 1 FROM rag_pdf_job_recovery r WHERE r.job_id=rag_pdf_jobs.job_id
    AND (r.lease_id IS NOT NULL OR r.lease_until!=0))
   AND EXISTS(SELECT 1 FROM rag_pdf_execution_evidence e WHERE e.job_id=rag_pdf_jobs.job_id AND e.claim_hash=token_hash
    AND e.protocol=? AND e.local_stopped_at IS NOT NULL AND e.remote_stopped_at IS NOT NULL
    AND (e.remote_kind='cancel_confirmed' OR (e.remote_kind='not_dispatched' AND ever_dispatched=0)))`,at,jobId,PROTOCOL,PROTOCOL),
 ]));
 const row=await within(()=>stmt(db,`SELECT 1 AS ok FROM rag_pdf_jobs j JOIN rag_pdf_execution_evidence e USING(job_id)
  WHERE j.job_id=? AND j.claim_protocol=? AND j.token_hash=e.claim_hash AND e.protocol=j.claim_protocol
   AND j.state='settled' AND e.local_stopped_at IS NOT NULL AND e.remote_stopped_at IS NOT NULL`,jobId,PROTOCOL).first());
 if(!row)fail('pdf_stop_evidence_incomplete');return Object.freeze({settled:true});
});
