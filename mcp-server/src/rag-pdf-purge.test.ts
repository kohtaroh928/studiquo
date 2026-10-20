// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {purgeSettledRawPDFJobs} from './rag/pdf-purge.ts';
import {rawPDFRetentionStatus} from './rag/pdf-retention.ts';
import {reserveRawPDFJob} from './rag/pdf-jobs.ts';
import {prepareRawPDFIntake} from './rag/pdf-intake.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
const DAY=86400000,HOLD=2*DAY,BASE=100*DAY;
const reject=(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.message,code);return true;});
function setup({migrate=true,enabled=true}={}){
 const env=qualityEnvironment(),db=env.ADMIN_DB.db;let now=BASE;
 db.function('strftime',(_format,_at)=>String(Math.floor(now/1000)));
 for(const name of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql','0014_rag_pdf_retention.sql',...(migrate?['0015_rag_pdf_purge.sql']:[])])
  db.exec(readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8'));
 // Include RETURNING in the SQLite D1 fixture's batch results, as actual D1 does.
 env.ADMIN_DB.prepare=sql=>({bind(...args){const get=()=>db.prepare(sql);return {
  first:async()=>get().get(...args)??null,all:async()=>({results:get().all(...args)}),
  run:async()=>{const st=get();return st.columns().length?{results:st.all(...args)}:{results:[],meta:{changes:Number(st.run(...args).changes)}};},
 };}});
 if(migrate&&enabled)db.exec('UPDATE rag_pdf_purge_control SET enabled=1');
 env.RAG_PDF_RETENTION_ENABLED=env.RAG_PDF_JOB_PURGE_ENABLED='true';
 const options={clock:()=>now};
 function seed(more={},recovery){
  const job=crypto.randomUUID(),intake=crypto.randomUUID(),document=crypto.randomUUID();
  db.prepare("INSERT INTO rag_pdf_intakes VALUES('synthetic-owner',?,?, '',1,1,1,'cancelled',NULL,NULL,?)").run(document,intake,BASE-3*DAY);
  const row={job_id:job,account_key:'synthetic-owner',document_id:document,intake_id:intake,generation:1,
   consent_epoch:1,raw_consent_epoch:1,state:'settled',token_hash:null,ever_dispatched:0,
   window_start:BASE-3*DAY,reserved_units:3,settled_units:0,memory_weight:67108864,policy_version:'synthetic',
   deadline:BASE-3*DAY+1000,created_at:BASE-3*DAY,settled_at:BASE-HOLD,writer_version:'floor-v2',...more};
  const keys=Object.keys(row);db.prepare(`INSERT INTO rag_pdf_jobs(${keys.join(',')}) VALUES(${keys.map(()=>'?').join(',')})`).run(...Object.values(row));
  if(recovery)db.prepare(`INSERT INTO rag_pdf_job_recovery(job_id,state,lease_id,lease_until) VALUES(?,?,?,?)`)
   .run(job,recovery.state??'done',recovery.lease_id??null,recovery.lease_until??0);
  return row;
 }
 return {env,db,seed,options,setTime:n=>{now=n;},purge:more=>purgeSettledRawPDFJobs(env,{...options,...more}),
  job:id=>db.prepare('SELECT * FROM rag_pdf_jobs WHERE job_id=?').get(id),
  floor:()=>db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').get().n};
}

test('48h boundary atomically deletes settled job and done recovery, advances floor, and preserves intake fence',async()=>{
 const s=setup(),j=s.seed({},{});
 assert.deepEqual(await s.purge(),{purged:1});assert.equal(s.job(j.job_id),undefined);
 assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,0);
 assert.equal(s.db.prepare('SELECT generation FROM rag_pdf_intakes').get().generation,1);
 assert.equal(s.floor(),j.window_start+DAY);assert.deepEqual(await s.purge(),{purged:0});
 assert.equal(s.db.prepare('SELECT lease_id FROM rag_pdf_purge_control').get().lease_id,null);
});

test('keeps unknown timestamps, recent settlement, current window, legacy and active jobs',async()=>{
 for(const more of [{created_at:null},{settled_at:null},{settled_at:BASE-HOLD+1000},{created_at:BASE-HOLD+1000},
  {window_start:BASE},{writer_version:'legacy'},...['reserved','receiving','dispatched','stop_requested'].map(state=>
   ({state,settled_units:null,token_hash:state==='dispatched'?'a'.repeat(64):null,ever_dispatched:state==='dispatched'?1:0}))]){
  const s=setup(),j=s.seed(more);assert.deepEqual(await s.purge(),{purged:0});assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
 }
});

test('holds remote-stopped, unresolved recovery, and even expired but uncleared lease',async()=>{
 for(const recovery of [{state:'pending'},{state:'remote_stopped'},{state:'needs_attention'},
  {lease_id:crypto.randomUUID(),lease_until:BASE-1},{lease_id:crypto.randomUUID(),lease_until:BASE+1000}]){
  const s=setup(),j=s.seed({},recovery);assert.deepEqual(await s.purge(),{purged:0});assert.ok(s.job(j.job_id));
 }
});

test('requires durable intake invalidation, holds missing intake, allows newer generation replacement',async()=>{
 for(const mode of ['pending','missing','replaced']){
  const s=setup(),j=s.seed();
  if(mode==='pending')s.db.prepare("UPDATE rag_pdf_intakes SET state='pending',pdf_sha256=?,byte_length=100").run('a'.repeat(64));
  else if(mode==='missing')s.db.exec('DELETE FROM rag_pdf_intakes');
  else s.db.prepare('UPDATE rag_pdf_intakes SET generation=2,intake_id=?').run(crypto.randomUUID());
  assert.equal((await s.purge()).purged,mode==='replaced'?1:0);
 }
});

test('unknown contract, new receipt/PDF table and missing migration close purge',async()=>{
 const old=setup({migrate:false});await reject(()=>old.purge(),'pdf_purge_upgrade_required');
 for(const sql of ["UPDATE rag_pdf_purge_control SET contract_version='adoption-v2'",
  'CREATE TABLE rag_pdf_new_reference(id TEXT)','CREATE TABLE adoption_receipts(id TEXT)']){
  const s=setup(),j=s.seed();s.db.exec(sql);
  await reject(()=>s.purge(),sql.startsWith('UPDATE')?'pdf_purge_upgrade_required':'pdf_purge_unavailable');
  assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
 }
});

test('registered document is held for the future adoption contract',async()=>{
 const s=setup(),j=s.seed();
 s.db.prepare(`INSERT INTO rag_documents(account_key,document_id,generation,consent_epoch,state,source_hash,title,total_pages,operation_id)
 VALUES(?,?,1,1,'deleted',?,'synthetic',1,'synthetic-operation')`).run(j.account_key,j.document_id,'a'.repeat(64));
 assert.deepEqual(await s.purge(),{purged:0});assert.ok(s.job(j.job_id));
});

test('parent guard rechecks clock/lease and receipt contract inside the atomic batch',async()=>{
 for(const mutation of [s=>s.setTime(BASE+11000),s=>s.db.exec("UPDATE rag_pdf_purge_control SET contract_version='adoption-v2'"),
  s=>s.db.exec('CREATE TABLE synthetic_receipts(id TEXT)')]){
  const s=setup(),j=s.seed({},{}),prepare=s.env.ADMIN_DB.prepare;
  s.env.ADMIN_DB.prepare=sql=>{const st=prepare(sql);return {bind(...args){const bound=st.bind(...args);
   if(sql.startsWith('DELETE FROM rag_pdf_jobs')){const run=bound.run;bound.run=async()=>{mutation(s);return run();};}return bound;}};};
  await reject(()=>s.purge(),'pdf_purge_unavailable');assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
  assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,1);
 }
});

test('candidate planner uses the purge index; guards use indexed job/owner/document lookups',()=>{
 const s=setup();s.seed();
 const plan=s.db.prepare(`EXPLAIN QUERY PLAN SELECT j.settled_at,j.job_id FROM rag_pdf_jobs j INDEXED BY rag_pdf_jobs_purge_due
 JOIN rag_pdf_purge_control p ON p.singleton=1 WHERE j.state='settled' AND j.writer_version='floor-v2'
 AND j.created_at IS NOT NULL AND j.settled_at IS NOT NULL AND j.settled_at<=?
 AND (j.settled_at,j.job_id)>(p.cursor_at,p.cursor_job) ORDER BY j.settled_at,j.job_id LIMIT 10`).all(BASE-HOLD);
 assert.ok(plan.some(r=>/rag_pdf_jobs_purge_due/u.test(r.detail)));
 const guard=s.db.prepare('EXPLAIN QUERY PLAN SELECT 1 FROM rag_pdf_purge_eligible WHERE job_id=?').all(crypto.randomUUID());
 assert.ok(guard.some(r=>/SEARCH j USING INDEX sqlite_autoindex_rag_pdf_jobs_1/u.test(r.detail)));
});

test('large held backlog probes only ten coarse candidates and advances past held rows',async()=>{
 const s=setup();s.db.exec('BEGIN');
 for(let i=0;i<10000;i++)s.seed({settled_at:BASE-HOLD-20000+i},{state:'needs_attention'});
 s.db.exec('COMMIT');
 assert.deepEqual(await s.purge(),{purged:0});
 const first=s.db.prepare('SELECT candidate_count,cursor_at,cursor_job FROM rag_pdf_purge_control').get();
 assert.equal(first.candidate_count,10);assert.equal(first.cursor_at,BASE-HOLD-19991);
 assert.deepEqual(await s.purge(),{purged:0});
 assert.equal(s.db.prepare('SELECT cursor_at FROM rag_pdf_purge_control').get().cursor_at,BASE-HOLD-19981);
 const small=setup();for(let i=0;i<10;i++)small.seed({settled_at:BASE-HOLD-100+i},{state:'pending'});
 const ready=small.seed({settled_at:BASE-HOLD});
 assert.deepEqual(await small.purge(),{purged:0});assert.deepEqual(await small.purge(),{purged:1});assert.equal(small.job(ready.job_id),undefined);
 await small.purge();assert.equal(small.db.prepare('SELECT cursor_job FROM rag_pdf_purge_control').get().cursor_job,'');
});

test('subsecond lease cannot authorize a late delete in the same DB second',async()=>{
 const s=setup(),j=s.seed();s.setTime(BASE+100);
 // Millisecond caller/lease ends at +125ms; DB remains in the same second.
 await reject(()=>s.purge({timeoutMs:25}),'pdf_purge_unavailable');assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
});

test('allowed positive caller skew cannot extend the initial database lease',async()=>{
 const s=setup(),j=s.seed(),batch=s.env.ADMIN_DB.batch.bind(s.env.ADMIN_DB);
 s.env.ADMIN_DB.batch=async statements=>{s.setTime(BASE+10000);return batch(statements);};
 await reject(()=>s.purge({clock:()=>BASE+5000}),'pdf_purge_unavailable');assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
});

test('parent failure rolls back child deletion, floor, writer fence and clock in one transaction',async()=>{
 const s=setup(),j=s.seed({},{});
 s.db.exec("CREATE TRIGGER synthetic_parent_failure AFTER DELETE ON rag_pdf_jobs BEGIN SELECT RAISE(ABORT,'synthetic failure'); END");
 await reject(()=>s.purge(),'pdf_purge_unavailable');
 assert.ok(s.job(j.job_id));assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,1);
 assert.equal(s.floor(),0);const c=s.db.prepare('SELECT * FROM rag_pdf_purge_control').get();
 assert.equal(c.writer_fenced,0);assert.equal(c.lease_id,null);assert.equal(c.requested_at,null);
});

test('child delete failure and final lease release failure also roll back all changes',async()=>{
 for(const sql of ["CREATE TRIGGER synthetic_child_failure BEFORE DELETE ON rag_pdf_job_recovery BEGIN SELECT RAISE(ABORT,'fail'); END",
  "CREATE TRIGGER synthetic_release_failure BEFORE UPDATE OF lease_id ON rag_pdf_purge_control WHEN OLD.lease_id IS NOT NULL AND NEW.lease_id IS NULL BEGIN SELECT RAISE(ABORT,'fail'); END"]){
  const s=setup(),j=s.seed({},{});s.db.exec(sql);await reject(()=>s.purge(),'pdf_purge_unavailable');
  assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
  assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,1);
 }
});

test('same-pass earlier deletions roll back if a later candidate fails',async()=>{
 const s=setup(),a=s.seed(),b=s.seed();
 s.db.exec(`CREATE TRIGGER synthetic_second_failure AFTER DELETE ON rag_pdf_jobs WHEN OLD.job_id='${b.job_id}' BEGIN SELECT RAISE(ABORT,'fail'); END`);
 await reject(()=>s.purge(),'pdf_purge_unavailable');assert.ok(s.job(a.job_id));assert.ok(s.job(b.job_id));assert.equal(s.floor(),0);
});

test('recovery lease acquired just before delete is rechecked and holds job',async()=>{
 const s=setup(),j=s.seed({},{}),batch=s.env.ADMIN_DB.batch.bind(s.env.ADMIN_DB);
 s.env.ADMIN_DB.batch=async statements=>{
  s.db.prepare('UPDATE rag_pdf_job_recovery SET lease_id=?,lease_until=?').run(crypto.randomUUID(),BASE+1000);
  return batch(statements);
 };
 assert.deepEqual(await s.purge(),{purged:0});assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
});

test('limits deletion to ten jobs and diagnostics contain only a count',async()=>{
 const s=setup();for(let i=0;i<12;i++)s.seed();
 assert.deepEqual(await s.purge(),{purged:10});assert.deepEqual(await s.purge(),{purged:2});
});

test('clock backward, jump over a day or caller/database skew deny mutation',async()=>{
 for(const options of [{dbTime:BASE-1000},{dbTime:BASE+DAY+1000},{clock:()=>BASE+6000}]){
  const s=setup(),j=s.seed();if(options.dbTime!==undefined)s.setTime(options.dbTime);
  await reject(()=>s.purge(options.clock?{clock:options.clock}:{}),'pdf_purge_unavailable');assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);
 }
});

test('default disabled/strict inputs/direct parent DELETE are closed',async()=>{
 const disabled=setup({enabled:false});await reject(()=>disabled.purge(),'pdf_purge_disabled');
 const s=setup(),j=s.seed();s.env.RAG_PDF_JOB_PURGE_ENABLED='false';await reject(()=>s.purge(),'pdf_purge_disabled');s.env.RAG_PDF_JOB_PURGE_ENABLED='true';
 for(const options of [{limit:0},{limit:11},{timeoutMs:10001},{clock:()=>NaN},{clock:null}])await reject(()=>s.purge(options),'invalid_pdf_purge_options');
 assert.throws(()=>s.db.prepare('DELETE FROM rag_pdf_jobs WHERE job_id=?').run(j.job_id),/pdf_job_purge_not_authorized/u);
});

test('aggregate enabled diagnostic respects both required runtime flags',async()=>{
 const s=setup();assert.equal((await rawPDFRetentionStatus(s.env,s.options)).physicalPurgeEnabled,true);
 for(const flag of ['RAG_PDF_RETENTION_ENABLED','RAG_PDF_JOB_PURGE_ENABLED']){
  s.env[flag]='false';assert.equal((await rawPDFRetentionStatus(s.env,s.options)).physicalPurgeEnabled,false);
  await reject(()=>s.purge(),'pdf_purge_disabled');s.env[flag]='true';
 }
});

test('writer fence survives disabling purge; floor and identity cannot be rolled back',async()=>{
 const s=setup(),j=s.seed();await s.purge();s.db.exec('UPDATE rag_pdf_purge_control SET enabled=0');
 assert.throws(()=>s.db.exec('UPDATE rag_pdf_purge_control SET writer_fenced=0'));
 assert.throws(()=>s.db.exec("INSERT OR REPLACE INTO rag_pdf_purge_control(singleton,last_clock_at) VALUES(1,0)"));
 assert.throws(()=>s.db.exec('DELETE FROM rag_pdf_purge_control'));
 assert.throws(()=>s.db.exec('UPDATE rag_pdf_retention_control SET min_admission_window=0'));
 const next=s.seed({window_start:BASE});
 assert.throws(()=>s.db.prepare('UPDATE rag_pdf_jobs SET window_start=0 WHERE job_id=?').run(next.job_id));
 assert.throws(()=>s.seed({writer_version:'legacy',window_start:BASE}),/pdf_job_writer_upgrade_required/u);
 assert.throws(()=>s.seed({window_start:j.window_start}),/pdf_job_admission_window_closed/u);
});

test('current new writer reserves after the permanent fence',async()=>{
 const s=setup();await s.purge();
 const session={sub:'synthetic-new-writer'},key=await accountKey(session.sub);
 s.env.AI_PROVIDER_APPROVED=s.env.RAG_AUTO_INDEX_ENABLED=s.env.RAG_PDF_PROCESSING_ENABLED='true';
 await updateConsent(s.env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(s.env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const p=await prepareRawPDFIntake(s.env,session,{documentId:'new-writer-document',requestId:'new-writer-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1},s.options);
 const policy={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
  reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
 const j=await reserveRawPDFJob(s.env,session,p,policy,s.options);assert.equal(s.job(j.jobId).writer_version,'floor-v2');
});

test('current-day accounting and unsettled memory remain unchanged while expired details disappear',async()=>{
 const s=setup();s.seed();s.seed({window_start:BASE});s.seed({state:'stop_requested',settled_units:null,token_hash:'a'.repeat(64)});
 const snapshot=()=>s.db.prepare(`SELECT
 (SELECT COUNT(*) FROM rag_pdf_jobs WHERE window_start=?) AS requests,
 (SELECT SUM(COALESCE(settled_units,reserved_units)) FROM rag_pdf_jobs WHERE window_start=?) AS units,
 (SELECT SUM(memory_weight) FROM rag_pdf_jobs WHERE state!='settled') AS memory`).get(BASE,BASE);
 const before=snapshot();assert.equal((await s.purge()).purged,1);assert.deepEqual(snapshot(),before);
});

test('late batch after timeout cannot delete with an expired lease',async()=>{
 const s=setup(),j=s.seed(),batch=s.env.ADMIN_DB.batch.bind(s.env.ADMIN_DB);let release,entered;
 const wait=new Promise(r=>{release=r;}),ready=new Promise(r=>{entered=r;});
 s.env.ADMIN_DB.batch=async statements=>{entered();await wait;return batch(statements);};
 const p=s.purge({timeoutMs:25}),rejected=reject(()=>p,'pdf_purge_timeout');await ready;await rejected;
 s.setTime(BASE+1000);release();await new Promise(r=>setTimeout(r,10));
 assert.ok(s.job(j.job_id));assert.equal(s.floor(),0);assert.equal(s.db.prepare('SELECT lease_id FROM rag_pdf_purge_control').get().lease_id,null);
});
