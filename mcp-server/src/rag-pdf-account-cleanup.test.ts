// @ts-nocheck -- historical JS regression fixture; runtime assertions preserved during TS port.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from './rag/pdf-intake.ts';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched} from './rag/pdf-jobs.ts';
import {beginRawPDFStopEvidence} from './rag/pdf-stop-evidence.ts';
import {cleanupAccountRawPDF} from './rag/pdf-account-cleanup.ts';
import {recoverAccountRawPDFJobs} from './rag/pdf-job-recovery.ts';
import {deleteAccount,startAccountDeletion} from './account-deletion.ts';
import {sha256Hex} from './auth.ts';
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
 assert.deepEqual(Object.keys(s.state()).sort(),['status','generation','identityKeys','pdfCleanup','independentCleanupComplete'].sort());
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

for (const kind of ['raw-claimed', 'raw-unclaimed', 'hashed']) test(`legacy deleted ${kind} remains held without rewriting lifecycle or fencing another generation`, async()=>{
 const s=await setup({claim:kind==='raw-unclaimed'?null:'legacy'});
 const marker={status:'deleted',generation:3,...(kind==='hashed'?{identityHashes:[await sha256Hex(sub)]}:{identityKeys:[sub]})};
 s.values.set(s.stateKey,JSON.stringify(marker));
 const before=s.row();s.e.STUDIQUO_DATA.list=()=>assert.fail('legacy identity rediscovery');
 assert.deepEqual(await s.run(),{deleted:false,cleanupPending:true});
 assert.deepEqual(s.state(),marker);assert.deepEqual(s.row(),before);
});

test('completed current deletion keeps only identity hashes and fixed PDF phase', async()=>{
 const s=await setup({claim:'proof'});await s.scope.sealAndRecord();await s.run();
 assert.equal(s.state().identityKeys,undefined);assert.deepEqual(s.state().identityHashes,[await sha256Hex(sub)]);
 assert.deepEqual(s.state().pdfCleanup,{version:1,tracked:true,pending:false});
 const before=s.state();assert.deepEqual(await s.run(),{deleted:true});assert.deepEqual(s.state(),before);
});

test('PDF-only retry cannot overwrite a new generation or clear its queued deletion', async()=>{
 const s=await setup({claim:'proof'});await s.run();await s.scope.sealAndRecord();
 const original=s.e.STUDIQUO_DATA.get;let reads=0;
 const active={status:'active',generation:1,reregisteredAt:Date.now()};
 s.e.STUDIQUO_DATA.get=async(...args)=>{const value=await original(...args);
  if(args[0]===s.stateKey && ++reads===2){s.values.set(s.stateKey,JSON.stringify(active));
   s.values.set(s.jobKey,JSON.stringify({canonicalSub:sub,generation:1,requestedAt:Date.now()}));}return value;};
 assert.deepEqual(await s.run(),{deleted:true});assert.deepEqual(s.state(),active);
 assert.equal(JSON.parse(s.values.get(s.jobKey)).generation,1);
});

test('alias completed before canonical marker failure resumes only the same deletion generation', async()=>{
 const s=await setup({claim:'proof'});await s.scope.sealAndRecord();
 const alias='synthetic-alias';s.values.set(`identity-canonical:${alias}`,sub);
 const aliasState=`account-deletion:${await sha256Hex(alias)}`;
 const put=s.e.STUDIQUO_DATA.put;let failOnce=true;
 s.e.STUDIQUO_DATA.put=async(k,v)=>{if(k===s.stateKey&&JSON.parse(v).status==='deleted'&&failOnce){failOnce=false;throw Error('synthetic-final-write');}return put(k,v);};
 await assert.rejects(()=>s.run(),/synthetic-final-write/);
 assert.equal(JSON.parse(s.values.get(aliasState)).status,'deleted');assert.equal(s.state().status,'deleting');
 assert.deepEqual(await s.run(),{deleted:true});assert.equal(s.state().identityKeys,undefined);
});

test('legacy deleted with missing DB binding is unknown and preserves marker and queued job', async()=>{
 const s=await setup();const marker={status:'deleted',identityHashes:[await sha256Hex(sub)],generation:2};
 s.values.set(s.stateKey,JSON.stringify(marker));s.values.set(s.jobKey,JSON.stringify({generation:2,requestedAt:1}));
 delete s.e.ADMIN_DB;s.e.RAG_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED='false';
 assert.deepEqual(await s.run(),{deleted:false,cleanupPending:true});assert.deepEqual(s.state(),marker);
 assert.equal(JSON.parse(s.values.get(s.jobKey)).generation,2);
});

test('generation loss during helper schema await prevents every subsequent destructive SQL',async()=>{
 const s=await setup({claim:null});s.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(s.key);
 const original=s.e.ADMIN_DB.prepare;let owns=true,writes=0;
 s.e.ADMIN_DB.prepare=sql=>{const query=original(sql);const bind=query.bind;query.bind=(...args)=>{const statement=bind(...args);
  if(sql.startsWith('SELECT name FROM sqlite_master')){const all=statement.all;statement.all=async()=>{const result=await all();owns=false;return result;};}
  if(/^(?:INSERT|UPDATE|DELETE)/u.test(sql)){writes++;}return statement;};return query;};
 assert.equal((await cleanupAccountRawPDF(s.e,sub,{isCurrent:async()=>owns})).pending,true);
 assert.equal(writes,0);assert.equal(s.row().state,'stop_requested');
});

test('ownership guard resolving after phase timeout cannot begin a new SQL operation',async()=>{
 const s=await setup({claim:null});let release;const guard=new Promise(resolve=>{release=resolve;});let queries=0;
 const original=s.e.ADMIN_DB.prepare;s.e.ADMIN_DB.prepare=sql=>{queries++;return original(sql);};
 assert.equal((await cleanupAccountRawPDF(s.e,sub,{timeoutMs:20,isCurrent:()=>guard})).pending,true);
 release(true);await new Promise(resolve=>setTimeout(resolve,20));assert.equal(queries,0);
});

test('owner recovery checks ownership after its own schema await before requesting stops',async()=>{
 const s=await setup({claim:null});let owns=true,writes=0;const original=s.e.ADMIN_DB.prepare;
 s.e.ADMIN_DB.prepare=sql=>{const q=original(sql);const bind=q.bind;q.bind=(...args)=>{const statement=bind(...args);
  if(sql.includes("name='rag_pdf_job_recovery'")){const first=statement.first;statement.first=async()=>{const r=await first();owns=false;return r;};}
  if(/^(?:INSERT|UPDATE|DELETE)/u.test(sql))writes++;return statement;};return q;};
 await assert.rejects(()=>recoverAccountRawPDFJobs(s.e,s.key,{isCurrent:async()=>owns}));
 assert.equal(writes,0);assert.equal(s.row().state,'reserved');
});

test('alias becoming active during PDF helper schema await receives no later destructive work',async()=>{
 const s=await setup({claim:'proof'});await s.scope.sealAndRecord();
 const alias='synthetic-alias-changed',aliasKey=await accountKey(alias),aliasState=`account-deletion:${await sha256Hex(alias)}`;
 s.values.set(`identity-canonical:${alias}`,sub);
 const original=s.e.ADMIN_DB.prepare;let phase=0,changed=false,aliasWrites=0;
 s.e.ADMIN_DB.prepare=sql=>{const q=original(sql);const bind=q.bind;q.bind=(...args)=>{const statement=bind(...args);
  if(sql.startsWith('SELECT name FROM sqlite_master')&&sql.includes('rag_raw_pdf_consents')){
   const all=statement.all;statement.all=async()=>{const r=await all();if(++phase===2){changed=true;s.values.set(aliasState,JSON.stringify({status:'active',generation:1}));}return r;};}
  if(changed&&/^(?:INSERT|UPDATE|DELETE)/u.test(sql)&&args.includes(aliasKey))aliasWrites++;
  return statement;};return q;};
 assert.deepEqual(await s.run(),{deleted:false,cleanupPending:true});assert.equal(changed,true);
 assert.equal(aliasWrites,0);assert.equal(JSON.parse(s.values.get(aliasState)).status,'active');
});

test('nested recovery cannot submit a later update after the outer phase has timed out',async()=>{
 const s=await setup({claim:null});s.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(s.key);
 let release,enteredResolve,entered=false,laterWrites=0;
 const held=new Promise(resolve=>{release=resolve;}),phase=new Promise(resolve=>{enteredResolve=resolve;});
 const original=s.e.ADMIN_DB.prepare;
 s.e.ADMIN_DB.prepare=sql=>{const q=original(sql);const bind=q.bind;q.bind=(...args)=>{const statement=bind(...args);
  if(sql.includes("name='rag_pdf_job_recovery'")){const first=statement.first;statement.first=async()=>{entered=true;enteredResolve();await held;return first();};}
  if(entered&&/^(?:INSERT|UPDATE|DELETE)/u.test(sql))laterWrites++;return statement;};return q;};
 const result=cleanupAccountRawPDF(s.e,sub,{timeoutMs:1000});let phaseTimer;try{await Promise.race([phase,new Promise((_,reject)=>{phaseTimer=setTimeout(()=>reject(Error('synthetic phase not reached')),1500);})]);}finally{clearTimeout(phaseTimer);}
 assert.equal((await result).pending,true);release();await new Promise(resolve=>setTimeout(resolve,20));
 assert.equal(laterWrites,0);assert.equal(s.row().state,'stop_requested');
});
