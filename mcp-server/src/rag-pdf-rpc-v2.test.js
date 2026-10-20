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
import {requestRawPDFJobStop,claimRawPDFJob,markRawPDFJobDispatchedV2} from './rag/pdf-jobs.js';
import {cancelRawPDFProcessor} from './rag/pdf-rpc.js';
import {cancelRawPDFIntake} from './rag/pdf-intake.js';
import {cleanupAccountRawPDF} from './rag/pdf-account-cleanup.js';
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
async function setup({rpcMigration=true,v2=true}={}){
 const e=qualityEnvironment();e.RAG_PDF_RPC_V2_ENABLED=String(v2);e.RAG_PDF_STOP_EVIDENCE_ENABLED='true';e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const p of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql','0014_rag_pdf_retention.sql','0015_rag_pdf_purge.sql','0016_rag_pdf_stop_evidence.sql','0017_rag_pdf_evidence_retention.sql',...(rpcMigration?['0018_rag_pdf_rpc_v2.sql']:[])])e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${p}`,import.meta.url),'utf8'));
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
 e.DOCLING_PROCESSOR.parseV2=async(contract,pdf)=>{calls.push('parseV2');assert.deepEqual(contract,{version:2,jobId:job({e}).job_id,pdfSha256,notAfter:job({e}).deadline});assert.deepEqual(pdf,bytes);return manifest;};
 e.DOCLING_PROCESSOR.cancelV2=async contract=>{calls.push('cancelV2');assert.deepEqual(contract,{version:2,jobId:job({e}).job_id,notAfter:job({e}).deadline});return {cancelled:true};};
 return {e,proof,manifest,calls,key};
}
const run=(s,req=request(),opts=options)=>processRawPDF(s.e,session,s.proof,req,limits,{consumeResult:async value=>{assert.deepEqual(value,s.manifest);s.consumed=(s.consumed??0)+1;},...opts});
const job=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').get();
async function failed(result){assert.ok(result instanceof Response);assert.deepEqual(await result.json(),{error:'pdf_processing_failed'});}

const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const evidence=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_execution_evidence').get();
const recover=s=>recoverRawPDFJobs(s.e,{timeoutMs:40});

// Full MCP pipeline -> private entry -> DO implementation, with synthetic VM/IO.
import {register} from 'node:module';
register('data:text/javascript,'+encodeURIComponent(`
export function resolve(s,c,n){if(s==='cloudflare:workers')return{url:'cloudflare-shim:',shortCircuit:true};return n(s,c);}
export function load(u,c,n){if(u==='cloudflare-shim:')return{format:'module',shortCircuit:true,source:'export class DurableObject {constructor(ctx,env){this.ctx=ctx;this.env=env;}}; export class WorkerEntrypoint {constructor(ctx,env){this.ctx=ctx;this.env=env;}}'};return n(u,c);}
`),import.meta.url);
const {DoclingJob,DoclingProcessor}=await import('../../services/docling-worker/index.js');
function connectPrivate(s){
 const stored=new Map(),calls=[],monitor=deferred();let lock=Promise.resolve(),alarm;
 const storage={get:async k=>structuredClone(stored.get(k)),put:async(k,v)=>{stored.set(k,structuredClone(v));},setAlarm:async n=>{alarm=n;},deleteAlarm:async()=>{alarm=undefined;}};
 const container={start(){calls.push('start');},monitor:()=>monitor.promise,getTcpPort:()=>({fetch:async(url,init)=>{
  if(url.endsWith('/ready'))return new Response(null,{status:204});calls.push('parse');assert.deepEqual(init.body,bytes);
  return new Response(JSON.stringify(s.manifest),{headers:{'Content-Type':'application/json'}});
 }}),destroy:async()=>{calls.push('destroy');monitor.resolve();}};
 const env={DOCLING_EXECUTION_ENABLED:'true',DOCLING_RPC_V2_ONLY:'true'};
 const ctx={storage,container,waitUntil:p=>p.catch(()=>{}),blockConcurrencyWhile(fn){const p=lock.then(fn);lock=p.catch(()=>{});return p;}};
 const object=new DoclingJob(ctx,env),entry=new DoclingProcessor({}, {...env,DOCLING_JOBS:{idFromName:x=>x,get:()=>object}});
 s.e.DOCLING_PROCESSOR=entry;return {stored,calls,object,entry,get alarm(){return alarm;}};
}

test('v2 MCP pipeline saves immutable dispatch envelope and traverses private entry/DO before proofs settle',async()=>{
 const s=await setup(),f=connectPrivate(s);const result=await run(s);
 assert.equal(result.consumed,true);assert.equal(job(s).rpc_version,2);assert.equal(job(s).rpc_pdf_sha256,s.proof.pdfSha256);
 assert.equal(job(s).rpc_not_after,job(s).deadline);assert.equal(job(s).state,'settled');
 assert.ok(evidence(s).local_stopped_at);assert.ok(evidence(s).remote_stopped_at);
 assert.equal(f.stored.get('job').notAfter,job(s).deadline);assert.equal(f.calls.filter(x=>x==='start').length,1);
 assert.equal(JSON.stringify([...f.stored.values()]).includes(s.proof.pdfSha256),false);
});

test('v2 stop after intake digest erasure and all acceptance flags off uses saved contract',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.cancelV2=async()=>({cancelled:false});await failed(await run(s));
 const before=job(s);assert.ok(evidence(s).local_stopped_at);
 await cancelRawPDFIntake(s.e,session,{documentId:s.proof.documentId,intakeId:s.proof.intakeId,generation:s.proof.generation});
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT pdf_sha256 FROM rag_pdf_intakes').get().pdf_sha256,null);
 s.e.RAG_ENABLED=s.e.RAG_PDF_RPC_V2_ENABLED=s.e.RAG_PDF_STOP_EVIDENCE_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED='false';
 let stopped=0;s.e.DOCLING_PROCESSOR={cancelV2:async c=>{stopped++;assert.deepEqual(c,{version:2,jobId:before.job_id,notAfter:before.deadline});return {cancelled:true};}};
 await recover(s);assert.equal(stopped,1);assert.equal(job(s).state,'settled');assert.equal(job(s).rpc_not_after,before.deadline);
});

test('legacy pending drains through v2-only private binding without digest or protocol backfill',async()=>{
 const s=await setup({v2:false}),j=await reserveRawPDFJob(s.e,session,s.proof,limits),scope=await beginRawPDFStopEvidence(s.e,session,s.proof,j.jobId);
 await scope.sealAndRecord();const f=connectPrivate(s);await f.object.ready;
 f.stored.set('job',{jobId:j.jobId,status:'running',deadline:j.deadline,cleanupAttempts:0});
 s.e.RAG_PDF_RPC_V2_ENABLED='true';await confirmRawPDFRemoteStop(s.e,j.jobId);await settleRawPDFJobFromEvidence(s.e,j.jobId);
 assert.equal(job(s).rpc_version,1);assert.equal(job(s).rpc_pdf_sha256,null);assert.equal(f.stored.get('job').rpcVersion,undefined);
 assert.ok(f.calls.includes('destroy'));await assert.rejects(()=>f.entry.parse(j.jobId,bytes),/rpc_upgrade_required/u);
});

test('lost dispatch commit response sends no parse and retains fixed metadata for stop',async()=>{
 const s=await setup(),base=s.e.ADMIN_DB.prepare;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes("SET state='dispatched'")){const all=b.all;b.all=async()=>{await all();throw Error('synthetic lost commit ack');};}return b;}};};
 await failed(await run(s));assert.deepEqual(s.calls,['cancelV2']);assert.equal(job(s).rpc_version,2);assert.equal(job(s).state,'settled');
 assert.equal(job(s).settled_units,1);assert.equal(job(s).rpc_not_after,job(s).deadline);
});

test('late dispatch CAS cannot revive a stopped job and cancel-before-parse blocks v2 replay',async()=>{
 const s=await setup(),f=connectPrivate(s),entered=deferred(),finish=deferred(),base=s.e.ADMIN_DB.prepare;let late;
 s.e.ADMIN_DB.prepare=sql=>{const st=base(sql);return {bind(...args){const b=st.bind(...args);if(sql.includes("SET state='dispatched'")){const all=b.all;b.all=()=>late=(async()=>{entered.resolve();await finish.promise;return all();})();}return b;}};};
 const active=run(s,request(),{...options,workMs:50,cleanupMs:30});await entered.promise;await failed(await active);
 assert.equal(job(s).state,'stop_requested');assert.equal(job(s).rpc_version,1);assert.equal(evidence(s).local_stopped_at,null);
 finish.resolve();await late;assert.equal(job(s).ever_dispatched,0);assert.equal(f.calls.includes('start'),false);
 await assert.rejects(()=>f.entry.parseV2({version:2,jobId:job(s).job_id,pdfSha256:s.proof.pdfSha256,notAfter:job(s).deadline},bytes));
});

test('0018 preserves legacy rows; v2 fields and deadline cannot change, clear or downgrade',async()=>{
 const s=await setup({rpcMigration:false,v2:false}),j=await reserveRawPDFJob(s.e,session,s.proof,limits);
 const db=s.e.ADMIN_DB.db,before=job(s);db.exec(readFileSync(new URL('../migrations/0018_rag_pdf_rpc_v2.sql',import.meta.url),'utf8'));
 const after=job(s);for(const k of Object.keys(before))assert.deepEqual(after[k],before[k]);assert.equal(after.rpc_version,1);
 const claim=await beginRawPDFStopEvidence(s.e,session,s.proof,j.jobId);
 assert.throws(()=>db.exec("UPDATE rag_pdf_jobs SET rpc_version=2"),/pdf_rpc_contract_invalid/u);
 assert.throws(()=>db.exec("UPDATE rag_pdf_jobs SET rpc_pdf_sha256='a'"),/pdf_rpc_contract_invalid/u);
 await markRawPDFJobDispatchedV2(s.e,session,s.proof,j.jobId,claim.executionToken);
 for(const sql of ["rpc_not_after=rpc_not_after+1","rpc_pdf_sha256=NULL","rpc_version=1,rpc_pdf_sha256=NULL,rpc_not_after=NULL","deadline=deadline+1"])
  assert.throws(()=>db.exec(`UPDATE rag_pdf_jobs SET ${sql}`),/pdf_rpc_contract_immutable/u);
 const fixed=job(s);await assert.rejects(()=>markRawPDFJobDispatchedV2(s.e,session,s.proof,j.jobId,claim.executionToken));assert.deepEqual(job(s),fixed);
});

test('missing v2 schema fails before reading body; legacy mode remains usable',async()=>{
 const s=await setup({rpcMigration:false});let read=false;
 await failed(await run(s,{headers:request().headers,signal:new AbortController().signal,get body(){read=true;throw Error('must not read');}}));
 assert.equal(read,false);assert.equal(job(s),undefined);
 s.e.RAG_PDF_RPC_V2_ENABLED='false';assert.equal((await run(s)).consumed,true);assert.deepEqual(s.calls,['parse','cancel']);
});

test('v2 binding failure cannot downgrade or convert remote-only ack to local proof',async()=>{
 const s=await setup(),j=await reserveRawPDFJob(s.e,session,s.proof,limits),claim=await beginRawPDFStopEvidence(s.e,session,s.proof,j.jobId);
 await markRawPDFJobDispatchedV2(s.e,session,s.proof,j.jobId,claim.executionToken);await requestRawPDFJobStop(s.e,session,j.jobId);
 s.e.RAG_PDF_RPC_V2_ENABLED='false';let legacy=0;s.e.DOCLING_PROCESSOR={cancel:async()=>{legacy++;return {cancelled:true};}};
 await assert.rejects(()=>confirmRawPDFRemoteStop(s.e,j.jobId));assert.equal(legacy,0);assert.equal(job(s).settled_units,null);
 s.e.DOCLING_PROCESSOR.cancelV2=async()=>({cancelled:true,extra:true});await assert.rejects(()=>confirmRawPDFRemoteStop(s.e,j.jobId));
 assert.equal(evidence(s).remote_stopped_at,null);
 s.e.DOCLING_PROCESSOR.cancelV2=async()=>({cancelled:true});await confirmRawPDFRemoteStop(s.e,j.jobId);
 await assert.rejects(()=>settleRawPDFJobFromEvidence(s.e,j.jobId));assert.equal(job(s).settled_units,null);
});

test('account deletion uses saved v2 contract after consent minimization with feature flags off',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.cancelV2=async()=>({cancelled:false});await failed(await run(s));
 const fixed=job(s);s.e.ADMIN_DB.db.exec('UPDATE rag_accounts SET deleted=1');s.e.RAG_PDF_RPC_V2_ENABLED=s.e.RAG_PDF_PROCESSING_ENABLED='false';
 let count=0;s.e.DOCLING_PROCESSOR={cancelV2:async c=>{count++;assert.equal(c.notAfter,fixed.deadline);return {cancelled:true};}};
 assert.equal((await cleanupAccountRawPDF(s.e,session.sub)).pending,false);assert.equal(count,1);assert.equal(job(s).state,'settled');
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT pdf_sha256 FROM rag_pdf_intakes').get().pdf_sha256,null);
});

test('v2 metadata follows guarded parent retention; no added table or weakened proof gate',async()=>{
 const s=await setup();await run(s);const db=s.e.ADMIN_DB.db,future=job(s).settled_at+172800000+3000;
 db.function('strftime',(_format,_at)=>String(Math.floor(future/1000)));
 db.prepare('UPDATE rag_pdf_purge_control SET enabled=1,last_clock_at=?').run(Math.floor(future/1000)*1000);
 db.exec("UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL");
 s.e.RAG_PDF_RETENTION_ENABLED=s.e.RAG_PDF_JOB_PURGE_ENABLED='true';
 assert.deepEqual(await purgeSettledRawPDFJobs(s.e,{clock:()=>future}),{purged:1});assert.equal(job(s),undefined);assert.equal(evidence(s),undefined);
});

test('mid-flight acceptance flag rollback cannot change the snapshotted v2 parse or stop protocol',async()=>{
 const s=await setup();const result=await run(s,request(),{...options,onInputConsumed:()=>{s.e.RAG_PDF_RPC_V2_ENABLED='false';}});
 assert.equal(result.consumed,true);assert.deepEqual(s.calls,['parseV2','cancelV2']);assert.equal(job(s).rpc_version,2);
});

test('legacy claim recovery also selects saved v2 RPC after expiry without inventing local proof',async()=>{
 const s=await setup(),j=await reserveRawPDFJob(s.e,session,s.proof,limits),claim=await claimRawPDFJob(s.e,session,s.proof,j.jobId);
 await markRawPDFJobDispatchedV2(s.e,session,s.proof,j.jobId,claim.executionToken);
 s.e.RAG_PDF_RPC_V2_ENABLED='false';let count=0;s.e.DOCLING_PROCESSOR={cancelV2:async c=>{count++;assert.equal(c.notAfter,j.deadline);return {cancelled:true};}};
 await recoverRawPDFJobs(s.e,{clock:()=>j.deadline+1000,timeoutMs:40});assert.equal(count,1);
 assert.equal(job(s).settled_units,null);assert.equal(job(s).claim_protocol,'legacy');assert.equal(evidence(s),undefined);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_job_recovery').get().state,'remote_stopped');
});
