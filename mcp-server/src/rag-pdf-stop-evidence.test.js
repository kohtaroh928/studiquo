import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.js';
import {accountKey} from './rag/storage.js';
import {updateConsent} from './rag/control.js';
import {updateRawPDFConsent} from './rag/pdf-authorization.js';
import {prepareRawPDFIntake} from './rag/pdf-intake.js';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched,settleRawPDFJob} from './rag/pdf-jobs.js';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from './rag/pdf-stop-evidence.js';
import {purgeSettledRawPDFJobs} from './rag/pdf-purge.js';
import {rawPDFRetentionStatus} from './rag/pdf-retention.js';
const session={sub:'synthetic-stop-evidence-owner'};
const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
 reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
const reject=(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.message,code);return true;});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
async function setup({migration=true,legacy=false}={}){
 const env=qualityEnvironment(),db=env.ADMIN_DB.db;
 env.AI_PROVIDER_APPROVED=env.RAG_AUTO_INDEX_ENABLED=env.RAG_PDF_PROCESSING_ENABLED=env.RAG_PDF_STOP_EVIDENCE_ENABLED='true';
 for(const name of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql',
  '0014_rag_pdf_retention.sql','0015_rag_pdf_purge.sql',...(migration?['0016_rag_pdf_stop_evidence.sql']:[])])
  db.exec(readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8'));
 const key=await accountKey(session.sub);await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const options={clock:()=>1000000};
 const proof=await prepareRawPDFIntake(env,session,{documentId:'synthetic-stop-document',requestId:'synthetic-stop-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1},options);
 const job=await reserveRawPDFJob(env,session,proof,limits,options);let calls=0;
 env.DOCLING_PROCESSOR={cancel:async id=>{assert.equal(id,job.jobId);calls++;return {cancelled:true};},parse:()=>assert.fail('proof recovery never parses')};
 const scope=migration?(legacy?await claimRawPDFJob(env,session,proof,job.jobId,options):await beginRawPDFStopEvidence(env,session,proof,job.jobId,options)):null;
 return {env,db,key,proof,job,scope,options,calls:()=>calls,
  row:()=>db.prepare('SELECT * FROM rag_pdf_jobs').get(),
  evidence:()=>db.prepare('SELECT * FROM rag_pdf_execution_evidence').get(),
  local:more=>scope.sealAndRecord({...options,...more}),
  remote:more=>confirmRawPDFRemoteStop(env,job.jobId,{...options,...more}),
  settle:more=>settleRawPDFJobFromEvidence(env,job.jobId,{...options,...more}),
  dispatch:()=>markRawPDFJobDispatched(env,session,proof,job.jobId,scope.executionToken,options)};
}

test('opt-in claim atomically binds only a hash and protocol, without payload or raw token',async()=>{
 const s=await setup(),e=s.evidence();assert.equal(s.row().claim_protocol,'stop-proof-v1');
 assert.equal(e.claim_hash,s.row().token_hash);assert.equal(e.local_stopped_at,null);assert.equal(e.remote_stopped_at,null);
 assert.equal(JSON.stringify(e).includes(s.scope.executionToken),false);
 assert.deepEqual(Object.keys(e).sort(),['job_id','claim_hash','protocol','local_stopped_at','remote_stopped_at','remote_kind'].sort());
});

test('actual pending work cannot be replaced with a localStopped boolean or remote ack',async()=>{
 const s=await setup(),pending=deferred(),entered=deferred();await s.dispatch();
 const task=s.scope.run(async()=>{entered.resolve();await pending.promise;});await entered.promise;await s.remote();
 await reject(()=>s.local({timeoutMs:15,localStopped:true}),'pdf_stop_timeout');
 assert.equal(s.evidence().local_stopped_at,null);await reject(()=>s.settle(),'pdf_stop_evidence_incomplete');
 assert.equal(s.row().settled_units,null);pending.resolve();await task;
 // Only an explicit retry after original work finished may record quiescence.
 await s.local();await s.settle();assert.equal(s.row().settled_units,3);
});

test('reader cleanup must really complete and false/rejected cleanup cannot certify stopping',async()=>{
 const s=await setup(),pending=deferred();s.scope.registerCleanup(pending.promise);
 await reject(()=>s.local({timeoutMs:15}),'pdf_stop_timeout');assert.equal(s.evidence().local_stopped_at,null);
 pending.resolve(true);await s.local();await s.settle();assert.equal(s.row().settled_units,0);
 for(const promise of [Promise.resolve(false),Promise.resolve(undefined)]){
  const t=await setup();t.scope.registerCleanup(promise);await reject(()=>t.local(),'pdf_stop_evidence_incomplete');
 }
 const t=await setup();t.scope.registerCleanup(Promise.reject(new Error('synthetic-cleanup-error')));
 await reject(()=>t.local(),'pdf_stop_evidence_incomplete');
});

test('an already-running task may register pending cleanup during sealing, and evidence waits for it',async()=>{
 const s=await setup(),entered=deferred(),finish=deferred(),cleanup=deferred();
 const task=s.scope.run(async()=>{entered.resolve();await finish.promise;
  // Mirrors a reader finally/onReaderCleanup callback after the stop begins.
  s.scope.registerCleanup(cleanup.promise);
 });await entered.promise;
 const sealing=s.local({timeoutMs:20}),rejected=reject(()=>sealing,'pdf_stop_timeout');
 finish.resolve();await task;await rejected;
 assert.equal(s.evidence().local_stopped_at,null);await reject(()=>s.settle(),'pdf_stop_evidence_incomplete');
 cleanup.resolve(true);await s.local();await s.settle();assert.equal(s.row().settled_units,0);
});

test('seal rejects scheduled and later work before any late callback can start',async()=>{
 const s=await setup();let started=0;
 const queued=s.scope.run(async()=>{started++;});const rejected=reject(()=>queued,'pdf_stop_scope_sealed');
 await s.local();await rejected;assert.equal(started,0);
 await reject(()=>s.scope.run(async()=>{started++;}),'pdf_stop_scope_sealed');assert.equal(started,0);
 assert.throws(()=>s.scope.registerCleanup(Promise.resolve(true)),/pdf_stop_scope_sealed/u);
 await reject(()=>s.dispatch(),'pdf_job_dispatch_conflict');
});

test('task results cannot carry payload outside the quiescence boundary',async()=>{
 const s=await setup();assert.throws(()=>s.scope.registerCleanup(true),/pdf_stop_task_invalid/u);
 await reject(()=>s.scope.run(async()=>({text:'synthetic-payload'})),'pdf_stop_task_invalid');
 await reject(()=>s.local(),'pdf_stop_evidence_incomplete');assert.equal(s.evidence().local_stopped_at,null);
});

test('a failed but actually finished task can stop without persisting the error',async()=>{
 const s=await setup();await reject(()=>s.scope.run(async()=>{throw new Error('synthetic-sensitive-detail');}),'pdf_stop_task_invalid');
 await s.local();await s.settle();assert.equal(s.row().settled_units,0);assert.equal(JSON.stringify(s.evidence()).includes('sensitive'),false);
});

test('local and remote evidence may arrive in either order but a dispatched job needs both',async()=>{
 for(const order of ['local','remote']){
  const s=await setup();await s.dispatch();await (order==='local'?s.local():s.remote());
  await reject(()=>s.settle(),'pdf_stop_evidence_incomplete');assert.equal(s.row().settled_units,null);
  await (order==='local'?s.remote():s.local());await s.settle();assert.equal(s.row().settled_units,3);
 }
});

test('undispatched resolution requires local evidence and irreversibly prohibits dispatch',async()=>{
 const s=await setup();await reject(()=>s.settle(),'pdf_stop_evidence_incomplete');assert.equal(s.evidence().remote_kind,null);
 await s.local();await s.settle();assert.equal(s.evidence().remote_kind,'not_dispatched');assert.equal(s.calls(),0);
 assert.throws(()=>s.db.exec("UPDATE rag_pdf_jobs SET ever_dispatched=1,state='dispatched'"),/pdf_execution_already_stopped/u);
 assert.equal(s.row().settled_units,0);
});

test('old stopConfirmed assertion cannot settle an opted-in claim without evidence',async()=>{
 const s=await setup();await reject(()=>settleRawPDFJob(s.env,s.job.jobId,s.scope.executionToken,{stopConfirmed:true}),'pdf_job_unavailable');
 assert.equal(s.row().settled_units,null);await s.local();await s.settle();
 assert.equal(s.row().settled_units,0);
});

test('legacy claims remain compatible but cannot acquire retrospective evidence',async()=>{
 const s=await setup({legacy:true});assert.equal(s.row().claim_protocol,'legacy');assert.equal(s.evidence(),undefined);
 await reject(()=>s.remote(),'pdf_stop_evidence_incomplete');await reject(()=>s.settle(),'pdf_stop_evidence_incomplete');
 assert.throws(()=>s.db.exec("UPDATE rag_pdf_jobs SET claim_protocol='stop-proof-v1'"));
 await settleRawPDFJob(s.env,s.job.jobId,s.scope.executionToken,{stopConfirmed:true});assert.equal(s.row().settled_units,0);
});

test('claim binding, proof timestamps and protocol cannot be replaced or rolled back',async()=>{
 const s=await setup();await s.dispatch();await s.remote();await s.local();const e=s.evidence();
 for(const sql of ["UPDATE rag_pdf_jobs SET token_hash='changed'","UPDATE rag_pdf_jobs SET claim_protocol='legacy'",
  'UPDATE rag_pdf_execution_evidence SET local_stopped_at=NULL','UPDATE rag_pdf_execution_evidence SET local_stopped_at=1',
  'UPDATE rag_pdf_execution_evidence SET remote_stopped_at=1',"UPDATE rag_pdf_execution_evidence SET remote_kind='not_dispatched'",
  "UPDATE rag_pdf_execution_evidence SET claim_hash='changed'",'DELETE FROM rag_pdf_execution_evidence',
  "INSERT OR REPLACE INTO rag_pdf_execution_evidence(job_id,claim_hash,protocol) SELECT job_id,claim_hash,protocol FROM rag_pdf_execution_evidence"])
  assert.throws(()=>s.db.exec(sql));
 assert.deepEqual(s.evidence(),e);
});

test('cross-job and unknown job IDs cannot borrow the original local capability',async()=>{
 const s=await setup();await s.local({jobId:crypto.randomUUID(),executionToken:crypto.randomUUID()});
 assert.ok(s.evidence().local_stopped_at);assert.equal(s.evidence().job_id,s.job.jobId);
 await reject(()=>confirmRawPDFRemoteStop(s.env,crypto.randomUUID(),s.options),'pdf_stop_evidence_incomplete');
 await reject(()=>settleRawPDFJobFromEvidence(s.env,crypto.randomUUID(),s.options),'pdf_stop_evidence_incomplete');
 assert.equal(s.row().settled_units,null);
});

test('invalid/late remote acknowledgements never create durable remote evidence',async()=>{
 for(const ack of [true,undefined,{cancelled:false},{cancelled:true,extra:1}]){
  const s=await setup();s.env.DOCLING_PROCESSOR.cancel=async()=>ack;
  await reject(()=>s.remote(),'pdf_stop_evidence_incomplete');assert.equal(s.evidence().remote_stopped_at,null);
 }
 const s=await setup(),pending=deferred();s.env.DOCLING_PROCESSOR.cancel=()=>pending.promise;
 await reject(()=>s.remote({timeoutMs:15}),'pdf_stop_timeout');pending.resolve({cancelled:true});
 await new Promise(r=>setTimeout(r,5));assert.equal(s.evidence().remote_stopped_at,null);
});

test('remote retries and repeated settlement preserve the first recorded times',async()=>{
 const s=await setup();await s.dispatch();await s.remote();const remote=s.evidence().remote_stopped_at;
 await s.remote();assert.equal(s.calls(),1);assert.equal(s.evidence().remote_stopped_at,remote);
 await s.local();const local=s.evidence().local_stopped_at;await s.local();assert.equal(s.evidence().local_stopped_at,local);
 await s.settle();const at=s.row().settled_at;await s.settle();assert.equal(s.row().settled_at,at);
 assert.equal(s.row().settled_units,3);
});

test('local transaction failure keeps evidence absent and retry never reopens the sealed scope',async()=>{
 const s=await setup();s.db.exec("CREATE TRIGGER synthetic_proof_failure BEFORE UPDATE ON rag_pdf_execution_evidence BEGIN SELECT RAISE(ABORT,'synthetic detail'); END");
 await reject(()=>s.local(),'pdf_stop_unavailable');assert.equal(s.row().state,'receiving');assert.equal(s.evidence().local_stopped_at,null);
 s.db.exec('DROP TRIGGER synthetic_proof_failure');await s.local();await s.settle();
 await reject(()=>s.scope.run(async()=>{}),'pdf_stop_scope_sealed');
});

test('loss of a proof acknowledgement and of a settle acknowledgement are recoverable from durable rows',async()=>{
 const s=await setup(),prepare=s.env.ADMIN_DB.prepare;let dropLocal=true,dropSettle=true;
 s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const b=st.bind(...args);
  if(sql.includes('WHERE job_id=? AND claim_hash=? AND protocol=? AND local_stopped_at IS NOT NULL')){
   const first=b.first;b.first=async()=>{if(dropLocal){dropLocal=false;throw new Error('synthetic response lost');}return first();};
  }
  if(sql.startsWith('SELECT 1 AS ok FROM rag_pdf_jobs j JOIN')){const first=b.first;b.first=async()=>{
   if(dropSettle){dropSettle=false;throw new Error('synthetic response lost');}return first();};}
  return b;}};};
 await reject(()=>s.local(),'pdf_stop_unavailable');assert.ok(s.evidence().local_stopped_at);
 // A different internal recovery instance needs the job ID, not the lost token.
 await reject(()=>s.settle(),'pdf_stop_unavailable');assert.equal(s.row().state,'settled');
 const at=s.row().settled_at;await s.settle();assert.equal(s.row().settled_at,at);
});

test('withdrawal and all processing flags off do not prevent proof cleanup or recovery',async()=>{
 const s=await setup();await s.dispatch();await updateConsent(s.env,s.key,{enabled:false,expectedEpoch:1});
 s.env.AI_PROVIDER_APPROVED=s.env.RAG_ENABLED=s.env.RAG_AUTO_INDEX_ENABLED=s.env.RAG_PDF_PROCESSING_ENABLED=s.env.RAG_PDF_STOP_EVIDENCE_ENABLED='false';
 await s.local();await s.remote();await s.settle();assert.equal(s.row().settled_units,3);
});

test('the extra evidence table closes old purge rather than silently dropping stop evidence',async()=>{
 const s=await setup();await s.local();await s.settle();s.db.exec('UPDATE rag_pdf_purge_control SET enabled=1');
 s.env.RAG_PDF_RETENTION_ENABLED=s.env.RAG_PDF_JOB_PURGE_ENABLED='true';
 await reject(()=>purgeSettledRawPDFJobs(s.env,s.options),'pdf_purge_unavailable');assert.ok(s.evidence());assert.equal(s.row().state,'settled');
 assert.equal((await rawPDFRetentionStatus(s.env,s.options)).physicalPurgeEnabled,false);
});

test('missing migration, disabled new claim, strict options and DB faults fail privately',async()=>{
 const old=await setup({migration:false});await reject(()=>beginRawPDFStopEvidence(old.env,session,old.proof,old.job.jobId,old.options),'pdf_stop_upgrade_required');
 const s=await setup();for(const options of [{timeoutMs:0},{timeoutMs:10001},{clock:()=>NaN}])await reject(()=>s.local(options),'invalid_pdf_stop_options');
 await reject(()=>s.remote({timeoutMs:2001}),'invalid_pdf_stop_options');
 s.env.RAG_PDF_STOP_EVIDENCE_ENABLED='false';await reject(()=>beginRawPDFStopEvidence(s.env,session,s.proof,s.job.jobId,s.options),'pdf_stop_disabled');
 s.env.ADMIN_DB.prepare=()=>{throw new Error('synthetic sensitive DB fault');};await reject(()=>s.settle(),'pdf_stop_unavailable');
});
