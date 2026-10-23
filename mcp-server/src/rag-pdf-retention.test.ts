// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake,requireRawPDFIntakeAuthorization} from './rag/pdf-intake.ts';
import {reserveRawPDFJob,claimRawPDFJob,requestRawPDFJobStop,closeUnclaimedRawPDFJob,settleRawPDFJob} from './rag/pdf-jobs.ts';
import {recoverRawPDFJobs} from './rag/pdf-job-recovery.ts';
import {minimizeExpiredRawPDFIntakes,rawPDFRetentionStatus} from './rag/pdf-retention.ts';
const user={sub:'synthetic-retention-owner'};
const policy={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,
 perOwnerDailyUnits:10,globalDailyUnits:20,reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
const reject=(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.message,code);return true;});
const ddl=name=>readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8');
const retentionDDL=()=>ddl('0014_rag_pdf_retention.sql');
async function setup({retention=true}={}){
 const env=qualityEnvironment(),db=env.ADMIN_DB.db;
 env.AI_PROVIDER_APPROVED=env.RAG_AUTO_INDEX_ENABLED=env.RAG_PDF_PROCESSING_ENABLED=env.RAG_PDF_RETENTION_ENABLED='true';
 for(const name of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql'])db.exec(ddl(name));
 if(retention)db.exec(retentionDDL());
 const key=await accountKey(user.sub);await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,user,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 let now=1000000;const options={clock:()=>now};
 const payload=(documentId='doc',more={})=>({documentId,requestId:`req-${documentId}`,expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1,...more});
 return {env,db,key,options,setTime:n=>{now=n;},payload,
  intake:(documentId,more)=>prepareRawPDFIntake(env,user,payload(documentId,more),options),
  reserve:p=>reserveRawPDFJob(env,user,p,policy,options),
  cleanup:more=>minimizeExpiredRawPDFIntakes(env,{...options,...more}),
  status:()=>rawPDFRetentionStatus(env,options)};
}
const accounting=s=>s.db.prepare(`SELECT COUNT(*) AS requests,SUM(COALESCE(settled_units,reserved_units)) AS units,
 SUM(CASE WHEN state!='settled' THEN memory_weight ELSE 0 END) AS memory FROM rag_pdf_jobs`).get();

test('expiry boundary minimizes details atomically and preserves fences, claimed accounting and unknown stop',async()=>{
 const s=await setup(),p=await s.intake(),j=await s.reserve(p);
 await claimRawPDFJob(s.env,user,p,j.jobId,s.options);const before=accounting(s);
 s.setTime(p.expiresAt-1);assert.deepEqual(await s.cleanup(),{minimized:0});
 s.setTime(p.expiresAt);assert.deepEqual(await s.cleanup(),{minimized:1});
 const row=s.db.prepare('SELECT * FROM rag_pdf_intakes').get();
 for(const name of ['account_key','document_id','intake_id','generation','consent_epoch','raw_consent_epoch','expires_at'])
  assert.notEqual(row[name],undefined);
 assert.equal(row.intake_id,p.intakeId);assert.equal(row.generation,p.generation);assert.equal(row.state,'cancelled');
 assert.equal(row.pdf_sha256,null);assert.equal(row.byte_length,null);assert.equal(row.request_id,'');
 assert.equal(s.db.prepare('SELECT state FROM rag_pdf_jobs').get().state,'stop_requested');
 assert.deepEqual(accounting(s),before);assert.deepEqual(await s.cleanup(),{minimized:0});
 await reject(()=>requireRawPDFIntakeAuthorization(s.env,user,p,{clock:()=>1000000}),'pdf_intake_not_authorized');
 await reject(()=>s.intake(),'pdf_intake_conflict');
 assert.equal((await s.intake('doc',{expectedGeneration:1,requestId:'req-new'})).generation,2);
});

test('pass writes at most ten rows, cancelled request metadata is also minimized',async()=>{
 const s=await setup();for(let i=0;i<12;i++)await s.intake(`doc-${i}`);
 s.db.exec("UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL WHERE document_id='doc-0'");
 s.setTime(1600000);assert.deepEqual(await s.cleanup(),{minimized:10});
 assert.equal((await s.status()).expiredIntakes,2);assert.deepEqual(await s.cleanup(),{minimized:2});
 assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,12);
 assert.equal((await s.status()).expiredIntakes,0);
});

test('replacement immediately before cleanup write is not erased',async()=>{
 const s=await setup(),p=await s.intake();s.setTime(p.expiresAt);
 const prepare=s.env.ADMIN_DB.prepare;let replacement;
 s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const bound=st.bind(...args);
  if(sql.startsWith('UPDATE rag_pdf_intakes\n')){const all=bound.all;bound.all=async()=>{
   replacement=await s.intake('doc',{expectedGeneration:1,requestId:'req-replacement'});return all();};}return bound;}};};
 assert.deepEqual(await s.cleanup(),{minimized:0});
 assert.equal(s.db.prepare('SELECT intake_id FROM rag_pdf_intakes').get().intake_id,replacement.intakeId);
 await requireRawPDFIntakeAuthorization(s.env,user,replacement,s.options);
});

test('captured earlier now cannot reserve after durable expiry cancellation',async()=>{
 const s=await setup(),p=await s.intake(),prepare=s.env.ADMIN_DB.prepare;
 s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const bound=st.bind(...args);
  if(sql.startsWith('INSERT OR IGNORE INTO rag_pdf_jobs')){const run=bound.run;bound.run=async()=>{
   s.setTime(p.expiresAt);await s.cleanup();return run();};}return bound;}};};
 await reject(()=>s.reserve(p),'pdf_job_admission_denied');
 assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_jobs').get().n,0);
});

test('all three settlement paths timestamp once, including settlement long after deadline',async()=>{
 for(const mode of ['executor','unclaimed','recovery']){
  const s=await setup(),p=await s.intake(),j=await s.reserve(p);let token;
  assert.equal(s.db.prepare('SELECT created_at FROM rag_pdf_jobs').get().created_at,1000000);
  if(mode==='executor')token=(await claimRawPDFJob(s.env,user,p,j.jobId,s.options)).executionToken;
  const settledAt=Date.now()+86400000;
  await requestRawPDFJobStop(s.env,user,j.jobId);s.setTime(settledAt);
  const settle=()=>mode==='executor'?settleRawPDFJob(s.env,j.jobId,token,{...s.options,stopConfirmed:true}):
   mode==='unclaimed'?closeUnclaimedRawPDFJob(s.env,user,j.jobId,s.options):
   recoverRawPDFJobs(s.env,s.options);
  s.env.DOCLING_PROCESSOR={cancel:()=>assert.fail('unclaimed never calls remote')};
  await settle();const row=s.db.prepare('SELECT * FROM rag_pdf_jobs').get();
  assert.equal(row.settled_at,settledAt);assert.equal(row.settled_units,0);
  s.setTime(settledAt+1000);await settle();assert.equal(s.db.prepare('SELECT settled_at FROM rag_pdf_jobs').get().settled_at,settledAt);
 }
});

test('0014 preserves old settled unknown times and retries do not backfill them; old schema stopping still works',async()=>{
 const s=await setup({retention:false}),p=await s.intake(),j=await s.reserve(p);
 await requestRawPDFJobStop(s.env,user,j.jobId);await closeUnclaimedRawPDFJob(s.env,user,j.jobId,s.options);
 const before=accounting(s);s.db.exec(retentionDDL());
 await closeUnclaimedRawPDFJob(s.env,user,j.jobId,s.options);
 const row=s.db.prepare('SELECT * FROM rag_pdf_jobs').get();assert.equal(row.created_at,null);assert.equal(row.settled_at,null);
 assert.deepEqual(accounting(s),before);assert.equal((await s.status()).settledWithoutTime,1);
});

test('late settlement SQL uses conservative DB execution time rather than old JS capture',async()=>{
 const s=await setup(),p=await s.intake(),j=await s.reserve(p);
 await requestRawPDFJobStop(s.env,user,j.jobId);
 const prepare=s.env.ADMIN_DB.prepare;let release,entered;
 const wait=new Promise(r=>{release=r;}),ready=new Promise(r=>{entered=r;});
 s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const bound=st.bind(...args);
  if(sql.startsWith("UPDATE rag_pdf_jobs SET state='settled'")){const run=bound.run;bound.run=async()=>{entered();await wait;return run();};}return bound;}};};
 const pending=closeUnclaimedRawPDFJob(s.env,user,j.jobId,s.options);await ready;
 const before=Date.now();release();await pending;
 const at=s.db.prepare('SELECT settled_at FROM rag_pdf_jobs').get().settled_at;
 assert.ok(at>=before);assert.ok(at<=Date.now()+1000);
});

test('expired cleanup preserves requests, units and active reservations in every job state',async()=>{
 for(const state of ['reserved','receiving','dispatched','stop_requested','settled']){
  const s=await setup(),p=await s.intake(),j=await s.reserve(p);
  // Synthetic SQL fixture spans every persisted state, including a zero-unit settlement.
  s.db.prepare(`UPDATE rag_pdf_jobs SET state=?,token_hash=?,ever_dispatched=?,settled_units=? WHERE job_id=?`)
   .run(state,state==='reserved'?null:'b'.repeat(64),state==='dispatched'?1:0,state==='settled'?0:null,j.jobId);
  const before=accounting(s);s.setTime(p.expiresAt);await s.cleanup();
  assert.deepEqual(accounting(s),before);
  assert.equal(s.db.prepare('SELECT state FROM rag_pdf_jobs').get().state,state==='settled'?'settled':'stop_requested');
 }
});

test('retention gates fail closed on missing schema, missing control or flag; errors contain no DB data',async()=>{
 const old=await setup({retention:false});await reject(()=>old.cleanup(),'pdf_retention_upgrade_required');
 const s=await setup();await s.intake();s.setTime(1600000);
 s.env.RAG_PDF_RETENTION_ENABLED='false';await reject(()=>s.cleanup(),'pdf_retention_disabled');
 s.env.RAG_PDF_RETENTION_ENABLED='true';
 s.env.ADMIN_DB.prepare=()=>{throw new Error('sensitive-sql-detail');};
 await reject(()=>s.cleanup(),'pdf_retention_unavailable');
 await reject(()=>s.status(),'pdf_retention_unavailable');
 assert.equal(s.db.prepare('SELECT state FROM rag_pdf_intakes').get().state,'pending');
});

test('migration locks physical purge and monotonic floor, including old raw INSERT writers',async()=>{
 const s=await setup();
 assert.throws(()=>s.db.exec('UPDATE rag_pdf_retention_control SET physical_purge_enabled=1'));
 assert.throws(()=>s.db.exec("UPDATE rag_pdf_retention_control SET policy_version='unknown'"));
 assert.throws(()=>s.db.exec('DELETE FROM rag_pdf_retention_control'));
 s.db.exec('UPDATE rag_pdf_retention_control SET min_admission_window=86400000');
 assert.throws(()=>s.db.exec('UPDATE rag_pdf_retention_control SET min_admission_window=0'));
 assert.throws(()=>s.db.exec("INSERT OR REPLACE INTO rag_pdf_retention_control(singleton,policy_version) VALUES(1,'raw-pdf-retention-v1')"));
 assert.equal(s.db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').get().n,86400000);
 const p=await s.intake();await reject(()=>s.reserve(p),'pdf_job_unavailable');
 // Simulate the pre-0014 writer, which does not bind timestamps or inspect floor.
 assert.throws(()=>s.db.prepare(`INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,
 consent_epoch,raw_consent_epoch,state,window_start,reserved_units,memory_weight,policy_version,deadline)
 VALUES(?,?,?,?,1,1,1,'reserved',0,3,67108864,'old',1600000)`)
  .run(crypto.randomUUID(),s.key,'doc',p.intakeId),/pdf_job_admission_window_closed/u);
});

test('aggregate status is read only and contains only fixed non-identifying fields',async()=>{
 const s=await setup(),p=await s.intake();await s.reserve(p);s.setTime(p.expiresAt+5);
 const before=s.db.prepare('SELECT * FROM rag_pdf_intakes').get();
 assert.deepEqual(await s.status(),{expiredIntakes:1,oldestExpiredMs:5,heldJobs:1,settledWithoutTime:0,settledWithTime:0,physicalPurgeEnabled:false});
 assert.deepEqual(s.db.prepare('SELECT * FROM rag_pdf_intakes').get(),before);
});

test('cleanup uses expiry index across a large set; LIMIT alone is not the scan bound',async()=>{
 const s=await setup();
 const plans=s.db.prepare(`EXPLAIN QUERY PLAN SELECT intake_id FROM rag_pdf_intakes INDEXED BY rag_pdf_intakes_retention_due
 WHERE (state='pending' OR (state='cancelled' AND request_id!='')) AND expires_at<=? ORDER BY expires_at LIMIT ?`).all(1600000,10);
 assert.ok(plans.some(p=>/SEARCH.*rag_pdf_intakes_retention_due.*expires_at/u.test(p.detail)));
 const insert=s.db.prepare(`INSERT INTO rag_pdf_intakes VALUES(?,?,?,?,1,1,1,'cancelled',NULL,NULL,2000000)`);
 s.db.exec('BEGIN');for(let i=0;i<10000;i++)insert.run(s.key,`bulk-${i}`,crypto.randomUUID(),'');s.db.exec('COMMIT');
 await s.intake();s.setTime(1600000);assert.deepEqual(await s.cleanup(),{minimized:1});
});

test('strict options reject oversized pass, noninteger clocks and invalid limits',async()=>{
 const s=await setup();for(const option of [{limit:0},{limit:11},{timeoutMs:10001},{timeoutMs:0},{clock:()=>NaN},{clock:()=>-1},{clock:null}])
  await reject(()=>s.cleanup(option),'invalid_pdf_retention_options');
});

test('timed out late UPDATE is observed but never chains further writes or frees job',async()=>{
 const s=await setup(),p=await s.intake();await s.reserve(p);s.setTime(p.expiresAt);
 const prepare=s.env.ADMIN_DB.prepare;let release,entered;
 const ready=new Promise(r=>{entered=r;}),wait=new Promise(r=>{release=r;});let writes=0;
 s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const bound=st.bind(...args);
  if(sql.startsWith('UPDATE rag_pdf_intakes\n')){const all=bound.all;bound.all=async()=>{writes++;entered();await wait;return all();};}return bound;}};};
 const pending=s.cleanup({timeoutMs:50});const rejected=reject(()=>pending,'pdf_retention_timeout');await ready;await rejected;
 const before=accounting(s);release();await new Promise(r=>setTimeout(r,10));
 assert.equal(writes,1);assert.equal(s.db.prepare('SELECT state FROM rag_pdf_intakes').get().state,'cancelled');
 assert.deepEqual(accounting(s),before);
});
