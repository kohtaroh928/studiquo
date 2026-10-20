import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {sha256Hex} from './auth.js';
import {canonicalJSON} from './rag/structured-input.js';
import {qualityEnvironment} from './rag-quality-fixture.js';
import {accountKey} from './rag/storage.js';
import {updateConsent} from './rag/control.js';
import {updateRawPDFConsent} from './rag/pdf-authorization.js';
import {prepareRawPDFIntake} from './rag/pdf-intake.js';
import {requestRawPDFJobStop} from './rag/pdf-jobs.js';
import {processRawPDF} from './rag/pdf-process.js';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from './rag/pdf-stop-evidence.js';
import {reserveRawPDFJob} from './rag/pdf-jobs.js';
import {recoverRawPDFJobs} from './rag/pdf-job-recovery.js';
import {purgeSettledRawPDFJobs} from './rag/pdf-purge.js';
import {rawPDFRetentionStatus} from './rag/pdf-retention.js';
import {validateRawPDFManifest} from './rag/pdf-manifest.js';
const session={sub:'synthetic-process-owner'},bytes=new TextEncoder().encode('%PDF-synthetic');
const limits={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:10,globalDailyUnits:10,reservationUnits:1,perOwnerDailyRequests:10,globalDailyRequests:10};
const options={pollMs:5,workMs:2000,cleanupMs:150};
function request(body=bytes,signal){return new Request('https://example.test/internal',{method:'POST',duplex:'half',body,signal,
 headers:{'Content-Type':'application/pdf','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1','X-Studiquo-Raw-PDF-Consent':'raw-pdf-docling-v1'}});}
async function setup({lastMigration=true}={}){
 const e=qualityEnvironment();e.RAG_PDF_STOP_EVIDENCE_ENABLED='true';e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const p of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql','0014_rag_pdf_retention.sql','0015_rag_pdf_purge.sql','0016_rag_pdf_stop_evidence.sql',...(lastMigration?['0017_rag_pdf_evidence_retention.sql']:[])])e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${p}`,import.meta.url),'utf8'));
 const key=await accountKey(session.sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const pdfSha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const proof=await prepareRawPDFIntake(e,session,{documentId:'new-doc',requestId:'request-a',expectedGeneration:0,pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1});
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256})),text='Synthetic paragraph.';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:null,charspan:[0,text.length]}],coordinateState:'unknown',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:text.length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 const manifest={version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,document,documentNamespace},totalPages:1,pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]}]};
 // Actual D1 batch includes RETURNING results; fixture must preserve them too.
 const db=e.ADMIN_DB.db;e.ADMIN_DB.prepare=sql=>({bind(...args){const get=()=>db.prepare(sql);return {
  first:async()=>get().get(...args)??null,all:async()=>({results:get().all(...args)}),
  run:async()=>{const st=get();return st.columns().length?{results:st.all(...args)}:{results:[],meta:{changes:Number(st.run(...args).changes)}};}
 };}});
 const calls=[];e.DOCLING_PROCESSOR={async parse(id,pdf){calls.push('parse');assert.deepEqual(pdf,bytes);return manifest;},async cancel(){calls.push('cancel');return {cancelled:true};}};
 return {e,proof,manifest,calls,key};
}
const run=(s,req=request(),opts=options)=>processRawPDF(s.e,session,s.proof,req,limits,{consumeResult:async value=>{assert.deepEqual(value,s.manifest);s.consumed=(s.consumed??0)+1;},...opts});
const job=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').get();
async function failed(result){assert.ok(result instanceof Response);assert.deepEqual(await result.json(),{error:'pdf_processing_failed'});}

const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const evidence=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_execution_evidence').get();
const recover=s=>recoverRawPDFJobs(s.e,{timeoutMs:40});

test('new processor success stores both bound proofs and settles only after strict remote cancel',async()=>{
 const s=await setup();const result=await run(s);
 assert.equal(result.consumed,true);assert.deepEqual(s.calls,['parse','cancel']);
 assert.equal(job(s).claim_protocol,'stop-proof-v1');assert.equal(job(s).state,'settled');
 assert.ok(evidence(s).local_stopped_at);assert.ok(evidence(s).remote_stopped_at);
 assert.equal(evidence(s).claim_hash,job(s).token_hash);assert.equal(job(s).settled_units,1);
});

test('consumer and underlying parse pending cannot create local proof or free a slot',async()=>{
 for(const stage of ['parse','consumer']){
  const s=await setup(),entered=deferred(),finish=deferred();
  const opts={...options,workMs:100,cleanupMs:25};
  if(stage==='parse')s.e.DOCLING_PROCESSOR.parse=async()=>{entered.resolve();await finish.promise;return s.manifest;};
  else opts.consumeResult=async()=>{entered.resolve();await finish.promise;};
  const active=run(s,request(),opts);await entered.promise;await failed(await active);
  assert.equal(job(s).settled_units,null);assert.equal(evidence(s).local_stopped_at,null);
  await recover(s);assert.equal(job(s).settled_units,null);
  finish.resolve();await new Promise(r=>setTimeout(r,20));
  assert.equal(evidence(s).local_stopped_at,null);assert.equal(job(s).settled_units,null);
 }
});

test('failed digest is local-only proof, never dispatches, and settles zero',async()=>{
 const s=await setup(),b=bytes.slice();b[b.length-1]^=1;
 await failed(await run(s,request(b)));assert.deepEqual(s.calls,[]);
 assert.equal(job(s).settled_units,0);assert.equal(evidence(s).remote_kind,'not_dispatched');
});

test('unresolved reader cancellation remains held even when cancel is acknowledged',async()=>{
 const s=await setup(),controller=new AbortController(),finish=deferred();
 const body=new ReadableStream({pull(){controller.abort();return new Promise(()=>{});},cancel(){return finish.promise;}},{highWaterMark:0});
 await failed(await run(s,request(body,controller.signal),{...options,cleanupMs:25}));
 assert.equal(evidence(s).local_stopped_at,null);assert.equal(job(s).settled_units,null);
 finish.resolve();await new Promise(r=>setTimeout(r,20));await recover(s);
 assert.equal(evidence(s).local_stopped_at,null);assert.equal(job(s).settled_units,null);
});

test('success with failed remote ack retains local proof; reaper later records remote proof and settles without token',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.cancel=async()=>({cancelled:false});
 await failed(await run(s));assert.ok(evidence(s).local_stopped_at);assert.equal(evidence(s).remote_stopped_at,null);
 assert.equal(job(s).settled_units,null);s.e.DOCLING_PROCESSOR.cancel=async()=>({cancelled:true});
 await recover(s);assert.equal(job(s).settled_units,1);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_job_recovery').get().state,'done');
 const time=job(s).settled_at;await recover(s);assert.equal(job(s).settled_at,time);
});

test('lost settlement response is safe and final reaper clears the recovery journal',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.batch.bind(s.e.ADMIN_DB);let thrown=false;
 s.e.ADMIN_DB.batch=async statements=>{const result=await base(statements);
  if(job(s)?.state==='settled'&&!thrown){thrown=true;throw Error('synthetic lost commit ack');}return result;};
 await failed(await run(s));assert.equal(job(s).state,'settled');assert.ok(evidence(s).local_stopped_at);
 await recover(s);assert.equal(job(s).settled_units,1);
});

test('flag true without evidence schema rejects before body read, with no legacy fallback',async()=>{
 const s=await setup();s.e.ADMIN_DB.db.exec('DROP TABLE rag_pdf_execution_evidence');let read=false;
 await failed(await run(s,{headers:request().headers,signal:new AbortController().signal,get body(){read=true;throw Error('must not read');}}));
 assert.equal(read,false);assert.equal(job(s).token_hash,null);
});

test('proof-complete jobs recover even after flags off and attempts exhausted, but never with a live recovery lease',async()=>{
 const s=await setup();const j=await reserveRawPDFJob(s.e,session,s.proof,limits);
 const scope=await beginRawPDFStopEvidence(s.e,session,s.proof,j.jobId);await scope.sealAndRecord();
 const db=s.e.ADMIN_DB.db;db.prepare("INSERT INTO rag_pdf_job_recovery(job_id,state,attempts,lease_id,lease_until) VALUES(?,'needs_attention',3,'synthetic-lease',?)").run(j.jobId,Date.now()+30000);
 s.e.RAG_PDF_STOP_EVIDENCE_ENABLED=s.e.RAG_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED='false';
 await recover(s);assert.equal(job(s).settled_units,null);
 db.exec('UPDATE rag_pdf_job_recovery SET lease_id=NULL,lease_until=0');await recover(s);
 assert.equal(job(s).state,'settled');assert.equal(job(s).settled_units,0);
});

async function readyForPurge(){
 const s=await setup();await run(s);const db=s.e.ADMIN_DB.db;
 const future=job(s).settled_at+172800000+3000;
 db.function('strftime',(_f,_at)=>String(Math.floor(future/1000)));
 // Reviewed synthetic clock anchor for the test only, never an operator endpoint.
 db.prepare('UPDATE rag_pdf_purge_control SET enabled=1,last_clock_at=?').run(Math.floor(future/1000)*1000);
 db.exec("UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL");
 db.prepare("INSERT INTO rag_pdf_job_recovery(job_id,state) VALUES(?,'done')").run(job(s).job_id);
 s.e.RAG_PDF_RETENTION_ENABLED=s.e.RAG_PDF_JOB_PURGE_ENABLED='true';
 s.purge=()=>purgeSettledRawPDFJobs(s.e,{clock:()=>future});return s;
}

test('v2 purge removes evidence/recovery/parent atomically and preserves the intake/floor',async()=>{
 const s=await readyForPurge(),row=job(s),db=s.e.ADMIN_DB.db;
 assert.equal((await rawPDFRetentionStatus(s.e)).physicalPurgeEnabled,true);
 assert.deepEqual(await s.purge(),{purged:1});assert.equal(job(s),undefined);assert.equal(evidence(s),undefined);
 assert.equal(db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_job_recovery').get().n,0);
 assert.equal(db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,1);
 assert.equal(db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').get().n,row.window_start+86400000);
 assert.equal(db.prepare('SELECT purging_job FROM rag_pdf_purge_control').get().purging_job,null);
});

test('evidence cannot be directly deleted even in an active purge lease without parent context',async()=>{
 const s=await readyForPurge(),db=s.e.ADMIN_DB.db;
 const n=Number(db.prepare("SELECT strftime('%s','now') AS n").get().n)*1000;
 db.prepare('UPDATE rag_pdf_purge_control SET requested_at=?,last_clock_at=?,writer_fenced=1,lease_id=?,lease_until=?').run(n,n,crypto.randomUUID(),n+10000);
 assert.throws(()=>db.exec('DELETE FROM rag_pdf_execution_evidence'),/pdf_stop_evidence_retention_required/u);
 assert.ok(evidence(s));assert.ok(job(s));
 // A caller with SQL access can mimic the context UPDATE, but cannot make the
 // FK parent absent without running its guarded deletion and cascade.
 db.prepare('UPDATE rag_pdf_purge_control SET purging_job=?').run(job(s).job_id);
 assert.throws(()=>db.exec('DELETE FROM rag_pdf_execution_evidence'),/pdf_stop_evidence_retention_required/u);
 assert.ok(evidence(s));assert.ok(job(s));
});

test('failure after evidence or recovery or parent deletion rolls back all children, floor, cursor and context',async()=>{
 for(const target of ['rag_pdf_execution_evidence','rag_pdf_job_recovery','rag_pdf_jobs']){
  const s=await readyForPurge(),db=s.e.ADMIN_DB.db;
  db.exec(`CREATE TRIGGER synthetic_failure AFTER DELETE ON ${target} BEGIN SELECT RAISE(ABORT,'synthetic'); END;`);
  await assert.rejects(()=>s.purge(),/pdf_purge_unavailable/u);
  assert.ok(job(s));assert.ok(evidence(s));assert.ok(db.prepare('SELECT * FROM rag_pdf_job_recovery').get());
  assert.equal(db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').get().n,0);
  const control=db.prepare('SELECT * FROM rag_pdf_purge_control').get();
  assert.equal(control.lease_id,null);assert.equal(control.purging_job,null);assert.equal(control.cursor_at,0);
 }
});

test('new contract still refuses future receipts/unknown PDF tables and invalid proof times',async()=>{
 for(const mode of ['receipt','unknown','proof_after_settled']){
  const s=await readyForPurge(),db=s.e.ADMIN_DB.db;
  if(mode==='receipt')db.exec('CREATE TABLE synthetic_receipts(id TEXT)');
  else if(mode==='unknown')db.exec('CREATE TABLE rag_pdf_future(id TEXT)');
  else db.exec('UPDATE rag_pdf_jobs SET settled_at=local_stopped_at-1 FROM rag_pdf_execution_evidence WHERE rag_pdf_jobs.job_id=rag_pdf_execution_evidence.job_id');
  if(mode==='proof_after_settled')assert.deepEqual(await s.purge(),{purged:0});
  else await assert.rejects(()=>s.purge(),/pdf_purge_unavailable/u);
  assert.ok(evidence(s));assert.ok(job(s));
 }
});

test('a lease acquired after evidence selection is rechecked at settlement, never releasing the slot',async()=>{
 const s=await setup(),j=await reserveRawPDFJob(s.e,session,s.proof,limits);
 const scope=await beginRawPDFStopEvidence(s.e,session,s.proof,j.jobId);await scope.sealAndRecord();
 const base=s.e.ADMIN_DB.prepare;let injected=false;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);
  if(sql.includes("UPDATE rag_pdf_jobs SET state='settled'")){
   const run=b.run;b.run=async()=>{
    if(!injected){injected=true;s.e.ADMIN_DB.db.prepare("INSERT INTO rag_pdf_job_recovery(job_id,state,lease_id,lease_until) VALUES(?,'pending','synthetic-other-pass',?)").run(j.jobId,Date.now()+30000);}
    return run();
   };
  }return b;
 }};};
 await recover(s);assert.equal(injected,true);assert.equal(job(s).settled_units,null);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT lease_id FROM rag_pdf_job_recovery').get().lease_id,'synthetic-other-pass');
});

test('0017 preserves populated proof rows and job identity while disabling the prior purge opt-in',async()=>{
 const s=await setup({lastMigration:false});assert.equal((await run(s)).consumed,true);
 const db=s.e.ADMIN_DB.db,beforeProof=evidence(s),beforeJob=job(s);
 db.exec('UPDATE rag_pdf_purge_control SET enabled=1,writer_fenced=1');
 db.exec(readFileSync(new URL('../migrations/0017_rag_pdf_evidence_retention.sql',import.meta.url),'utf8'));
 assert.deepEqual(evidence(s),beforeProof);assert.deepEqual(job(s),beforeJob);
 const control=db.prepare('SELECT * FROM rag_pdf_purge_control').get();
 assert.equal(control.enabled,0);assert.equal(control.writer_fenced,1);assert.equal(control.contract_version,'pre-adoption-stop-v2');
 assert.throws(()=>db.exec('UPDATE rag_pdf_execution_evidence SET local_stopped_at=NULL'),/pdf_stop_evidence_not_authorized/u);
 assert.throws(()=>db.exec('DELETE FROM rag_pdf_execution_evidence'),/pdf_stop_evidence_retention_required/u);
 assert.ok(db.prepare('PRAGMA foreign_key_list(rag_pdf_execution_evidence)').all().some(k=>k.on_delete==='CASCADE'));
});

test('missing v2 context clear trigger closes purge before any partial delete can commit',async()=>{
 const s=await readyForPurge(),db=s.e.ADMIN_DB.db;
 db.exec('DROP TRIGGER rag_pdf_purge_context_clear');
 await assert.rejects(()=>s.purge(),/pdf_purge_upgrade_required/u);
 assert.equal((await rawPDFRetentionStatus(s.e)).physicalPurgeEnabled,false);
 assert.ok(evidence(s));assert.ok(job(s));
 assert.equal(db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').get().n,0);
});
