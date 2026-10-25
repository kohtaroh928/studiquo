// @ts-nocheck -- historical JS regression fixture; runtime assertions preserved during TS port.
// Real local workerd/D1; remote cancel is a synthetic adapter, not a VM test.
import {Miniflare,convertV4MiniflareOptions} from './rag-local-runtime.ts';
import {unstable_splitSqlQuery} from 'wrangler';
import {readFileSync,readdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {sha256Hex} from '../src/auth.ts';
import {canonicalJSON} from '../src/rag/structured-input.ts';
import {processRawPDF} from '../src/rag/pdf-process.ts';
import {recoverRawPDFJobs} from '../src/rag/pdf-job-recovery.ts';
import {accountKey} from '../src/rag/storage.ts';
import {updateConsent} from '../src/rag/control.ts';
import {updateRawPDFConsent} from '../src/rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from '../src/rag/pdf-intake.ts';
import {reserveRawPDFJob,markRawPDFJobDispatched,settleRawPDFJob} from '../src/rag/pdf-jobs.ts';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from '../src/rag/pdf-stop-evidence.ts';
import {purgeSettledRawPDFJobs} from '../src/rag/pdf-purge.ts';
const temp=mkdtempSync(join(tmpdir(),'studiquo-stop-integration-smoke-'));
const mf=new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',cf:false,d1Persist:join(temp,'d1'),durableObjectsPersist:join(temp,'do'),
 workers:[{name:'step6b',modules:true,script:"export default {fetch(){return new Response('ok')}}",
  compatibilityDate:'2026-08-27',d1Databases:['ADMIN_DB']}]}));
try{
 const db=await mf.getD1Database('ADMIN_DB'),dir=new URL('../migrations/',import.meta.url);let files=0;
 for(const name of readdirSync(dir).filter(n=>/^00(?:0[1-9]|[12]\d|3[01])_.*\.sql$/u.test(n)).sort()){
  for(const sql of unstable_splitSqlQuery(readFileSync(new URL(name,dir),'utf8')))await db.prepare(sql).run();files++;
 }
 const env={ADMIN_DB:db,RAG_ENABLED:'true',AI_PROVIDER_APPROVED:'true',RAG_AUTO_INDEX_ENABLED:'true',
  RAG_PDF_PROCESSING_ENABLED:'true',RAG_PDF_STOP_EVIDENCE_ENABLED:'true'};
 const session={sub:'synthetic-local-stop-integration'},key=await accountKey(session.sub);
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(env,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const bytes=new TextEncoder().encode('%PDF-synthetic'),pdfSha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const proof=await prepareRawPDFIntake(env,session,{documentId:'synthetic-document',requestId:'synthetic-request',expectedGeneration:0,
  pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1});
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256})),text='Synthetic paragraph.';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:null,charspan:[0,text.length]}],coordinateState:'unknown',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:text.length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 const manifest={version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,document,documentNamespace},totalPages:1,pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]}]};

 let cancels=0;env.DOCLING_PROCESSOR={parse:async()=>manifest,cancel:async()=>{cancels++;return {cancelled:false};}};
 const limits={perOwnerActive:1,globalActive:2,globalMemoryBytes:96*1024*1024,perOwnerDailyUnits:10,globalDailyUnits:20,
  reservationUnits:3,perOwnerDailyRequests:10,globalDailyRequests:20};
 const request=new Request('https://example.test/internal',{method:'POST',body:bytes,headers:{'Content-Type':'application/pdf',
  'X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1','X-Studiquo-Raw-PDF-Consent':'raw-pdf-docling-v1'}});
 const result=await processRawPDF(env,session,proof,request,limits,{pollMs:250,workMs:10000,cleanupMs:2000,
  consumeResult:async value=>{assert.deepEqual(value,manifest);}});
 assert.equal(result.status,503);assert.equal(cancels,1);
 const held=await db.prepare('SELECT * FROM rag_pdf_jobs').first();assert.equal(held.settled_units,null);
 assert.ok((await db.prepare('SELECT local_stopped_at FROM rag_pdf_execution_evidence').first()).local_stopped_at);
 env.DOCLING_PROCESSOR.cancel=async()=>{cancels++;return {cancelled:true};};
 await recoverRawPDFJobs(env);assert.equal((await db.prepare('SELECT settled_units FROM rag_pdf_jobs').first()).settled_units,3);
 assert.equal((await db.prepare('SELECT state FROM rag_pdf_job_recovery').first()).state,'done');
 assert.equal(cancels,2);
 // Old synthetic, fully-proved job for 48h retention without moving real clocks.
 const n=Date.now(),day=86400000,window=Math.floor(n/day)*day-4*day;
 const job=crypto.randomUUID(),intake=crypto.randomUUID(),doc=crypto.randomUUID(),hash='b'.repeat(64);
 await db.prepare("INSERT INTO rag_pdf_intakes VALUES('synthetic-retention-owner',?,?,'',1,1,1,'cancelled',NULL,NULL,?)").bind(doc,intake,window+1000).run();
 await db.prepare(`INSERT INTO rag_pdf_jobs(job_id,account_key,document_id,intake_id,generation,consent_epoch,raw_consent_epoch,
  state,window_start,reserved_units,memory_weight,policy_version,deadline,created_at,writer_version)
  VALUES(?,'synthetic-retention-owner',?,?,1,1,1,'reserved',?,3,67108864,'synthetic',?,?,'floor-v2')`).bind(job,doc,intake,window,window+1000,window).run();
 await db.prepare("UPDATE rag_pdf_jobs SET state='receiving',token_hash=?,claim_protocol='stop-proof-v1' WHERE job_id=?").bind(hash,job).run();
 await db.prepare("UPDATE rag_pdf_jobs SET state='stop_requested' WHERE job_id=?").bind(job).run();
 await db.prepare("UPDATE rag_pdf_execution_evidence SET local_stopped_at=?,remote_stopped_at=?,remote_kind='not_dispatched' WHERE job_id=?").bind(window+2000,window+2000,job).run();
 await db.prepare("UPDATE rag_pdf_jobs SET state='settled',settled_units=0,settled_at=? WHERE job_id=?").bind(window+3000,job).run();
 await db.prepare("INSERT INTO rag_pdf_job_recovery(job_id,state) VALUES(?,'done')").bind(job).run();
 await db.prepare('UPDATE rag_pdf_purge_control SET enabled=1').run();env.RAG_PDF_RETENTION_ENABLED=env.RAG_PDF_JOB_PURGE_ENABLED='true';
 await db.prepare("CREATE TRIGGER synthetic_failure AFTER DELETE ON rag_pdf_execution_evidence BEGIN SELECT RAISE(ABORT,'synthetic'); END").run();
 await assert.rejects(()=>purgeSettledRawPDFJobs(env),/pdf_purge_unavailable/u);
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_execution_evidence WHERE job_id=?').bind(job).first());
 assert.ok(await db.prepare('SELECT 1 FROM rag_pdf_jobs WHERE job_id=?').bind(job).first());
 assert.equal((await db.prepare('SELECT min_admission_window AS n FROM rag_pdf_retention_control').first()).n,0);
 await db.prepare('DROP TRIGGER synthetic_failure').run();
 assert.deepEqual(await purgeSettledRawPDFJobs(env),{purged:1});
 assert.equal(await db.prepare('SELECT 1 FROM rag_pdf_execution_evidence WHERE job_id=?').bind(job).first(),null);
 assert.equal(await db.prepare('SELECT 1 FROM rag_pdf_job_recovery WHERE job_id=?').bind(job).first(),null);
 assert.equal((await db.prepare('SELECT purging_job FROM rag_pdf_purge_control').first()).purging_job,null);
 console.log(JSON.stringify({localWorkerd:true,migrations:files,processorLocalProof:true,singleCancelPerCleanup:true,
  reaperEvidenceSettlement:true,cascadeRetention:true,cascadeRollback:true,remote:'synthetic_adapter_only',remoteChanges:false}));
}finally{try{await mf.dispose();}finally{rmSync(temp,{recursive:true,force:true});}}
