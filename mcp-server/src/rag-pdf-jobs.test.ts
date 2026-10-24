// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake,cancelRawPDFIntake} from './rag/pdf-intake.ts';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched,requestRawPDFJobStop,
 requestExpiredRawPDFJobsStop,closeUnclaimedRawPDFJob,settleRawPDFJob} from './rag/pdf-jobs.ts';
const user={sub:'synthetic-job-owner'},other={sub:'synthetic-job-other'};
const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,
 perOwnerDailyUnits:10,globalDailyUnits:20,reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
const reject=(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.message,code);return true;});
async function setup({jobs=true}={}){
 const e=qualityEnvironment();e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const path of ['0024_rag_raw_pdf_consent.sql','0025_rag_pdf_intakes.sql',...(jobs?['0026_rag_pdf_jobs.sql']:[])])
  e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${path}`,import.meta.url),'utf8'));
 let time=1000000;const options={clock:()=>time};
 async function intake(documentId,session=user,more={}){
  const key=await accountKey(session.sub);
  if(!e.ADMIN_DB.db.prepare('SELECT 1 FROM rag_controls WHERE account_key=?').get(key)){
   await updateConsent(e,key,{enabled:true,expectedEpoch:0});
   await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
  }
  return prepareRawPDFIntake(e,session,{documentId,requestId:`request-${documentId}`,expectedGeneration:0,
   pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1,...more},options);
 }
 return {e,options,intake,setTime:n=>{time=n;}};
}
const reserve=(s,p,policy=limits,session=user)=>reserveRawPDFJob(s.e,session,p,policy,s.options);
const claim=(s,p,j,session=user)=>claimRawPDFJob(s.e,session,p,j.jobId,s.options);
const dispatch=(s,p,j,t)=>markRawPDFJobDispatched(s.e,user,p,j.jobId,t.executionToken,s.options);

test('reservation is idempotent, snapshots accounting, never exposes execution token',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),a=await reserve(s,p);s.setTime(1001000);
 assert.deepEqual(await reserve(s,p),a);assert.equal(a.reservedUnits,3);assert.equal(a.memoryWeight,67108864);
 assert.equal(a.state,'reserved');assert.equal(a.executionToken,undefined);assert.equal(a.token_hash,undefined);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_jobs').get().n,1);
});

test('receive claim and dispatch each have one winner, tokens never reissued on retry',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p);
 const contenders=await Promise.allSettled([claim(s,p,j),claim(s,p,j)]);
 assert.equal(contenders.filter(r=>r.status==='fulfilled').length,1);
 const t=contenders.find(r=>r.status==='fulfilled').value;
 const stored=s.e.ADMIN_DB.db.prepare('SELECT token_hash FROM rag_pdf_jobs').get().token_hash;
 assert.notEqual(stored,t.executionToken);assert.equal(stored.length,64);
 const results=await Promise.allSettled([dispatch(s,p,j,t),dispatch(s,p,j,t)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 await reject(()=>claim(s,p,j),'pdf_job_claim_conflict');
 assert.equal((await reserve(s,p)).executionToken,undefined);
});

test('parallel reservations for different intakes cannot exceed a global memory/slot budget',async()=>{
 const s=await setup(),a=await s.intake('doc-a'),b=await s.intake('doc-b',other);
 const results=await Promise.allSettled([reserve(s,a),reserve(s,b,limits,other)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.equal(results.find(r=>r.status==='rejected').reason.message,'pdf_job_admission_denied');
 const total=s.e.ADMIN_DB.db.prepare("SELECT SUM(memory_weight) AS n FROM rag_pdf_jobs WHERE state!='settled'").get().n;
 assert.equal(total,67108864);
});

test('simultaneous same-intake reservations converge without double units',async()=>{
 const s=await setup(),p=await s.intake('doc-a');const [a,b]=await Promise.all([reserve(s,p),reserve(s,p)]);
 assert.deepEqual(a,b);assert.equal(s.e.ADMIN_DB.db.prepare('SELECT SUM(reserved_units) AS n FROM rag_pdf_jobs').get().n,3);
});

test('policy is mandatory/strict and never reweights existing reservations',async()=>{
 const s=await setup(),p=await s.intake('doc-a');
 for(const bad of [null,{}, {...limits,extra:1},{...limits,reservationUnits:0},{...limits,globalMemoryBytes:128*1024*1024}])
  await reject(()=>reserve(s,p,bad),'pdf_job_policy_required');
 const j=await reserve(s,p);assert.equal((await reserve(s,p,{...limits,reservationUnits:1})).reservedUnits,j.reservedUnits);
});

test('cancel is a stop request only; claimed job holds the slot until confirmed cleanup',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p),t=await claim(s,p,j);
 await requestRawPDFJobStop(s.e,user,j.jobId);
 const b=await s.intake('doc-b');await reject(()=>reserve(s,b),'pdf_job_admission_denied');
 await reject(()=>dispatch(s,p,j,t),'pdf_job_dispatch_conflict');
 await reject(()=>settleRawPDFJob(s.e,j.jobId,t.executionToken),'pdf_job_stop_unconfirmed');
 await reject(()=>closeUnclaimedRawPDFJob(s.e,user,j.jobId),'pdf_job_stop_unconfirmed');
 const end=await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true});assert.equal(end.settledUnits,0);
 assert.deepEqual(await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true}),end);
 await reserve(s,b);
});

test('dispatched or unknown execution consumes reserved units even after cancellation',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p),t=await claim(s,p,j);await dispatch(s,p,j,t);
 await requestRawPDFJobStop(s.e,user,j.jobId);
 const end=await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true});assert.equal(end.settledUnits,3);assert.equal(end.everDispatched,true);
 assert.equal((await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true})).settledUnits,3);
});

test('unclaimed job can only close after stop request; no executor can then claim',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p);
 await reject(()=>closeUnclaimedRawPDFJob(s.e,user,j.jobId),'pdf_job_stop_unconfirmed');
 await requestRawPDFJobStop(s.e,user,j.jobId);assert.equal((await closeUnclaimedRawPDFJob(s.e,user,j.jobId)).settledUnits,0);
 await closeUnclaimedRawPDFJob(s.e,user,j.jobId);await reject(()=>claim(s,p,j),'pdf_job_claim_conflict');
});

test('expiry and day-window rollover never release an active/unknown job',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p);await claim(s,p,j);s.setTime(86400000+1000);
 const b=await s.intake('doc-b');await reject(()=>reserve(s,b),'pdf_job_admission_denied');
 assert.deepEqual(await requestExpiredRawPDFJobsStop(s.e,s.options),{requested:1});
 await reject(()=>reserve(s,b),'pdf_job_admission_denied');
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT settled_units FROM rag_pdf_jobs').get().settled_units,null);
});

test('intake cancellation/replacement/raw consent/account revoke request stop without releasing',async()=>{
 for(const action of ['intake','replace','raw','account']){
  const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p),t=await claim(s,p,j);
  if(action==='intake')await cancelRawPDFIntake(s.e,user,{documentId:p.documentId,intakeId:p.intakeId,generation:p.generation});
  if(action==='replace')await s.intake('doc-a',user,{expectedGeneration:1,requestId:'new-request'});
  if(action==='raw')await updateRawPDFConsent(s.e,user,{enabled:false,expectedEpoch:1});
  if(action==='account')s.e.ADMIN_DB.db.prepare('UPDATE rag_accounts SET deleted=1').run();
  const r=s.e.ADMIN_DB.db.prepare('SELECT state,settled_units FROM rag_pdf_jobs').get();assert.equal(r.state,'stop_requested');assert.equal(r.settled_units,null);
  s.e.RAG_ENABLED='false';assert.equal((await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true})).settledUnits,0);
 }
});

test('units budget and request count cannot be restored by repeated settlement',async()=>{
 const s=await setup(),policy={...limits,reservationUnits:3,perOwnerDailyUnits:3,perOwnerDailyRequests:2};
 const a=await s.intake('doc-a'),j=await reserve(s,a,policy),t=await claim(s,a,j);await dispatch(s,a,j,t);
 await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true});await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true});
 const b=await s.intake('doc-b');await reject(()=>reserve(s,b,policy),'pdf_job_admission_denied');
 // A never-dispatched refund releases units but still counts the request against abuse.
 const u=await setup(),one={...limits,perOwnerDailyRequests:1};const p=await u.intake('one'),r=await reserve(u,p,one);
 await requestRawPDFJobStop(u.e,user,r.jobId);await closeUnclaimedRawPDFJob(u.e,user,r.jobId);
 const next=await u.intake('two');await reject(()=>reserve(u,next,one),'pdf_job_admission_denied');
});

test('foreign owner or incorrect token cannot claim, cancel, dispatch or settle',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p),t=await claim(s,p,j);
 await reject(()=>claim(s,p,j,other),'pdf_intake_not_authorized');
 await reject(()=>requestRawPDFJobStop(s.e,other,j.jobId),'pdf_job_not_found');
 await reject(()=>markRawPDFJobDispatched(s.e,user,p,j.jobId,crypto.randomUUID(),s.options),'pdf_job_dispatch_conflict');
 await reject(()=>settleRawPDFJob(s.e,j.jobId,crypto.randomUUID(),{stopConfirmed:true}),'pdf_job_stop_unconfirmed');
 await dispatch(s,p,j,t);
});

test('missing job migration or DB failure never opens admission',async()=>{
 const s=await setup({jobs:false}),p=await s.intake('doc-a');await reject(()=>reserve(s,p),'pdf_job_upgrade_required');
 const u=await setup(),v=await u.intake('doc-a');const original=u.e.ADMIN_DB.prepare.bind(u.e.ADMIN_DB);
 u.e.ADMIN_DB.prepare=sql=>{if(sql.startsWith('INSERT OR IGNORE INTO rag_pdf_jobs'))throw Error('private SQL details');return original(sql);};
 await reject(()=>reserve(u,v),'pdf_job_unavailable');
 assert.equal(u.e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_jobs').get().n,0);
});

test('failed settlement preserves stop-requested reservation rather than freeing it',async()=>{
 const s=await setup(),p=await s.intake('doc-a'),j=await reserve(s,p),t=await claim(s,p,j);await requestRawPDFJobStop(s.e,user,j.jobId);
 const original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);
 s.e.ADMIN_DB.prepare=sql=>{if(sql.includes("SET state='settled'"))throw Error('private outage');return original(sql);};
 await reject(()=>settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true}),'pdf_job_unavailable');
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT settled_units FROM rag_pdf_jobs').get().settled_units,null);
});

test('global daily units and global request caps apply across distinct owners',async()=>{
 for(const requestCap of [false,true]){
  const s=await setup(),policy={...limits,...(requestCap?{globalDailyRequests:1}:{globalDailyUnits:3})};
  const p=await s.intake('doc-a'),j=await reserve(s,p,policy);
  if(requestCap){await requestRawPDFJobStop(s.e,user,j.jobId);await closeUnclaimedRawPDFJob(s.e,user,j.jobId);}
  else {const t=await claim(s,p,j);await dispatch(s,p,j,t);await settleRawPDFJob(s.e,j.jobId,t.executionToken,{stopConfirmed:true});}
  const next=await s.intake('doc-b',other);await reject(()=>reserve(s,next,policy,other),'pdf_job_admission_denied');
 }
});

test('revocation immediately before reserve/receive/dispatch SQL defeats the write',async()=>{
 for(const stage of ['reserve','receive','dispatch']){
  const s=await setup(),p=await s.intake('doc-a');let j,t;
  if(stage!=='reserve')j=await reserve(s,p);if(stage==='dispatch')t=await claim(s,p,j);
  const original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);
  const match=stage==='reserve'?'INSERT OR IGNORE INTO rag_pdf_jobs':stage==='receive'?"UPDATE rag_pdf_jobs SET state='receiving'":"UPDATE rag_pdf_jobs SET state='dispatched'";
  s.e.ADMIN_DB.prepare=sql=>{const prepared=original(sql);return {bind(...args){const bound=prepared.bind(...args);
   if(sql.startsWith(match)){const run=bound.run;bound.run=async()=>{
    await cancelRawPDFIntake(s.e,user,{documentId:p.documentId,intakeId:p.intakeId,generation:p.generation});return run();};}return bound;}};};
  await reject(()=>stage==='reserve'?reserve(s,p):stage==='receive'?claim(s,p,j):dispatch(s,p,j,t),
   stage==='reserve'?'pdf_job_admission_denied':stage==='receive'?'pdf_job_claim_conflict':'pdf_job_dispatch_conflict');
  const rows=s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').all();
  if(stage==='reserve')assert.equal(rows.length,0);else{assert.equal(rows[0].state,'stop_requested');assert.equal(rows[0].ever_dispatched,0);}
 }
});

test('reserve copies trusted policy/session/proof before async work',async()=>{
 const s=await setup(),proof={...await s.intake('doc-a')},session={...user},policy={...limits};
 const pending=reserveRawPDFJob(s.e,session,proof,policy,s.options);
 policy.reservationUnits=1;session.sub='different-owner';proof.intakeId=crypto.randomUUID();
 const j=await pending;assert.equal(j.reservedUnits,3);assert.equal(j.documentId,'doc-a');
 const key=await accountKey(user.sub);assert.equal(s.e.ADMIN_DB.db.prepare('SELECT account_key FROM rag_pdf_jobs').get().account_key,key);
});
