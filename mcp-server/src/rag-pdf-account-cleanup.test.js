import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.js';
import {accountKey} from './rag/storage.js';
import {updateConsent} from './rag/control.js';
import {updateRawPDFConsent} from './rag/pdf-authorization.js';
import {prepareRawPDFIntake} from './rag/pdf-intake.js';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched} from './rag/pdf-jobs.js';
import {beginRawPDFStopEvidence} from './rag/pdf-stop-evidence.js';
import {cleanupAccountRawPDF} from './rag/pdf-account-cleanup.js';
import {recoverAccountRawPDFJobs} from './rag/pdf-job-recovery.js';
import {deleteAccount,startAccountDeletion} from './account-deletion.js';
import {sha256Hex} from './auth.js';
const sub='synthetic-account-cleanup',session={sub};
const policy={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:100,globalDailyUnits:100,
 reservationUnits:3,perOwnerDailyRequests:100,globalDailyRequests:100};
async function setup({claim='legacy',binding=true}={}){
 const e=qualityEnvironment(),db=e.ADMIN_DB.db;
 e.RAG_AUTO_INDEX_ENABLED=e.AI_PROVIDER_APPROVED=e.RAG_PDF_PROCESSING_ENABLED=e.RAG_PDF_STOP_EVIDENCE_ENABLED='true';
 for(const name of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql',
  '0014_rag_pdf_retention.sql','0015_rag_pdf_purge.sql','0016_rag_pdf_stop_evidence.sql','0017_rag_pdf_evidence_retention.sql'])
  db.exec(readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8'));
 const key=await accountKey(sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const proof=await prepareRawPDFIntake(e,session,{documentId:'synthetic-document',requestId:'synthetic-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1});
 const job=await reserveRawPDFJob(e,session,proof,policy);
 let scope,token;
 if(claim==='proof'){scope=await beginRawPDFStopEvidence(e,session,proof,job.jobId);token=scope.executionToken;}
 else if(claim==='legacy')token=(await claimRawPDFJob(e,session,proof,job.jobId)).executionToken;
 if(token)await markRawPDFJobDispatched(e,session,proof,job.jobId,token);
 let calls=0;if(binding)e.DOCLING_PROCESSOR={cancel:async()=>{calls++;return {cancelled:true};}};
 const values=new Map();e.STUDIQUO_DATA={
  get:async(k,type)=>{const v=values.get(k)??null;return type==='json'&&v?JSON.parse(v):v;},
  put:async(k,v)=>{values.set(k,v);},delete:async k=>{values.delete(k);},
  list:async({prefix})=>({keys:[...values.keys()].filter(k=>k.startsWith(prefix)).map(name=>({name})),list_complete:true}),
 };
 values.set(`account:${sub}`,'{}');values.set('session:synthetic-session',JSON.stringify({sub}));values.set('snapshot:synthetic-session','synthetic');
 // Keep real RAG SQLite behavior while stubbing unrelated existing dashboard tables.
 const base=e.ADMIN_DB.prepare;
 e.ADMIN_DB.prepare=sql=>/\brag_|sqlite_master|PRAGMA/iu.test(sql)?base(sql):({bind(){return {run:async()=>({meta:{changes:0}}),all:async()=>({results:[]})};}});
 const stateKey=`account-deletion:${await sha256Hex(sub)}`,jobKey=`privacy-account-delete:${await sha256Hex(sub)}`;
 return {e,db,key,scope,job,values,calls:()=>calls,stateKey,jobKey,
  state:()=>JSON.parse(values.get(stateKey)||'null'),row:()=>db.prepare('SELECT * FROM rag_pdf_jobs WHERE job_id=?').get(job.jobId),
  run:()=>deleteAccount(e,sub)};
}

test('unclaimed owner reservation settles zero without remote binding even with every flag disabled',async()=>{
 const s=await setup({claim:null,binding:false});s.e.RAG_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED=s.e.RAG_PDF_STOP_EVIDENCE_ENABLED='false';
 assert.deepEqual(await s.run(),{deleted:true});assert.equal(s.row().settled_units,0);
 assert.equal(s.state().status,'deleted');assert.equal(s.values.has(s.jobKey),false);
});

test('remote ack alone keeps PDF pending while credentials/sessions/snapshot are erased and retry state remains',async()=>{
 const s=await setup();const result=await startAccountDeletion(s.e,sub);
 assert.deepEqual(result,{deleted:false,cleanupPending:true});assert.equal(s.row().settled_units,null);
 for(const k of [`account:${sub}`,'session:synthetic-session','snapshot:synthetic-session'])assert.equal(s.values.has(k),false);
 assert.equal(s.state().status,'deleting');assert.equal(s.state().independentCleanupComplete,true);
 assert.deepEqual(Object.keys(s.state()).sort(),['status','identityKeys','pdfCleanup','independentCleanupComplete'].sort());
 assert.deepEqual(s.state().pdfCleanup,{version:1,tracked:true,pending:true});assert.equal(s.values.has(s.jobKey),true);
 const intake=s.db.prepare('SELECT * FROM rag_pdf_intakes').get();assert.equal(intake.pdf_sha256,null);assert.equal(intake.request_id,'');
 assert.equal(s.db.prepare('SELECT deleted FROM rag_accounts').get().deleted,1);
});

test('saved local evidence plus owner-scoped remote cancellation completes account cleanup',async()=>{
 const s=await setup({claim:'proof'});await s.scope.sealAndRecord();
 assert.deepEqual(await s.run(),{deleted:true});assert.equal(s.row().settled_units,3);
 assert.equal(s.db.prepare('SELECT state FROM rag_pdf_job_recovery').get().state,'done');
 assert.ok(s.db.prepare('SELECT * FROM rag_pdf_execution_evidence').get());
});

test('identity-free retry resumes only PDF phase after pending real task finishes',async()=>{
 const s=await setup({claim:'proof'});let finish,started;
 const entered=new Promise(r=>{started=r;}),wait=new Promise(r=>{finish=r;});
 const task=s.scope.run(async()=>{started();await wait;});await entered;
 assert.deepEqual(await s.run(),{deleted:false,cleanupPending:true});assert.equal(s.calls(),1);
 finish();await task;await s.scope.sealAndRecord();
 // Independent phase must not discover/re-delete credentials or vector state.
 s.e.RAG_VECTORIZE.deleteByIds=()=>assert.fail('independent phase repeated');
 const list=s.e.STUDIQUO_DATA.list;s.e.STUDIQUO_DATA.list=()=>assert.fail('identity rediscovery repeated');
 assert.deepEqual(await s.run(),{deleted:true});assert.equal(s.row().settled_units,3);
 assert.equal(s.state().status,'deleted');assert.equal(s.values.has(s.jobKey),false);s.e.STUDIQUO_DATA.list=list;
});

test('binding missing, partial schema or previously tracked schema disappearance stays pending',async()=>{
 const noBinding=await setup({binding:false});assert.equal((await noBinding.run()).cleanupPending,true);
 const partial=await setup();partial.db.exec('DROP TABLE rag_pdf_job_recovery');
 assert.equal((await partial.run()).cleanupPending,true);assert.equal(partial.values.has(`account:${sub}`),false);
 const gone=await setup();await gone.run();delete gone.e.ADMIN_DB;gone.e.RAG_ENABLED=gone.e.RAG_PDF_PROCESSING_ENABLED='false';
 assert.equal((await gone.run()).cleanupPending,true);assert.equal(gone.state().status,'deleting');
});

test('PDF checkpoint write failure cannot announce deletion or erase credential ownership before retry',async()=>{
 const s=await setup();const put=s.e.STUDIQUO_DATA.put;let blocked=false;
 s.e.STUDIQUO_DATA.put=async(k,v)=>{const state=JSON.parse(v);if(k===s.stateKey&&state.pdfCleanup&&!blocked){blocked=true;throw Error('synthetic-checkpoint-failure');}return put(k,v);};
 await assert.rejects(()=>s.run(),/synthetic-checkpoint-failure/u);
 assert.equal(s.values.has(`account:${sub}`),true);assert.equal(s.state().status,'deleting');
 s.e.STUDIQUO_DATA.put=put;assert.equal((await s.run()).cleanupPending,true);
});

test('owner cleanup cannot cancel, settle or exhaust a different account, even with a large foreign backlog',async()=>{
 const s=await setup({claim:null}),db=s.db;
 for(let i=0;i<25;i++)db.prepare(`INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,state,
  window_start,reserved_units,memory_weight,policy_version,deadline,created_at,writer_version)
  VALUES(?,'synthetic-other',?,?,1,1,1,'reserved',0,3,67108864,'synthetic',0,0,'floor-v2')`).run(crypto.randomUUID(),crypto.randomUUID(),crypto.randomUUID());
 await s.run();assert.equal(s.row().state,'settled');
 assert.equal(db.prepare("SELECT COUNT(*) AS n FROM rag_pdf_jobs WHERE account_key='synthetic-other' AND state='reserved'").get().n,25);
 assert.equal(db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,0);assert.equal(s.calls(),0);
 for(const key of [null,undefined,{},"bad' OR 1=1",{toString:()=>s.key}])
  await assert.rejects(()=>recoverAccountRawPDFJobs(s.e,key),/invalid_pdf_recovery_options/u);
 assert.equal(db.prepare("SELECT COUNT(*) AS n FROM rag_pdf_jobs WHERE account_key='synthetic-other' AND state='reserved'").get().n,25);
});

test('more than ten owned reservations need another pass; processing a finite batch is not completion',async()=>{
 const s=await setup({claim:null,binding:false});
 for(let i=0;i<12;i++)s.db.prepare(`INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,state,
  window_start,reserved_units,memory_weight,policy_version,deadline,created_at,writer_version)
  VALUES(?,?,?,?,1,1,1,'reserved',0,3,67108864,'synthetic',0,0,'floor-v2')`).run(crypto.randomUUID(),s.key,crypto.randomUUID(),crypto.randomUUID());
 assert.equal((await s.run()).cleanupPending,true);
 assert.equal(s.db.prepare("SELECT COUNT(*) AS n FROM rag_pdf_jobs WHERE state='settled'").get().n,10);
 assert.deepEqual(await s.run(),{deleted:true});
});

test('no account fence or an invalid bounded option cannot settle jobs or expose private errors',async()=>{
 const s=await setup({claim:null});
 assert.equal((await cleanupAccountRawPDF(s.e,sub)).pending,true);assert.equal(s.row().state,'reserved');
 for(const options of [{limit:11},{timeoutMs:0},{requireSchema:'yes'}])assert.deepEqual(await cleanupAccountRawPDF(s.e,sub,options),{version:1,tracked:true,pending:true});
 const old=s.e.ADMIN_DB.prepare;s.e.ADMIN_DB.prepare=()=>{throw Error('synthetic-private-detail');};
 assert.equal(JSON.stringify(await cleanupAccountRawPDF(s.e,sub)).includes('detail'),false);s.e.ADMIN_DB.prepare=old;
});

test('PDF phase timeout cannot produce a later complete result or free a claimed slot',async()=>{
 const s=await setup();s.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(s.key);
 let finish;const wait=new Promise(r=>{finish=r;});s.e.DOCLING_PROCESSOR.cancel=()=>wait;
 const phase=await cleanupAccountRawPDF(s.e,sub,{timeoutMs:30});assert.equal(phase.pending,true);assert.equal(s.row().settled_units,null);
 finish({cancelled:true});await new Promise(r=>setTimeout(r,20));assert.equal(s.row().settled_units,null);
});

test('legacy deleted checkpoint reopens PDF-only tracking instead of silently losing held jobs',async()=>{
 const s=await setup();s.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(s.key);
 s.values.set(s.stateKey,JSON.stringify({status:'deleted',deletedAt:1,identityKeys:[sub]}));
 s.e.STUDIQUO_DATA.list=()=>assert.fail('old completed independent phases repeated');
 assert.deepEqual(await s.run(),{deleted:false,cleanupPending:true});
 assert.equal(s.state().status,'deleting');assert.equal(s.values.has(s.jobKey),true);assert.equal(s.row().settled_units,null);
});

test('legacy deleted checkpoint without PDF data upgrades to a versioned completion',async()=>{
 const s=await setup({claim:null});s.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(s.key);
 s.values.set(s.stateKey,JSON.stringify({status:'deleted',deletedAt:1,identityKeys:[sub]}));
 assert.deepEqual(await s.run(),{deleted:true});assert.equal(s.state().pdfCleanup.version,1);
 assert.equal(s.state().pdfCleanup.pending,false);assert.equal(s.row().settled_units,0);
});

test('legacy deleted RAG-nonuser creates only a denial fence and does not become permanently pending',async()=>{
 const s=await setup(),old='synthetic-legacy-rag-nonuser',key=await accountKey(old),stateKey=`account-deletion:${await sha256Hex(old)}`;
 s.values.set(stateKey,JSON.stringify({status:'deleted',deletedAt:1,identityKeys:[old]}));
 s.e.STUDIQUO_DATA.list=()=>assert.fail('independent phases repeated');
 assert.equal(s.db.prepare('SELECT 1 FROM rag_accounts WHERE account_key=?').get(key),undefined);
 assert.deepEqual(await deleteAccount(s.e,old),{deleted:true});
 assert.equal(s.db.prepare('SELECT deleted FROM rag_accounts WHERE account_key=?').get(key).deleted,1);
 assert.equal(s.db.prepare('SELECT 1 FROM rag_pdf_jobs WHERE account_key=?').get(key),undefined);
 assert.equal(JSON.parse(s.values.get(stateKey)).pdfCleanup.pending,false);
 assert.equal(s.row().state,'dispatched');
});
