// @ts-nocheck -- historical JS regression fixture; runtime assertions preserved during TS port.
// Real local workerd/D1; remote cancel is a synthetic adapter, not a VM test.
import {Miniflare,convertV4MiniflareOptions} from './rag-local-runtime.ts';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {deleteAccount} from '../src/account-deletion.ts';
import {sha256Hex} from '../src/auth.ts';
import {accountKey} from '../src/rag/storage.ts';
import {updateConsent} from '../src/rag/control.ts';
import {updateRawPDFConsent} from '../src/rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from '../src/rag/pdf-intake.ts';
import {reserveRawPDFJob,markRawPDFJobDispatched,settleRawPDFJob} from '../src/rag/pdf-jobs.ts';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from '../src/rag/pdf-stop-evidence.ts';
import {purgeSettledRawPDFJobs} from '../src/rag/pdf-purge.ts';
const temp=mkdtempSync(join(tmpdir(),'studiquo-account-pdf-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,d1Persist:join(temp,'d1'),durableObjectsPersist:join(temp,'do'),
 workers:[{name:'step5c',modules:true,script:"export default {fetch(){return new Response('ok')}}",
  compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']}]}));
try{
 const db=await mf.getD1Database('ADMIN_DB'),dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|[12]\d|3[01])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8')))await db.prepare(sql).run();files++;
 }
 const values=new Map(),env={ADMIN_DB:db,RAG_ENABLED:'true',AI_PROVIDER_APPROVED:'true',RAG_AUTO_INDEX_ENABLED:'true',
  RAG_PDF_PROCESSING_ENABLED:'true',RAG_PDF_STOP_EVIDENCE_ENABLED:'true',STUDIQUO_DATA:{
   get:async(k,type)=>{const v=values.get(k)??null;return type==='json'&&v?JSON.parse(v):v;},
   put:async(k,v)=>{values.set(k,v);},delete:async k=>{values.delete(k);},
   list:async({prefix})=>({keys:[...values.keys()].filter(k=>k.startsWith(prefix)).map(name=>({name})),list_complete:true})
  }};
 const session={sub:'synthetic-local-account-cleanup'},key=await accountKey(session.sub);
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const proof=await prepareRawPDFIntake(env,session,{documentId:'synthetic-document',requestId:'synthetic-request',expectedGeneration:0,
  pdfSha256:'a'.repeat(64),byteLength:100,consentEpoch:1,rawPDFConsentEpoch:1});
 const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
  reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
 const job=await reserveRawPDFJob(env,session,proof,limits);let scope=await beginRawPDFStopEvidence(env,session,proof,job.jobId);
 await markRawPDFJobDispatched(env,session,proof,job.jobId,scope.executionToken);await scope.sealAndRecord();scope=undefined;
 values.set(`account:${session.sub}`,'{}');values.set('session:synthetic-session',JSON.stringify(session));values.set('snapshot:synthetic-session','synthetic');
 const stateKey=`account-deletion:${await sha256Hex(session.sub)}`,jobKey=`privacy-account-delete:${await sha256Hex(session.sub)}`;
 assert.deepEqual(await deleteAccount(env,session.sub),{deleted:false,cleanupPending:true});
 assert.equal(values.has(`account:${session.sub}`),false);assert.equal(values.has('session:synthetic-session'),false);
 assert.equal(values.has('snapshot:synthetic-session'),false);assert.equal(values.has(jobKey),true);
 const pending=JSON.parse(values.get(stateKey));assert.equal(pending.independentCleanupComplete,true);
 assert.deepEqual(Object.keys(pending).sort(),['status','generation','identityKeys','pdfCleanup','independentCleanupComplete'].sort());
 assert.equal((await db.prepare('SELECT settled_units FROM rag_pdf_jobs WHERE job_id=?').bind(job.jobId).first()).settled_units,null);
 env.DOCLING_PROCESSOR={cancel:async()=>({cancelled:true})};
 env.RAG_ENABLED=env.RAG_PDF_PROCESSING_ENABLED=env.RAG_PDF_STOP_EVIDENCE_ENABLED='false';
 assert.deepEqual(await deleteAccount(env,session.sub),{deleted:true});
 assert.equal((await db.prepare('SELECT settled_units FROM rag_pdf_jobs WHERE job_id=?').bind(job.jobId).first()).settled_units,3);
 assert.equal(values.has(jobKey),false);const finalState=JSON.parse(values.get(stateKey));assert.equal(finalState.status,'deleted');assert.equal(finalState.identityKeys,undefined);assert.deepEqual(finalState.identityHashes,[await sha256Hex(session.sub)]);
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_execution_evidence WHERE job_id=?').bind(job.jobId).first());
 console.log(JSON.stringify({localWorkerd:true,migrations:files,independentErasureWhilePending:true,minimalCheckpoint:true,
  flagsOffEvidenceRecovery:true,tokenFreeRetry:true,evidenceRetained:true,remote:'synthetic_adapter_only',remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
