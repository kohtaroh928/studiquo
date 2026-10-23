import {requestExpiredRawPDFJobsStop,rawPDFJobTimestampsSupported} from './pdf-jobs.ts';

const LEASE_MS=30000, PASS_MS=10000, BACKOFF=[10000,30000], MAX_ATTEMPTS=3;
const stmt=(db: any,sql: any,...args: any[])=>db.prepare(sql).bind(...args);
const changes=(r: any)=>r?.meta?.changes??0;
const fail=(code: any)=>{throw new Error(code);};
function time(clock: any){const n=clock();if(!Number.isSafeInteger(n)||n<0||n>Number.MAX_SAFE_INTEGER-LEASE_MS)fail('invalid_pdf_recovery_options');return n;}

// Trusted internal maintenance only. Never expose this as a client operation.
// Remote stop acknowledgement cannot prove that local reader/verifier/consumer
// tasks have ended. Claimed jobs therefore ALWAYS retain their admission slot.
export async function recoverRawPDFJobs(env: any,{clock=Date.now,limit=10,timeoutMs=2000}: any={}){
 let end: any;
 try{
  if(typeof clock!=='function'||!Number.isSafeInteger(limit)||limit<1||limit>10||
   !Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>2000)fail('invalid_pdf_recovery_options');
  const processor=env.DOCLING_PROCESSOR,db=env.ADMIN_DB;
  if(typeof processor?.cancel!=='function')fail('pdf_recovery_binding_required');
  time(clock);end=performance.now()+PASS_MS;
  // A timeout observes the original promise, but does not pretend to cancel it.
  // Late RPC results never schedule a journal write or release a slot.
  async function within(work: any,cap=PASS_MS): Promise<any>{
   const remaining=Math.min(cap,end-performance.now());if(remaining<=0)fail('pdf_recovery_timeout');
   let timer;
   try{return await Promise.race([Promise.resolve().then(work),new Promise((_,reject)=>{
    timer=setTimeout(()=>reject(new Error('pdf_recovery_timeout')),remaining);
   })]);}finally{clearTimeout(timer);}
  }
  const schema=await within(()=>stmt(db,"SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='rag_pdf_job_recovery'").first());
  if(!schema)fail('pdf_recovery_upgrade_required');
  const expired=await within(()=>requestExpiredRawPDFJobsStop(env,{clock,limit}));
  // Claim and close compete on the same job row. This never impersonates an owner.
  const timed=await within(()=>rawPDFJobTimestampsSupported(db));
  const settledAt=time(clock);
  const closed=changes(await within(()=>stmt(db,`UPDATE rag_pdf_jobs SET state='settled',settled_units=0${timed?",settled_at=MAX(?,CAST(strftime('%s','now') AS INTEGER)*1000+1000)":''}
   WHERE job_id IN (SELECT job_id FROM rag_pdf_jobs WHERE state='stop_requested' AND token_hash IS NULL
    AND ever_dispatched=0 ORDER BY deadline,job_id LIMIT ?)
   AND state='stop_requested' AND token_hash IS NULL AND ever_dispatched=0`,...(timed?[settledAt]:[]),limit).run()));
  await within(()=>stmt(db,`UPDATE rag_pdf_job_recovery SET state='done',outcome='settled',lease_id=NULL,lease_until=0
   WHERE job_id IN (SELECT r.job_id FROM rag_pdf_job_recovery r JOIN rag_pdf_jobs j USING(job_id)
    WHERE j.state='settled' AND r.state!='done' ORDER BY j.deadline,j.job_id LIMIT ?)`,limit).run());
  await within(()=>stmt(db,`INSERT OR IGNORE INTO rag_pdf_job_recovery(job_id)
   SELECT j.job_id FROM rag_pdf_jobs j WHERE j.state='stop_requested' AND j.token_hash IS NOT NULL
    AND NOT EXISTS(SELECT 1 FROM rag_pdf_job_recovery r WHERE r.job_id=j.job_id)
   ORDER BY j.deadline,j.job_id LIMIT ?`,limit).run());
  await within(()=>stmt(db,`UPDATE rag_pdf_job_recovery SET state='needs_attention',outcome='exhausted',lease_id=NULL,lease_until=0
   WHERE job_id IN (SELECT job_id FROM rag_pdf_job_recovery WHERE state='pending' AND attempts>=?
    AND lease_until<=? ORDER BY next_attempt_at,job_id LIMIT ?) AND state='pending' AND lease_until<=?`,
   MAX_ATTEMPTS,time(clock),limit,time(clock)).run());
  const candidates=await within(()=>stmt(db,`SELECT r.job_id,r.attempts FROM rag_pdf_job_recovery r JOIN rag_pdf_jobs j USING(job_id)
   WHERE j.state='stop_requested' AND r.state='pending' AND r.attempts<? AND r.next_attempt_at<=? AND r.lease_until<=?
   ORDER BY r.next_attempt_at,j.deadline,r.job_id LIMIT ?`,MAX_ATTEMPTS,time(clock),time(clock),limit).all());
  let attempted=0,confirmed=0;
  for(const candidate of candidates.results){
   // Leave enough pass time for one RPC plus its acknowledgement write.
   if(end-performance.now()<timeoutMs+100)break;
   const n=time(clock),lease=crypto.randomUUID();
   const won=changes(await within(()=>stmt(db,`UPDATE rag_pdf_job_recovery SET attempts=attempts+1,lease_id=?,lease_until=?
    WHERE job_id=? AND state='pending' AND attempts=? AND attempts<? AND next_attempt_at<=? AND lease_until<=?
    AND EXISTS(SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=rag_pdf_job_recovery.job_id AND j.state='stop_requested')`,
    lease,n+LEASE_MS,candidate.job_id,candidate.attempts,MAX_ATTEMPTS,n,n).run()));
   if(won!==1)continue;
   attempted++;
   let outcome='failed';
   try{
    const ack=await within(()=>processor.cancel(candidate.job_id),timeoutMs);
    if(ack&&typeof ack==='object'&&!Array.isArray(ack)&&Object.keys(ack).length===1&&ack.cancelled===true)outcome='confirmed';
   }catch(e: any){if(e?.message==='pdf_recovery_timeout')outcome='timeout';}
   const attempts=candidate.attempts+1,done=outcome==='confirmed',at=time(clock);
   const state=done?'remote_stopped':attempts>=MAX_ATTEMPTS?'needs_attention':'pending';
   const saved=changes(await within(()=>stmt(db,`UPDATE rag_pdf_job_recovery SET state=?,outcome=?,next_attempt_at=?,
    lease_id=NULL,lease_until=0,remote_stopped_at=? WHERE job_id=? AND state='pending' AND lease_id=? AND lease_until>?`,
    state,outcome,done||attempts>=MAX_ATTEMPTS?0:at+BACKOFF[attempts-1],done?at:null,candidate.job_id,lease,at).run()));
   if(done&&saved===1)confirmed++;
  }
  return Object.freeze({expired:expired.requested,closedUnclaimed:closed,attempted,remoteConfirmed:confirmed});
 }catch(e: any){
  const allowed=['invalid_pdf_recovery_options','pdf_recovery_binding_required','pdf_recovery_upgrade_required','pdf_recovery_timeout'];
  throw new Error(allowed.includes(e?.message)?e.message:'pdf_recovery_unavailable');
 }
}

// Aggregate diagnostics only, for a trusted operator; no owner/job IDs or tokens.
export async function rawPDFRecoveryStatus(env: any,{clock=Date.now}: any={}){
 try{
  const n=time(clock),r=await stmt(env.ADMIN_DB,`SELECT COUNT(*) AS held,
   COALESCE(SUM(CASE WHEN r.state='remote_stopped' THEN 1 ELSE 0 END),0) AS remote_stopped,
   COALESCE(SUM(CASE WHEN r.state='needs_attention' THEN 1 ELSE 0 END),0) AS needs_attention,
   COALESCE(SUM(CASE WHEN r.lease_until>? THEN 1 ELSE 0 END),0) AS leased,
   MIN(j.deadline) AS oldest FROM rag_pdf_jobs j LEFT JOIN rag_pdf_job_recovery r USING(job_id)
   WHERE j.state='stop_requested' AND j.token_hash IS NOT NULL`,n).first();
  return Object.freeze({heldClaimed:r.held,remoteStopped:r.remote_stopped,needsAttention:r.needs_attention,
   leased:r.leased,oldestOverdueMs:r.oldest===null?0:Math.max(0,n-r.oldest)});
 }catch{throw new Error('pdf_recovery_unavailable');}
}
