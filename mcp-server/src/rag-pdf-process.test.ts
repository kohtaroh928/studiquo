// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {sha256Hex} from './auth.ts';
import {canonicalJSON} from './rag/structured-input.ts';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from './rag/pdf-intake.ts';
import {requestRawPDFJobStop} from './rag/pdf-jobs.ts';
import {processRawPDF} from './rag/pdf-process.ts';
import {validateRawPDFManifest} from './rag/pdf-manifest.ts';
const session={sub:'synthetic-process-owner'},bytes=new TextEncoder().encode('%PDF-synthetic');
const limits={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:10,globalDailyUnits:10,reservationUnits:1,perOwnerDailyRequests:10,globalDailyRequests:10};
const options={pollMs:5,workMs:2000,cleanupMs:150};
function request(body=bytes,signal){return new Request('https://example.test/internal',{method:'POST',duplex:'half',body,signal,
 headers:{'Content-Type':'application/pdf','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1','X-Studiquo-Raw-PDF-Consent':'raw-pdf-docling-v1'}});}
async function setup(){
 const e=qualityEnvironment();e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const p of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql'])e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${p}`,import.meta.url),'utf8'));
 const key=await accountKey(session.sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const pdfSha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const proof=await prepareRawPDFIntake(e,session,{documentId:'new-doc',requestId:'request-a',expectedGeneration:0,pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1});
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256})),text='Synthetic paragraph.';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:null,charspan:[0,text.length]}],coordinateState:'unknown',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:text.length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 const manifest={version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,document,documentNamespace},totalPages:1,pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]}]};
 const calls=[];e.DOCLING_PROCESSOR={async parse(id,pdf){calls.push('parse');assert.deepEqual(pdf,bytes);return manifest;},async cancel(){calls.push('cancel');return {cancelled:true};}};
 return {e,proof,manifest,calls,key};
}
const run=(s,req=request(),opts=options)=>processRawPDF(s.e,session,s.proof,req,limits,{consumeResult:async value=>{assert.deepEqual(value,s.manifest);s.consumed=(s.consumed??0)+1;},...opts});
const job=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').get();
async function failed(result){assert.ok(result instanceof Response);assert.deepEqual(await result.json(),{error:'pdf_processing_failed'});}

test('success connects receive/digest/one dispatch/strict result/settlement without index writes',async()=>{
 const s=await setup(),result=await run(s);assert.equal(result.consumed,true);assert.equal(s.consumed,1);assert.deepEqual(s.calls,['parse']);
 assert.equal(job(s).state,'settled');assert.equal(job(s).settled_units,1);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_sources').get().n,0);
});

test('missing binding or privacy rejection never consumes or reads the PDF',async()=>{
 const s=await setup();delete s.e.DOCLING_PROCESSOR;let read=false;
 const req={headers:request().headers,get body(){read=true;throw Error('do not read');}};
 assert.equal((await run(s,req)).status,503);assert.equal(read,false);assert.equal(job(s),undefined);
});

test('duplicate processing cannot read a second body or stop the first executor',async()=>{
 const s=await setup();let release;const pending=new Promise(r=>{release=r;});s.e.DOCLING_PROCESSOR.parse=async()=>{s.calls.push('parse');return pending;};
 const first=run(s);while(!s.calls.length)await new Promise(r=>setTimeout(r,1));
 let read=false;const req={method:'POST',headers:request().headers,signal:new AbortController().signal,get body(){read=true;throw Error('must not read');}};
 await failed(await run(s,req));assert.equal(read,false);assert.equal(s.calls.includes('cancel'),false);
 release(s.manifest);assert.equal((await first).consumed,true);assert.deepEqual(s.calls,['parse']);
});

test('byte mismatch causes no parse and releases only after local reader completion',async()=>{
 const s=await setup();const b=bytes.slice();b[b.length-1]^=1;await failed(await run(s,request(b)));
 assert.deepEqual(s.calls,[]);assert.equal(job(s).state,'settled');assert.equal(job(s).settled_units,0);
});

test('parse failure uses explicit cancel confirmation before settlement',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.parse=async()=>{s.calls.push('parse');throw Error('private upstream body');};
 await failed(await run(s));assert.deepEqual(s.calls,['parse','cancel']);assert.equal(job(s).state,'settled');assert.equal(job(s).settled_units,1);
});

test('cancel failure retains reservation on unknown remote stop',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.parse=async()=>{throw Error('lost response');};s.e.DOCLING_PROCESSOR.cancel=async()=>{throw Error('cleanup detail');};
 await failed(await run(s));assert.equal(job(s).state,'stop_requested');assert.equal(job(s).settled_units,null);
});

test('job-only stop during parse is detected and late parse cannot be adopted',async()=>{
 const s=await setup();let release;s.e.DOCLING_PROCESSOR.parse=async id=>{s.calls.push('parse');await requestRawPDFJobStop(s.e,session,id);return new Promise(r=>{release=r;});};
 await failed(await run(s));assert.deepEqual(s.calls,['parse','cancel']);assert.equal(job(s).state,'stop_requested');release(s.manifest);
});

test('request abort while reading stops without starting parse',async()=>{
 const s=await setup(),controller=new AbortController();
 const body=new ReadableStream({pull(){controller.abort();return new Promise(()=>{});},cancel(){}},{highWaterMark:0});
 await failed(await run(s,request(body,controller.signal)));assert.deepEqual(s.calls,[]);assert.equal(job(s).state,'settled');
});

test('unconfirmed local reader cancellation retains reservation',async()=>{
 const s=await setup(),controller=new AbortController();
 const body=new ReadableStream({pull(){controller.abort();return new Promise(()=>{});},cancel(){return new Promise(()=>{});}},{highWaterMark:0});
 await failed(await run(s,request(body,controller.signal),{...options,cleanupMs:25}));
 assert.equal(job(s).state,'stop_requested');assert.equal(job(s).settled_units,null);
});

test('absolute timeout cancels pending RPC and bounds a hanging cancel',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.parse=()=>new Promise(()=>{});s.e.DOCLING_PROCESSOR.cancel=()=>new Promise(()=>{});
 await failed(await run(s,request(),{...options,workMs:35,cleanupMs:20}));assert.equal(job(s).settled_units,null);
});

test('invalid RPC manifest never reaches result adoption even after service stopped',async()=>{
 const s=await setup();s.e.DOCLING_PROCESSOR.parse=async()=>({version:1,integration:'prepared_only_no_upload',batches:[]});
 await failed(await run(s));assert.equal(job(s).state,'settled');assert.equal(job(s).settled_units,1);assert.deepEqual(s.calls,[]);
});

test('manifest strict final validation rejects wrong digest/namespace/hash/pages/unknown fields',async()=>{
 const s=await setup();await validateRawPDFManifest(s.manifest,s.proof.pdfSha256);
 for(const mutate of [v=>{v.extra=1;},v=>{v.batches[0].pages[0].pageNumber=2;},v=>{v.batches[0].structure.document.pdfSha256='c'.repeat(64);},
  v=>{v.batches[0].pages[0].structured.records[0].metadata.source.textSha256='d'.repeat(64);},v=>{v.batches[0].totalPages=2;}]){
  const v=structuredClone(s.manifest);mutate(v);await assert.rejects(validateRawPDFManifest(v,s.proof.pdfSha256),{message:'pdf_manifest_invalid'});
 }
});

test('revocation after settlement still suppresses result return',async()=>{
 const s=await setup(),original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);let done=false;
 s.e.ADMIN_DB.prepare=sql=>{const p=original(sql);return {bind(...args){const b=p.bind(...args);if(sql.includes("SET state='settled'")){const run=b.run;b.run=async()=>{const r=await run();if(!done){done=true;await updateRawPDFConsent(s.e,session,{enabled:false,expectedEpoch:1});}return r;};}return b;}};};
 await failed(await run(s));assert.equal(job(s).state,'settled');
});


test('timed-out verification retaining a PDF copy never releases memory admission',async()=>{
 const s=await setup(),original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);let reads=0,release;
 s.e.ADMIN_DB.prepare=sql=>{const p=original(sql);return {bind(...args){const b=p.bind(...args);
  if(sql.startsWith('SELECT * FROM rag_pdf_intakes WHERE account_key=? AND document_id=? AND intake_id=?')){
   const first=b.first;b.first=()=>{if(++reads===3)return new Promise(r=>{release=()=>r(null);});return first();};
  }return b;}};};
 await failed(await run(s,request(),{...options,workMs:40,cleanupMs:20}));
 assert.equal(job(s).state,'stop_requested');assert.equal(job(s).settled_units,null);release?.();
});

test('successful parse followed by stalled verification respects one shared cleanup grace',async()=>{
 const s=await setup(),original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);let block=false,release;
 s.e.DOCLING_PROCESSOR.parse=async()=>{block=true;return s.manifest;};
 s.e.ADMIN_DB.prepare=sql=>{const p=original(sql);return {bind(...args){const b=p.bind(...args);
  if(block&&sql.includes("FROM rag_pdf_jobs WHERE account_key=? AND job_id=? AND intake_id=?"))b.first=()=>new Promise(r=>{release=()=>r(null);});
  return b;}};};
 await failed(await run(s,request(),{...options,workMs:40,cleanupMs:20}));
 assert.equal(job(s).settled_units,null);release?.();
});

test('failure after success cleanup timeout does not create a second grace window',async()=>{
 const s=await setup(),original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);let guardReads=0,release,stopWrites=0;
 s.e.ADMIN_DB.prepare=sql=>{const p=original(sql);return {bind(...args){const b=p.bind(...args);
  if(sql.includes("FROM rag_pdf_jobs WHERE account_key=? AND job_id=? AND intake_id=?")){
   const first=b.first;b.first=()=>++guardReads===1?new Promise(r=>{release=()=>r(null);}):first();
  }
  if(sql.startsWith("UPDATE rag_pdf_jobs SET state='stop_requested'")){stopWrites++;}
  return b;}};};
 await failed(await run(s,request(),{...options,workMs:2000,cleanupMs:20}));
 assert.equal(stopWrites,0);assert.equal(job(s).settled_units,null);release?.();
});


test('large result consumer holds admission until it has finished and never returns the manifest',async()=>{
 const s=await setup();let started=false,release;
 const pending=run(s,request(),{...options,consumeResult:async value=>{assert.deepEqual(value,s.manifest);started=true;await new Promise(r=>{release=r;});}});
 while(!started)await new Promise(r=>setTimeout(r,1));
 assert.equal(job(s).state,'dispatched');assert.equal(job(s).settled_units,null);
 release();const result=await pending;assert.equal(result.manifest,undefined);assert.equal(result.consumed,true);
});
