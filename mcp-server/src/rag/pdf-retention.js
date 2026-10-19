// Internal maintenance only. No HTTP route, scheduler, client policy or body data.
// Physical job/recovery/DO deletion is deliberately absent in Step5-A.
const VERSION='raw-pdf-retention-v1',PASS_MS=10000;
const stmt=(db,sql,...args)=>db.prepare(sql).bind(...args);
const fail=code=>{throw new Error(code);};
const due="(state='pending' OR (state='cancelled' AND request_id!=''))";
function time(clock){const n=clock();if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-PASS_MS)fail('invalid_pdf_retention_options');return n;}
function bounded(timeoutMs){
 if(!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>PASS_MS)fail('invalid_pdf_retention_options');
 const end=performance.now()+timeoutMs;
 return async work=>{
  const remaining=end-performance.now();if(remaining<=0)fail('pdf_retention_timeout');
  let timer;
  try{return await Promise.race([Promise.resolve().then(work),new Promise((_,reject)=>{
   timer=setTimeout(()=>reject(new Error('pdf_retention_timeout')),remaining);
  })]);}finally{clearTimeout(timer);}
 };
}
async function schema(db,within){
 const found=await within(()=>stmt(db,`SELECT COUNT(*) AS n FROM sqlite_master WHERE
  (type='table' AND name='rag_pdf_retention_control') OR
  (type='index' AND name IN ('rag_pdf_jobs_settled_at','rag_pdf_intakes_retention_due')) OR
  (type='trigger' AND name IN ('rag_pdf_retention_floor_monotonic','rag_pdf_retention_control_kept','rag_pdf_retention_control_no_replace','rag_pdf_jobs_retention_floor'))`).first());
 if(found?.n!==7)fail('pdf_retention_upgrade_required');
 const control=await within(()=>stmt(db,`SELECT 1 AS ok FROM rag_pdf_retention_control
  WHERE singleton=1 AND policy_version=? AND physical_purge_enabled=0`,VERSION).first());
 if(!control)fail('pdf_retention_upgrade_required');
 // Explicitly verify the additive columns even when the job table is empty.
 await within(()=>stmt(db,'SELECT created_at,settled_at FROM rag_pdf_jobs LIMIT 0').all());
}
async function guarded(work){
 try{return await work();}catch(e){
  const allowed=['invalid_pdf_retention_options','pdf_retention_disabled','pdf_retention_upgrade_required','pdf_retention_timeout'];
  throw new Error(allowed.includes(e?.message)?e.message:'pdf_retention_unavailable');
 }
}

export const minimizeExpiredRawPDFIntakes=(env,{clock=Date.now,limit=10,timeoutMs=PASS_MS}={})=>guarded(async()=>{
 if(typeof clock!=='function'||!Number.isSafeInteger(limit)||limit<1||limit>10)fail('invalid_pdf_retention_options');
 if(env.RAG_PDF_RETENTION_ENABLED!=='true')fail('pdf_retention_disabled');
 const within=bounded(timeoutMs),db=env.ADMIN_DB;time(clock);await schema(db,within);
 const at=time(clock);
 // One atomic statement: no stale candidate list can erase a replacement intake.
 // Cancelling first also defeats reserve/dispatch SQL carrying an earlier now.
 // A delayed statement may finish after timeout; it is still bounded/idempotent
 // and cannot cause a subsequent write or release any admission reservation.
 const r=await within(()=>stmt(db,`UPDATE rag_pdf_intakes
  SET state='cancelled',pdf_sha256=NULL,byte_length=NULL,request_id=''
  WHERE intake_id IN (SELECT intake_id FROM rag_pdf_intakes INDEXED BY rag_pdf_intakes_retention_due
   WHERE ${due} AND expires_at<=? ORDER BY expires_at LIMIT ?)
  AND ${due} AND expires_at<=?
  AND EXISTS(SELECT 1 FROM rag_pdf_retention_control WHERE singleton=1
   AND policy_version=? AND physical_purge_enabled=0)
  RETURNING 1 AS minimized`,at,limit,at,VERSION).all());
 // D1 meta.changes includes triggered job writes too. RETURNING counts only
 // the intake rows, so diagnostics cannot report more than the pass limit.
 return Object.freeze({minimized:r.results.length});
});

// Operator-only read; full aggregate scans are not a cheap per-request endpoint.
export const rawPDFRetentionStatus=(env,{clock=Date.now,timeoutMs=PASS_MS}={})=>guarded(async()=>{
 if(typeof clock!=='function')fail('invalid_pdf_retention_options');
 const within=bounded(timeoutMs),db=env.ADMIN_DB;const at=time(clock);await schema(db,within);
 const newer=await within(()=>stmt(db,"SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='rag_pdf_purge_control'").first());
 const purge=newer?await within(()=>stmt(db,'SELECT enabled,contract_version FROM rag_pdf_purge_control WHERE singleton=1').first()):null;
 const r=await within(()=>stmt(db,`SELECT
  (SELECT COUNT(*) FROM rag_pdf_intakes WHERE ${due} AND expires_at<=?) AS expired,
  (SELECT MIN(expires_at) FROM rag_pdf_intakes WHERE ${due} AND expires_at<=?) AS oldest,
  (SELECT COUNT(*) FROM rag_pdf_jobs WHERE state!='settled') AS held,
  (SELECT COUNT(*) FROM rag_pdf_jobs WHERE state='settled' AND settled_at IS NULL) AS unknown_settled,
  (SELECT COUNT(*) FROM rag_pdf_jobs WHERE state='settled' AND settled_at IS NOT NULL) AS dated_settled`,at,at).first());
 return Object.freeze({expiredIntakes:r.expired,oldestExpiredMs:r.oldest===null?0:Math.max(0,at-r.oldest),
  heldJobs:r.held,settledWithoutTime:r.unknown_settled,settledWithTime:r.dated_settled,
  physicalPurgeEnabled:env.RAG_PDF_RETENTION_ENABLED==='true'&&env.RAG_PDF_JOB_PURGE_ENABLED==='true'
   &&purge?.enabled===1&&purge.contract_version==='pre-adoption-v1'});
});
