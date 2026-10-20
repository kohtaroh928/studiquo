// Internal, pre-adoption maintenance. No HTTP/cron entry or runtime flag is
// enabled by this module. Database policy must be reviewed before activation.
const VERSIONS=['pre-adoption-v1','pre-adoption-stop-v2'],PASS_MS=10000;
const stmt=(db,sql,...args)=>db.prepare(sql).bind(...args);
const fail=code=>{throw new Error(code);};
const dbNow="CAST(strftime('%s','now') AS INTEGER)*1000";
export async function purgeSettledRawPDFJobs(env,{clock=Date.now,limit=10,timeoutMs=PASS_MS}={}){
 let timer;
 try{
  if(typeof clock!=='function'||!Number.isSafeInteger(limit)||limit<1||limit>10||
   !Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>PASS_MS)fail('invalid_pdf_purge_options');
  if(env.RAG_PDF_RETENTION_ENABLED!=='true'||env.RAG_PDF_JOB_PURGE_ENABLED!=='true')fail('pdf_purge_disabled');
  const start=performance.now(),n=clock();
  if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-PASS_MS)fail('invalid_pdf_purge_options');
  const db=env.ADMIN_DB;
  const run=async()=>{
   const found=await stmt(db,`SELECT COUNT(*) AS n,${dbNow} AS database_at FROM sqlite_master WHERE
    (type='table' AND name IN ('rag_pdf_purge_control','rag_pdf_retention_control','rag_pdf_job_recovery')) OR
    (type='trigger' AND name IN ('rag_pdf_purge_no_replace','rag_pdf_purge_no_delete','rag_pdf_purge_monotonic',
     'rag_pdf_jobs_writer_fence','rag_pdf_jobs_identity_kept','rag_pdf_purge_pass_guard','rag_pdf_jobs_purge_guard',
     'rag_pdf_jobs_retention_floor','rag_pdf_retention_floor_monotonic','rag_pdf_retention_control_no_replace','rag_pdf_retention_control_kept')) OR
    (type='view' AND name='rag_pdf_purge_eligible') OR (type='index' AND name='rag_pdf_jobs_purge_due')`).first();
   if(found?.n!==16)fail('pdf_purge_upgrade_required');
   const control=await stmt(db,'SELECT enabled,contract_version FROM rag_pdf_purge_control WHERE singleton=1').first();
   if(control?.enabled!==1)fail('pdf_purge_disabled');
   if(!VERSIONS.includes(control.contract_version))fail('pdf_purge_upgrade_required');
   if(control.contract_version==='pre-adoption-stop-v2'){
    const context=await stmt(db,"SELECT COUNT(*) AS n FROM sqlite_master WHERE type='trigger' AND name IN ('rag_pdf_purge_context_guard','rag_pdf_purge_context_clear')").first();
    const foreignKeys=await stmt(db,'PRAGMA foreign_key_list(rag_pdf_execution_evidence)').all();
    if(context?.n!==2||!foreignKeys.results.some(k=>k.table==='rag_pdf_jobs'&&k.from==='job_id'&&k.to==='job_id'&&k.on_delete==='CASCADE'))fail('pdf_purge_upgrade_required');
   }
   if(performance.now()-start>=timeoutMs)fail('pdf_purge_timeout');
   const token=crypto.randomUUID();
   // Anchor expiration to the initially observed database time too: an allowed
   // positive caller clock skew must not grant a longer post-timeout DB lease.
   const leaseUntil=Math.min(n+timeoutMs,found.database_at+Math.floor(timeoutMs-(performance.now()-start)));
   // SQLite time and clock/contract checks are repeated in the write trigger.
   // All four statements form one transaction. Any guard/constraint error
   // rolls back child, parent, clock, lease, writer fence and accounting floor.
   const batch=await db.batch([
    stmt(db,`UPDATE rag_pdf_purge_control SET requested_at=?,last_clock_at=${dbNow},
     writer_fenced=1,lease_id=?,lease_until=? WHERE singleton=1`,n,token,leaseUntil),
    // Materialize at most ten coarse index entries BEFORE expensive reference
    // checks. Persist the end key before DELETE so held rows cannot starve later
    // entries. An empty probe wraps the cursor for the following pass.
    stmt(db,`WITH candidates AS MATERIALIZED (
     SELECT j.settled_at,j.job_id FROM rag_pdf_jobs j INDEXED BY rag_pdf_jobs_purge_due
      JOIN rag_pdf_purge_control p ON p.singleton=1
     WHERE j.state='settled' AND j.writer_version='floor-v2' AND j.created_at IS NOT NULL AND j.settled_at IS NOT NULL
      AND j.settled_at<=${dbNow}-172800000 AND (j.settled_at,j.job_id)>(p.cursor_at,p.cursor_job)
     ORDER BY j.settled_at,j.job_id LIMIT ?)
     UPDATE rag_pdf_purge_control SET
      next_cursor_at=COALESCE((SELECT settled_at FROM candidates ORDER BY settled_at DESC,job_id DESC LIMIT 1),0),
      next_cursor_job=COALESCE((SELECT job_id FROM candidates ORDER BY settled_at DESC,job_id DESC LIMIT 1),''),
      candidate_count=(SELECT COUNT(*) FROM candidates) WHERE singleton=1 AND lease_id=?`,limit,token),
    stmt(db,`DELETE FROM rag_pdf_jobs WHERE job_id IN
     (SELECT j.job_id FROM rag_pdf_jobs j INDEXED BY rag_pdf_jobs_purge_due
      JOIN rag_pdf_purge_control p ON p.singleton=1
      WHERE j.state='settled' AND j.writer_version='floor-v2' AND j.created_at IS NOT NULL AND j.settled_at IS NOT NULL
       AND (j.settled_at,j.job_id)>(p.cursor_at,p.cursor_job)
       AND (j.settled_at,j.job_id)<=(p.next_cursor_at,p.next_cursor_job))
     AND job_id IN (SELECT job_id FROM rag_pdf_purge_eligible WHERE job_id=rag_pdf_jobs.job_id)
     AND EXISTS(SELECT 1 FROM rag_pdf_purge_control WHERE singleton=1 AND lease_id=?)
     RETURNING 1 AS purged`,token),
    stmt(db,`UPDATE rag_pdf_purge_control SET cursor_at=next_cursor_at,cursor_job=next_cursor_job,
     lease_id=NULL,lease_until=0 WHERE singleton=1 AND lease_id=?`,token),
   ]);
   return Object.freeze({purged:batch[2].results.length});
  };
  // A timed-out batch is observed but not cancelled; its stored lease/DB guards
  // deny late deletes. Never retry automatically on an unknown commit result.
  return await Promise.race([run(),new Promise((_,reject)=>{
   timer=setTimeout(()=>reject(new Error('pdf_purge_timeout')),timeoutMs);
  })]);
 }catch(e){
  const allowed=['invalid_pdf_purge_options','pdf_purge_disabled','pdf_purge_upgrade_required','pdf_purge_timeout'];
  throw new Error(allowed.includes(e?.message)?e.message:'pdf_purge_unavailable');
 }finally{clearTimeout(timer);}
}
