// @ts-nocheck -- historical JS regression fixture; runtime assertions preserved during TS port.
// Real local workerd/D1; remote cancel is a synthetic adapter, not a VM test.
import {Miniflare,convertV4MiniflareOptions} from './rag-local-runtime.ts';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {accountKey} from '../src/rag/storage.ts';
import {updateConsent} from '../src/rag/control.ts';
import {updateRawPDFConsent} from '../src/rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from '../src/rag/pdf-intake.ts';
import {reserveRawPDFJob,markRawPDFJobDispatched,settleRawPDFJob} from '../src/rag/pdf-jobs.ts';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from '../src/rag/pdf-stop-evidence.ts';
import {purgeSettledRawPDFJobs} from '../src/rag/pdf-purge.ts';
const temp=mkdtempSync(join(tmpdir(),'studiquo-stop-evidence-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,d1Persist:join(temp,'d1'),durableObjectsPersist:join(temp,'do'),
 workers:[{name:'step6a',modules:true,script:"export default {fetch(){return new Response('ok')}}",
  compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']}]}));
try{
 const db=await mf.getD1Database('ADMIN_DB'),dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|1[0-6])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8')))await db.prepare(sql).run();files++;
 }
 const env={ADMIN_DB:db,RAG_ENABLED:'true',AI_PROVIDER_APPROVED:'true',RAG_AUTO_INDEX_ENABLED:'true',
  RAG_PDF_PROCESSING_ENABLED:'true',RAG_PDF_STOP_EVIDENCE_ENABLED:'true',DOCLING_PROCESSOR:{cancel:async()=>({cancelled:true})}};
 const session={sub:'synthetic-local-stop-owner'},key=await accountKey(session.sub);
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const proof=await prepareRawPDFIntake(env,session,{documentId:'synthetic-local-document',requestId:'synthetic-local-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1});
 const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
  reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
 const job=await reserveRawPDFJob(env,session,proof,limits);let scope=await beginRawPDFStopEvidence(env,session,proof,job.jobId);
 await markRawPDFJobDispatched(env,session,proof,job.jobId,scope.executionToken);
 await assert.rejects(()=>settleRawPDFJob(env,job.jobId,scope.executionToken,{stopConfirmed:true}),/pdf_job_unavailable/u);
 let release,entered;const ready=new Promise(r=>{entered=r;}),wait=new Promise(r=>{release=r;});
 const task=scope.run(async()=>{entered();await wait;});await ready;
 await confirmRawPDFRemoteStop(env,job.jobId);
 await assert.rejects(()=>scope.sealAndRecord({timeoutMs:15}),/pdf_stop_timeout/u);
 await assert.rejects(()=>settleRawPDFJobFromEvidence(env,job.jobId),/pdf_stop_evidence_incomplete/u);
 assert.equal((await db.prepare('SELECT settled_units FROM rag_pdf_jobs').first()).settled_units,null);
 release();await task;await scope.sealAndRecord();scope=undefined;
 assert.deepEqual(await settleRawPDFJobFromEvidence(env,job.jobId),{settled:true});
 const row=await db.prepare('SELECT settled_units,settled_at FROM rag_pdf_jobs').first();assert.equal(row.settled_units,3);
 await settleRawPDFJobFromEvidence(env,job.jobId);assert.equal((await db.prepare('SELECT settled_at FROM rag_pdf_jobs').first()).settled_at,row.settled_at);
 await assert.rejects(()=>db.prepare('UPDATE rag_pdf_execution_evidence SET local_stopped_at=NULL').run());
 await db.prepare('UPDATE rag_pdf_purge_control SET enabled=1').run();env.RAG_PDF_RETENTION_ENABLED=env.RAG_PDF_JOB_PURGE_ENABLED='true';
 await assert.rejects(()=>purgeSettledRawPDFJobs(env),/pdf_purge_unavailable/u);
 console.log(JSON.stringify({localWorkerd:true,migrations:files,newClaimReturning:true,liveTaskHeld:true,
  durableEvidenceRecovery:true,idempotentSettlement:true,proofRollbackRejected:true,legacyPurgeClosed:true,
  remoteCancel:'synthetic_adapter_only',remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
