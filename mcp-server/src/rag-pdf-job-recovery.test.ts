// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from './rag/pdf-intake.ts';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched,requestRawPDFJobStop,settleRawPDFJob} from './rag/pdf-jobs.ts';
import {recoverRawPDFJobs,rawPDFRecoveryStatus} from './rag/pdf-job-recovery.ts';
const session={sub:'synthetic-recovery-owner'};
const policy={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,
 perOwnerDailyUnits:10,globalDailyUnits:20,reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
async function setup({claim=true,dispatch=false,migration=true}={}){
 const e=qualityEnvironment();e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const file of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql',...(migration?['0013_rag_pdf_job_recovery.sql']:[])])
  e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${file}`,import.meta.url),'utf8'));
 let now=1000000,calls=0;const options={clock:()=>now,timeoutMs:15};
 const key=await accountKey(session.sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const proof=await prepareRawPDFIntake(e,session,{documentId:'synthetic-pdf',requestId:'synthetic-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1},options);
 const job=await reserveRawPDFJob(e,session,proof,policy,options);
 const token=claim?(await claimRawPDFJob(e,session,proof,job.jobId,options)).executionToken:null;
 if(dispatch)await markRawPDFJobDispatched(e,session,proof,job.jobId,token,options);
 e.DOCLING_PROCESSOR={cancel:async id=>{assert.equal(id,job.jobId);calls++;return {cancelled:true};},parse:()=>assert.fail('recovery must never parse')};
 return {e,job,token,options,proof,calls:()=>calls,setTime:n=>{now=n;},
  row:()=>e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').get(),
  journal:()=>e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_job_recovery').get(),
  stop:()=>requestRawPDFJobStop(e,session,job.jobId),run:()=>recoverRawPDFJobs(e,options)};
}
const rejects=(fn,code)=>assert.rejects(fn,e=>e.message===code);

test('expiry closes only unclaimed job, without parsing or remote cancellation',async()=>{
 const s=await setup({claim:false});s.setTime(s.job.deadline);
 assert.deepEqual(await s.run(),{expired:1,closedUnclaimed:1,attempted:0,remoteConfirmed:0});
 assert.equal(s.row().state,'settled');assert.equal(s.row().settled_units,0);assert.equal(s.calls(),0);
 await rejects(()=>claimRawPDFJob(s.e,session,s.proof,s.job.jobId,s.options),'pdf_job_claim_conflict');
});
test('active nonexpired jobs untouched; expired claimed job is remotely stopped but retains full slot',async()=>{
 const s=await setup({dispatch:true});assert.equal((await s.run()).attempted,0);s.setTime(s.job.deadline);
 assert.equal((await s.run()).remoteConfirmed,1);assert.equal(s.row().state,'stop_requested');assert.equal(s.row().settled_units,null);
 assert.equal(s.row().memory_weight,67108864);assert.equal(s.journal().state,'remote_stopped');
 assert.equal((await s.run()).attempted,0);assert.equal(s.calls(),1);
 assert.deepEqual(await rawPDFRecoveryStatus(s.e,s.options),{heldClaimed:1,remoteStopped:1,needsAttention:0,leased:0,oldestOverdueMs:0});
});
test('withdrawn consent and disabled flags do not prevent stopping',async()=>{
 const s=await setup();await updateConsent(s.e,await accountKey(session.sub),{enabled:false,expectedEpoch:1});
 s.e.RAG_ENABLED=s.e.RAG_AUTO_INDEX_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED=s.e.AI_PROVIDER_APPROVED='false';
 assert.equal((await s.run()).remoteConfirmed,1);assert.equal(s.row().state,'stop_requested');
});
test('two concurrent passes have one lease winner and one remote cancel',async()=>{
 const s=await setup();await s.stop();const pending=deferred(),entered=deferred();let calls=0;
 s.e.DOCLING_PROCESSOR.cancel=()=>{calls++;entered.resolve();return pending.promise;};
 const a=s.run(),b=s.run();await entered.promise;pending.resolve({cancelled:true});
 const both=await Promise.all([a,b]);assert.equal(calls,1);assert.equal(both.reduce((n,r)=>n+r.attempted,0),1);
});
test('fixed backoff counts failures, caps attempts and exposes aggregate attention without leaking upstream errors',async()=>{
 const s=await setup();await s.stop();s.e.DOCLING_PROCESSOR.cancel=async()=>{throw new Error('sensitive-upstream-detail');};
 await s.run();assert.equal(s.journal().attempts,1);assert.equal(s.journal().next_attempt_at,1010000);
 assert.equal((await s.run()).attempted,0);s.setTime(1010000);await s.run();assert.equal(s.journal().next_attempt_at,1040000);
 s.setTime(1040000);await s.run();assert.equal(s.journal().attempts,3);assert.equal(s.journal().state,'needs_attention');
 s.setTime(2000000);assert.equal((await s.run()).attempted,0);
 const status=await rawPDFRecoveryStatus(s.e,s.options);assert.equal(status.needsAttention,1);assert.equal(status.heldClaimed,1);
 assert.equal(JSON.stringify(s.journal()).includes('sensitive'),false);assert.equal(s.row().settled_units,null);
});
test('timeout is counted and late remote success cannot rewrite journal or release reservation',async()=>{
 const s=await setup();await s.stop();const pending=deferred();s.e.DOCLING_PROCESSOR.cancel=()=>pending.promise;
 await s.run();assert.equal(s.journal().outcome,'timeout');assert.equal(s.journal().attempts,1);
 pending.resolve({cancelled:true});await new Promise(resolve=>setTimeout(resolve,5));
 assert.equal(s.journal().outcome,'timeout');assert.equal(s.row().state,'stop_requested');
});
test('invalid acknowledgement never counts as confirmed stop',async()=>{
 for(const ack of [undefined,{cancelled:false},{cancelled:true,detail:'unexpected'},true]){
  const s=await setup();await s.stop();s.e.DOCLING_PROCESSOR.cancel=async()=>ack;
  assert.equal((await s.run()).remoteConfirmed,0);assert.equal(s.journal().outcome,'failed');
 }
});
test('executor settlement wins over cleanup journal and is never charged twice',async()=>{
 const s=await setup({dispatch:true});await s.stop();
 s.e.DOCLING_PROCESSOR.cancel=async()=>{await settleRawPDFJob(s.e,s.job.jobId,s.token,{stopConfirmed:true});return {cancelled:true};};
 await s.run();await s.run();assert.equal(s.journal().state,'done');assert.equal(s.row().settled_units,3);
 assert.equal((await rawPDFRecoveryStatus(s.e,s.options)).heldClaimed,0);
});
test('crashed final attempt is marked exhausted after lease expiry; no fourth RPC',async()=>{
 const s=await setup();await s.stop();await s.run();
 s.e.ADMIN_DB.db.prepare("UPDATE rag_pdf_job_recovery SET state='pending',attempts=3,lease_id='synthetic-lease',lease_until=?,next_attempt_at=0").run(1030000);
 assert.equal((await s.run()).attempted,0);s.setTime(1030000);await s.run();
 assert.equal(s.journal().state,'needs_attention');assert.equal(s.journal().outcome,'exhausted');assert.equal(s.calls(),1);
});
test('stale lease acknowledgement cannot overwrite replacement lease',async()=>{
 const s=await setup();await s.stop();
 s.e.DOCLING_PROCESSOR.cancel=async()=>{
  s.e.ADMIN_DB.db.exec("UPDATE rag_pdf_job_recovery SET lease_id='replacement',lease_until=1090000,attempts=2");
  return {cancelled:true};
 };
 assert.equal((await s.run()).remoteConfirmed,0);assert.equal(s.journal().lease_id,'replacement');assert.equal(s.journal().state,'pending');
});
test('missing binding, schema, invalid policy and SQL errors use fixed failures',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR=null;await rejects(()=>s.run(),'pdf_recovery_binding_required');
 const old=await setup({migration:false});await rejects(()=>old.run(),'pdf_recovery_upgrade_required');
 const good=await setup();for(const more of [{limit:0},{limit:11},{timeoutMs:2001},{clock:()=>NaN}])
  await rejects(()=>recoverRawPDFJobs(good.e,{...good.options,...more}),'invalid_pdf_recovery_options');
 good.e.ADMIN_DB.prepare=()=>{throw new Error('private sql detail');};await rejects(()=>good.run(),'pdf_recovery_unavailable');
});
test('each pass bounds unclaimed settlement and leaves other rows for a later pass',async()=>{
 const s=await setup({claim:false});await s.stop();
 // Synthetic stopped reservations only: simulate a backlog without dispatching PDFs.
 for(let i=0;i<3;i++)s.e.ADMIN_DB.db.prepare(`INSERT INTO rag_pdf_jobs
  SELECT ?,account_key,document_id,?,generation,consent_epoch,raw_consent_epoch,state,token_hash,ever_dispatched,
   window_start,reserved_units,settled_units,memory_weight,policy_version,deadline FROM rag_pdf_jobs WHERE job_id=?`)
  .run(crypto.randomUUID(),crypto.randomUUID(),s.job.jobId);
 assert.equal((await recoverRawPDFJobs(s.e,{...s.options,limit:2})).closedUnclaimed,2);
 assert.equal(s.e.ADMIN_DB.db.prepare("SELECT COUNT(*) AS n FROM rag_pdf_jobs WHERE state='stop_requested'").get().n,2);
 assert.equal((await recoverRawPDFJobs(s.e,{...s.options,limit:2})).closedUnclaimed,2);
});
test('stalled claim SQL ends the pass; its late write cannot dispatch or release anything',async()=>{
 const s=await setup();await s.stop();const ready=deferred(),release=deferred(),base=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);
 s.e.ADMIN_DB.prepare=sql=>{
  const original=base(sql);if(!sql.includes('SET attempts=attempts+1'))return original;
  return {bind:(...args)=>({run:async()=>{ready.resolve();await release.promise;return original.bind(...args).run();}})};
 };
 const pass=s.run();await ready.promise;await rejects(()=>pass,'pdf_recovery_timeout');
 assert.equal(s.calls(),0);assert.equal(s.row().state,'stop_requested');
 release.resolve();await new Promise(resolve=>setTimeout(resolve,5));
 assert.equal(s.journal().attempts,1);assert.equal(s.calls(),0);assert.equal(s.row().settled_units,null);
});
