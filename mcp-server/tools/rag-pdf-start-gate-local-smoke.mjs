// Actual local D1/CAS only. No private start binding, PDF parse or real VM.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {accountKey} from '../src/rag/storage.js';
import {updateConsent} from '../src/rag/control.js';
import {updateRawPDFConsent} from '../src/rag/pdf-authorization.js';
import {prepareRawPDFIntake} from '../src/rag/pdf-intake.js';
import {reserveRawPDFJob,markRawPDFJobDispatchedV2,markRawPDFJobDispatchedWithStartProtocol} from '../src/rag/pdf-jobs.js';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from '../src/rag/pdf-stop-evidence.js';
import {claimRawPDFStart} from '../src/rag/pdf-start-gate.js';
const temp=mkdtempSync(join(tmpdir(),'studiquo-start-gate-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,persist:temp,workers:[{
 name:'start-gate-local',modules:true,script:"export default {fetch(){return new Response('ok')}}",compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']
}]}));
try{
 const db=await mf.getD1Database('ADMIN_DB'),dir=new URL('../migrations/',import.meta.url);let count=0;
 const apply=async name=>{for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8')))await db.prepare(sql).run();count++;};
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|1[0-8])_.*\.sql$/u.test(n)).sort())await apply(name);
 const env={ADMIN_DB:db,AI_PROVIDER_APPROVED:'true',RAG_ENABLED:'true',RAG_AUTO_INDEX_ENABLED:'true',RAG_PDF_PROCESSING_ENABLED:'true',
  RAG_PDF_START_GATE_ENABLED:'true',RAG_PDF_STOP_EVIDENCE_ENABLED:'true',RAG_PDF_RPC_V2_ENABLED:'true',DOCLING_PROCESSOR:{cancelV2:async()=>({cancelled:true})}};
 const session={sub:'synthetic-start-local'},key=await accountKey(session.sub);
 const policy={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:10,globalDailyUnits:10,reservationUnits:1,perOwnerDailyRequests:10,globalDailyRequests:10};
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const prepare=async(doc,oneShot)=>{
  const proof=await prepareRawPDFIntake(env,session,{documentId:doc,requestId:`request-${doc}`,expectedGeneration:0,pdfSha256:'a'.repeat(64),byteLength:20,consentEpoch:1,rawPDFConsentEpoch:1});
  const job=await reserveRawPDFJob(env,session,proof,policy),scope=await beginRawPDFStopEvidence(env,session,proof,job.jobId);
  const contract=await (oneShot?markRawPDFJobDispatchedWithStartProtocol:markRawPDFJobDispatchedV2)(env,session,proof,job.jobId,scope.executionToken);
  return {scope,contract};
 };
 const settle=async s=>{await s.scope.sealAndRecord();await confirmRawPDFRemoteStop(env,s.contract.jobId);await settleRawPDFJobFromEvidence(env,s.contract.jobId);};
 const get=s=>db.prepare('SELECT * FROM rag_pdf_jobs WHERE job_id=?').bind(s.contract.jobId).first();
 const old=await prepare('legacy',false),before=await get(old);await apply('0019_rag_pdf_start_gate.sql');assert.equal(count,19);
 const after=await get(old);for(const k of Object.keys(before))assert.deepEqual(after[k],before[k]);assert.equal(after.start_protocol,'legacy');
 await assert.rejects(()=>claimRawPDFStart(env,old.contract,crypto.randomUUID()));await settle(old);
 const fresh=await prepare('new',true),id=crypto.randomUUID();
 const replies=await Promise.allSettled([claimRawPDFStart(env,fresh.contract,id),claimRawPDFStart(env,fresh.contract,id)]);
 assert.equal(replies.filter(x=>x.status==='fulfilled').length,1);assert.equal((await get(fresh)).start_claim_id,id);
 await assert.rejects(()=>claimRawPDFStart(env,fresh.contract,id));
 await assert.rejects(()=>db.prepare('UPDATE rag_pdf_jobs SET start_claim_id=NULL,start_claimed_at=NULL WHERE job_id=?').bind(fresh.contract.jobId).run());
 await settle(fresh);await assert.rejects(()=>db.prepare('DELETE FROM rag_pdf_jobs WHERE job_id=?').bind(fresh.contract.jobId).run());
 const lost=await prepare('lost',true),lostId=crypto.randomUUID();let injected=false;
 env.ADMIN_DB={prepare(sql){const st=db.prepare(sql);return {bind(...args){const q=st.bind(...args);return {
  first:()=>q.first(),all:async()=>{const r=await q.all();if(sql.includes('SET start_claim_id=')&&!injected){injected=true;throw Error('synthetic lost ack');}return r;}
 };}};}};
 await assert.rejects(()=>claimRawPDFStart(env,lost.contract,lostId),/pdf_start_unavailable/u);env.ADMIN_DB=db;
 assert.equal((await get(lost)).start_claim_id,lostId);await assert.rejects(()=>claimRawPDFStart(env,lost.contract,lostId));
 await settle(lost);assert.equal((await get(lost)).state,'settled');assert.equal((await get(lost)).start_claim_id,lostId);
 console.log(JSON.stringify({localWorkerd:true,d1Migrations:count,actualCAS:true,existingLegacyPreserved:true,oneWinner:true,sameNonceDenied:true,
  lostCommitNotRegranted:true,immutableConsumption:true,newParentHeld:true,vm:'not_started',remoteBinding:'synthetic_cancel_ack_only',remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
