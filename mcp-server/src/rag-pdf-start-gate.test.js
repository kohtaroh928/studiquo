import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.js';
import {accountKey} from './rag/storage.js';
import {updateConsent} from './rag/control.js';
import {updateRawPDFConsent} from './rag/pdf-authorization.js';
import {prepareRawPDFIntake,cancelRawPDFIntake} from './rag/pdf-intake.js';
import {reserveRawPDFJob,markRawPDFJobDispatchedV2,markRawPDFJobDispatchedWithStartProtocol,requestRawPDFJobStop} from './rag/pdf-jobs.js';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from './rag/pdf-stop-evidence.js';
import {claimRawPDFStart} from './rag/pdf-start-gate.js';
import {purgeSettledRawPDFJobs} from './rag/pdf-purge.js';
import {cleanupAccountRawPDF} from './rag/pdf-account-cleanup.js';
const session={sub:'synthetic-start-owner'},limits={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:20,globalDailyUnits:20,reservationUnits:1,perOwnerDailyRequests:20,globalDailyRequests:20};
const names=['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql','0014_rag_pdf_retention.sql','0015_rag_pdf_purge.sql','0016_rag_pdf_stop_evidence.sql','0017_rag_pdf_evidence_retention.sql','0018_rag_pdf_rpc_v2.sql'];
const row=s=>s.db.prepare('SELECT * FROM rag_pdf_jobs WHERE job_id=?').get(s.contract.jobId);
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
async function waitPhase(p){let timer;try{return await Promise.race([p,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('synthetic phase not reached')),1500);})]);}finally{clearTimeout(timer);}}
async function setup({newSchema=true,oneShot=true}={}){
 const e=qualityEnvironment(),db=e.ADMIN_DB.db;let n=Date.now();const options={clock:()=>n};
 for(const name of [...names,...(newSchema?['0019_rag_pdf_start_gate.sql']:[])])db.exec(readFileSync(new URL(`../migrations/${name}`,import.meta.url),'utf8'));
 e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED=e.RAG_PDF_START_GATE_ENABLED=e.RAG_PDF_STOP_EVIDENCE_ENABLED=e.RAG_PDF_RPC_V2_ENABLED='true';
 e.DOCLING_PROCESSOR={cancelV2:async()=>({cancelled:true})};
 e.ADMIN_DB.prepare=sql=>({bind(...args){const st=()=>db.prepare(sql);return {first:async()=>st().get(...args)??null,all:async()=>({results:st().all(...args)}),run:async()=>st().columns().length?{results:st().all(...args)}:{results:[],meta:{changes:Number(st().run(...args).changes)}}};}});
 const key=await accountKey(session.sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const prepare=async(documentId,protocol=true)=>{
  const proof=await prepareRawPDFIntake(e,session,{documentId,requestId:`req-${documentId}`,expectedGeneration:0,pdfSha256:'a'.repeat(64),byteLength:20,consentEpoch:1,rawPDFConsentEpoch:1},options);
  const j=await reserveRawPDFJob(e,session,proof,limits,options),scope=await beginRawPDFStopEvidence(e,session,proof,j.jobId,options);
  const contract=await (protocol?markRawPDFJobDispatchedWithStartProtocol:markRawPDFJobDispatchedV2)(e,session,proof,j.jobId,scope.executionToken,options);
  return {proof,scope,contract};
 };
 const ready=await prepare('doc-a',oneShot);
 return {e,db,key,options,prepare,...ready,setTime:v=>{n=v;}};
}
const claim=(s,id=crypto.randomUUID(),more={})=>claimRawPDFStart(s.e,s.contract,id,{...s.options,...more});
async function settle(s){await s.scope.sealAndRecord(s.options);await confirmRawPDFRemoteStop(s.e,s.contract.jobId,s.options);await settleRawPDFJobFromEvidence(s.e,s.contract.jobId,s.options);}

test('dedicated dispatch fixes independent protocol; one winning start is immutable and never regranted',async()=>{
 const s=await setup(),id=crypto.randomUUID(),before=row(s);assert.equal(before.start_protocol,'one-shot-v1');assert.equal(before.start_claim_id,null);
 assert.deepEqual(await claim(s,id),{granted:true,startClaimId:id});assert.equal(row(s).start_claim_id,id);
 assert.ok(Number.isSafeInteger(row(s).start_claimed_at));assert.equal(row(s).state,'dispatched');assert.equal(row(s).settled_units,null);
 await assert.rejects(()=>claim(s,id),/pdf_start_denied/u);await assert.rejects(()=>claim(s),/pdf_start_denied/u);
 for(const sql of ["start_claim_id=NULL,start_claimed_at=NULL","start_claimed_at=start_claimed_at+1","start_protocol='legacy'","start_claim_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'"])
  assert.throws(()=>s.db.exec(`UPDATE rag_pdf_jobs SET ${sql}`),/pdf_start_immutable/u);
});

test('two concurrent callers and a replicated nonce return only one permission',async()=>{
 for(const duplicate of [false,true]){const s=await setup(),id=crypto.randomUUID();const replies=await Promise.allSettled([claim(s,id),claim(s,duplicate?id:crypto.randomUUID())]);
  assert.equal(replies.filter(x=>x.status==='fulfilled').length,1);assert.equal(row(s).start_claim_id,id);}
});

test('legacy rows survive migration unchanged and cannot be upgraded after dispatch or treated as unused',async()=>{
 const s=await setup({newSchema:false,oneShot:false}),before=row(s);
 s.db.exec(readFileSync(new URL('../migrations/0019_rag_pdf_start_gate.sql',import.meta.url),'utf8'));
 for(const k of Object.keys(before))assert.deepEqual(row(s)[k],before[k]);assert.equal(row(s).start_protocol,'legacy');
 await assert.rejects(()=>claim(s),/pdf_start_denied/u);
 assert.throws(()=>s.db.exec("UPDATE rag_pdf_jobs SET start_protocol='one-shot-v1'"),/pdf_start_invalid/u);
 assert.throws(()=>s.db.exec("UPDATE rag_pdf_jobs SET start_claim_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',start_claimed_at=1"),/pdf_start_invalid/u);
});

test('invalid envelopes, extra fields, bad nonce and options never consume permission',async()=>{
 const s=await setup();for(const value of [null,{}, {...s.contract,version:1},{...s.contract,extra:true},{...s.contract,notAfter:'1'},{...s.contract,pdfSha256:'b'.repeat(64)},{...s.contract,jobId:crypto.randomUUID()}])
  await assert.rejects(()=>claimRawPDFStart(s.e,value,crypto.randomUUID(),s.options));
 for(const id of [null,'bad','bbbbbbbb-bbbb-4bbb-7bbb-bbbbbbbbbbbb'])await assert.rejects(()=>claim(s,id),/invalid_pdf_start/u);
 for(const more of [{timeoutMs:0},{timeoutMs:2001},{clock:()=>NaN},{clock:()=>-1}])await assert.rejects(()=>claim(s,crypto.randomUUID(),more));
 assert.equal(row(s).start_claim_id,null);
});

test('each acceptance and dedicated flag off, missing or wrong type denies before DB reads and cleanup stays available',async()=>{
 const flags=['AI_PROVIDER_APPROVED','RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED','RAG_PDF_START_GATE_ENABLED'];
 for(const name of flags)for(const value of ['false',undefined,true]){const s=await setup(),base=s.e.ADMIN_DB.prepare;let reads=0;
  s.e[name]=value;s.e.ADMIN_DB.prepare=sql=>{reads++;return base(sql);};await assert.rejects(()=>claim(s),/pdf_start_disabled/u);assert.equal(reads,0);assert.equal(row(s).start_claim_id,null);
  await requestRawPDFJobStop(s.e,session,s.contract.jobId);assert.equal(row(s).state,'stop_requested');}
});

test('flag shutdown during schema await prevents CAS; shutdown after commit discards grant but keeps consumption',async()=>{
 for(const phase of ['schema','after_commit']){const s=await setup(),base=s.e.ADMIN_DB.prepare;
  s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);
   if(phase==='schema'&&sql.startsWith('PRAGMA')){const all=b.all;b.all=async()=>{const r=await all();s.e.RAG_PDF_START_GATE_ENABLED='false';return r;};}
   if(phase==='after_commit'&&sql.includes('SET start_claim_id=')){const all=b.all;b.all=async()=>{const r=await all();s.e.RAG_PDF_PROCESSING_ENABLED='false';return r;};}return b;}};};
  await assert.rejects(()=>claim(s),/pdf_start_disabled/u);assert.equal(row(s).start_claim_id!==null,phase==='after_commit');
 }
});

test('revocation or owner mutation before the write is rechecked atomically',async()=>{
 for(const kind of ['intake','account','rag','raw','epoch','floor']){const s=await setup(),base=s.e.ADMIN_DB.prepare;let once=false;
  s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes('SET start_claim_id=')){const all=b.all;b.all=async()=>{
   if(!once){once=true;const mutation={intake:"UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL",account:'UPDATE rag_accounts SET deleted=1',rag:'UPDATE rag_controls SET enabled=0',raw:'UPDATE rag_raw_pdf_consents SET enabled=0,rag_consent_epoch=NULL,consent_version=NULL',epoch:'UPDATE rag_controls SET epoch=epoch+1',floor:'UPDATE rag_pdf_retention_control SET min_admission_window=min_admission_window+8640000000000'}[kind];s.db.exec(mutation);}return all();};}return b;}};};
  await assert.rejects(()=>claim(s),/pdf_start_denied/u);assert.equal(row(s).start_claim_id,null);}
});

test('a different owner current intake cannot satisfy the persisted job correlation',async()=>{
 const s=await setup();s.db.exec('UPDATE rag_pdf_intakes SET account_key=\'synthetic-other-hash\'');
 await assert.rejects(()=>claim(s),/pdf_start_denied/u);assert.equal(row(s).start_claim_id,null);
});

test('both trusted capture clock expiry and actual DB execution expiry reject without permission',async()=>{
 const s=await setup();s.setTime(s.contract.notAfter);await assert.rejects(()=>claim(s),/pdf_start_denied/u);assert.equal(row(s).start_claim_id,null);
 const t=await setup();t.db.function('strftime',(_f,_at)=>String(Math.ceil(t.contract.notAfter/1000)));
 await assert.rejects(()=>claim(t),/pdf_start_denied/u);assert.equal(row(t).start_claim_id,null);
});

test('lost commit response consumes permission but retry with the same nonce is refused',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.prepare,id=crypto.randomUUID();let first=true;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes('SET start_claim_id=')){const all=b.all;b.all=async()=>{const r=await all();if(first){first=false;throw Error('synthetic secret-like DB detail');}return r;};}return b;}};};
 await assert.rejects(()=>claim(s,id),/^Error: pdf_start_unavailable$/u);assert.equal(row(s).start_claim_id,id);
 await assert.rejects(()=>claim(s,id),/pdf_start_denied/u);assert.equal(row(s).settled_units,null);
});

test('timeout is not cancellation: late commit stays consumed with no late permission',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.prepare,entered=deferred(),finish=deferred();let actual;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes('SET start_claim_id=')){const all=b.all;b.all=()=>actual=(async()=>{entered.resolve();await finish.promise;return all();})();}return b;}};};
 const pending=claim(s,crypto.randomUUID(),{timeoutMs:1000});const rejected=assert.rejects(pending,/pdf_start_timeout/u);await waitPhase(entered.promise);await rejected;
 assert.equal(row(s).start_claim_id,null);finish.resolve();await actual;await new Promise(r=>setTimeout(r,1));assert.ok(row(s).start_claim_id);
 s.e.ADMIN_DB.prepare=base;await assert.rejects(()=>claim(s),/pdf_start_denied/u);assert.equal(row(s).settled_units,null);
});

test('cancel winning before a delayed commit prevents consumption; original task may not grant later',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.prepare,entered=deferred(),finish=deferred();let actual;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes('SET start_claim_id=')){const all=b.all;b.all=()=>actual=(async()=>{entered.resolve();await finish.promise;return all();})();}return b;}};};
 const pending=claim(s,crypto.randomUUID(),{timeoutMs:1000}),rejected=assert.rejects(pending,/pdf_start_timeout/u);await waitPhase(entered.promise);await rejected;
 await requestRawPDFJobStop(s.e,session,s.contract.jobId);finish.resolve();await actual;assert.equal(row(s).start_claim_id,null);
});

test('schema absence or missing guard closes only the new helper and preserves stop/settle',async()=>{
 for(const mode of ['old','guard','floor_guard']){const s=await setup(mode==='old'?{newSchema:false,oneShot:false}:{});if(mode==='guard')s.db.exec('DROP TRIGGER rag_pdf_start_update');if(mode==='floor_guard')s.db.exec('DROP TRIGGER rag_pdf_retention_control_no_replace');
  await assert.rejects(()=>claim(s),/pdf_start_upgrade_required/u);
  await assert.rejects(()=>markRawPDFJobDispatchedWithStartProtocol(s.e,session,s.proof,s.contract.jobId,s.scope.executionToken,s.options),/pdf_start_upgrade_required/u);await settle(s);assert.equal(row(s).state,'settled');}
});

test('consumed permission survives owner cleanup; remote stop alone never resets consumption or proves VM start',async()=>{
 const s=await setup(),id=crypto.randomUUID();await claim(s,id);s.db.exec('UPDATE rag_accounts SET deleted=1');
 assert.equal((await cleanupAccountRawPDF(s.e,session.sub)).pending,true);assert.equal(row(s).start_claim_id,id);assert.equal(row(s).settled_units,null);
 await s.scope.sealAndRecord(s.options);assert.equal((await cleanupAccountRawPDF(s.e,session.sub)).pending,false);
 assert.equal(row(s).start_claim_id,id);assert.equal(row(s).state,'settled');await assert.rejects(()=>claim(s),/pdf_start_denied/u);
});

test('new protocol parent is retained while mixed legacy purge moves cursor and removes the legacy parent',async()=>{
 const s=await setup();await claim(s);await settle(s);await cancelRawPDFIntake(s.e,session,{documentId:s.proof.documentId,intakeId:s.proof.intakeId,generation:s.proof.generation});
 const legacy=await s.prepare('doc-b',false),other={...s,...legacy};await settle(other);
 s.db.prepare('UPDATE rag_pdf_jobs SET settled_at=? WHERE job_id=?').run(row(s).settled_at+1,legacy.contract.jobId);
 await cancelRawPDFIntake(s.e,session,{documentId:legacy.proof.documentId,intakeId:legacy.proof.intakeId,generation:legacy.proof.generation});
 const future=row(other).settled_at+172800000+3000;s.db.function('strftime',(_f,_at)=>String(Math.floor(future/1000)));
 s.db.prepare('UPDATE rag_pdf_purge_control SET enabled=1,last_clock_at=?').run(Math.floor(future/1000)*1000);
 s.e.RAG_PDF_RETENTION_ENABLED=s.e.RAG_PDF_JOB_PURGE_ENABLED='true';
 assert.throws(()=>s.db.prepare('DELETE FROM rag_pdf_jobs WHERE job_id=?').run(s.contract.jobId));
 assert.deepEqual(await purgeSettledRawPDFJobs(s.e,{clock:()=>future,limit:1}),{purged:0});
 assert.equal(s.db.prepare('SELECT cursor_job FROM rag_pdf_purge_control').get().cursor_job,s.contract.jobId);
 assert.deepEqual(await purgeSettledRawPDFJobs(s.e,{clock:()=>future,limit:1}),{purged:1});assert.equal(row(other),undefined);assert.ok(row(s).start_claim_id);
 await assert.rejects(()=>claim(other),/pdf_start_denied/u);
});

test('INSERT OR REPLACE cannot reset a consumed job or remove its bound evidence',async()=>{
 const s=await setup();await claim(s);const before=row(s);
 const columns=Object.keys(before),values=columns.map(k=>k==='start_protocol'?'legacy':['start_claim_id','start_claimed_at'].includes(k)?null:before[k]);
 assert.throws(()=>s.db.prepare(`INSERT OR REPLACE INTO rag_pdf_jobs(${columns.join(',')}) VALUES(${columns.map(()=>'?').join(',')})`).run(...values));
 assert.deepEqual(row(s),before);assert.ok(s.db.prepare('SELECT * FROM rag_pdf_execution_evidence WHERE job_id=?').get(s.contract.jobId));
});

test('the fixed input envelope is snapshotted before any schema await',async()=>{
 const s=await setup(),p={...s.contract},id=crypto.randomUUID();const pending=claimRawPDFStart(s.e,p,id,s.options);
 p.notAfter=1;p.pdfSha256='b'.repeat(64);assert.equal((await pending).startClaimId,id);assert.equal(row(s).rpc_not_after,s.contract.notAfter);
});

test('a schema timeout cannot go on to submit a CAS after its underlying schema read finishes',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.prepare,entered=deferred(),finish=deferred();let writes=0,actual;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.startsWith('PRAGMA')){const all=b.all;b.all=()=>actual=(async()=>{entered.resolve();await finish.promise;return all();})();}
  if(sql.includes('SET start_claim_id='))writes++;return b;}};};
 const pending=claim(s,crypto.randomUUID(),{timeoutMs:1000}),rejected=assert.rejects(pending,/pdf_start_timeout/u);await waitPhase(entered.promise);await rejected;
 finish.resolve();await actual;await new Promise(r=>setTimeout(r,1));assert.equal(writes,0);assert.equal(row(s).start_claim_id,null);
});
