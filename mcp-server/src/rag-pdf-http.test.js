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
import {handleRawPDFHTTP} from './rag/pdf-http.js';
const session={sub:'synthetic-process-owner'},bytes=new TextEncoder().encode('%PDF-synthetic');
const limits={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:10,globalDailyUnits:10,reservationUnits:1,perOwnerDailyRequests:10,globalDailyRequests:10};
const options={pollMs:5,workMs:2000,cleanupMs:150};
function request(body=bytes,signal){return new Request('https://example.test/internal',{method:'POST',duplex:'half',body,signal,
 headers:{'Content-Type':'application/pdf','X-Studiquo-AI-Consent':'openai-v1','X-Studiquo-Age':'adult','X-Studiquo-RAG-Consent':'rag-openai-v1','X-Studiquo-Raw-PDF-Consent':'raw-pdf-docling-v1'}});}
async function setup(){
 const e=qualityEnvironment();e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 for(const p of ['0010_rag_raw_pdf_consent.sql','0011_rag_pdf_intakes.sql','0012_rag_pdf_jobs.sql','0013_rag_pdf_job_recovery.sql'])e.ADMIN_DB.db.exec(readFileSync(new URL(`../migrations/${p}`,import.meta.url),'utf8'));
 const key=await accountKey(session.sub);await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 const pdfSha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 const proof=await prepareRawPDFIntake(e,session,{documentId:'new-doc',requestId:'request-a',expectedGeneration:0,pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1});
 const document={parser:{name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const documentNamespace=await sha256Hex(canonicalJSON({parser:document.parser,pdfSha256})),text='Synthetic paragraph.';
 const metadata={documentNamespace,kind:'text',elementId:'#/texts/0',localId:'b'.repeat(64),idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:null,charspan:[0,text.length]}],coordinateState:'unknown',headingPath:{state:'unknown',reason:'missing_parent',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:text.length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}};
 const manifest={version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,document,documentNamespace},totalPages:1,pages:[{pageNumber:1,text,structured:{version:1,records:[{text,metadata}]}}]}]};
 e.RAG_PDF_ADMISSION_POLICY=JSON.stringify(limits);e.RAG_PDF_INTAKE_LIMITS=JSON.stringify({ownerRows:5,globalRows:100,ownerPending:1,globalPending:10});e.RATE_LIMIT_RAG_PDF={limit:async()=>({success:true})};
 const calls=[];e.DOCLING_PROCESSOR={async parse(id,pdf){calls.push('parse');assert.deepEqual(pdf,bytes);return manifest;},async cancel(){calls.push('cancel');return {cancelled:true};}};
 return {e,proof,manifest,calls,key};
}
const path=s=>`/api/rag/pdf/intakes/${s.proof.intakeId}/process`;
const url=p=>new URL('https://example.test'+p);
const run=(s,req=request(),p=path(s),who=session)=>handleRawPDFHTTP(url(p),req,s.e,who,{processOptions:options});
const job=s=>s.e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_jobs').get();
async function frames(response){let text='';try{text=await response.text();}catch{return {failed:true,frames:[]};}return {failed:false,frames:text.trim().split('\n').filter(Boolean).map(x=>JSON.parse(x))};}
const jsonRequest=value=>{const headers=new Headers(request().headers);headers.set('Content-Type','application/json');return new Request('https://example.test/',{method:'POST',headers,body:JSON.stringify(value)});};

test('HTTP process streams provisional bounded manifest then settled completion with exact byte/hash binding',async()=>{
 const s=await setup(),response=await run(s);assert.equal(response.headers.get('content-type'),'application/x-ndjson; charset=utf-8');
 const result=await frames(response);assert.equal(result.failed,false);assert.equal(result.frames[0].type,'begin');
 const complete=result.frames.at(-1);assert.equal(complete.type,'complete');assert.equal(complete.pdfSha256,s.proof.pdfSha256);
 const manifestText=result.frames.filter(x=>x.type==='manifest').map(x=>x.text).join('');assert.deepEqual(JSON.parse(manifestText),s.manifest);
 assert.equal(complete.manifestByteLength,new TextEncoder().encode(manifestText).length);assert.equal(complete.manifestSha256,await sha256Hex(manifestText));
 assert.equal(job(s).state,'settled');assert.deepEqual(s.calls,['parse']);
});
test('foreign owner, expired and revoked intake reject before raw body access',async()=>{
 for(const variant of ['foreign','expired','revoked']){
  const s=await setup();if(variant==='expired')s.e.ADMIN_DB.db.prepare('UPDATE rag_pdf_intakes SET expires_at=0').run();
  if(variant==='revoked')await updateRawPDFConsent(s.e,session,{enabled:false,expectedEpoch:1});
  let read=false;const req={method:'POST',headers:request().headers,signal:new AbortController().signal,get body(){read=true;throw Error('private');}};
  const response=await run(s,req,path(s),variant==='foreign'?{sub:'another-synthetic-owner'}:session);assert.equal(response.status,503);assert.equal(read,false);assert.deepEqual(s.calls,[]);
 }
});
test('disabled flag, missing policy/binding/rate/schema reject before PDF read',async()=>{
 for(const variant of ['flag','policy','binding','rate','schema']){
  const s=await setup();if(variant==='flag')s.e.RAG_PDF_PROCESSING_ENABLED='false';if(variant==='policy')delete s.e.RAG_PDF_ADMISSION_POLICY;if(variant==='binding')delete s.e.DOCLING_PROCESSOR;if(variant==='rate')delete s.e.RATE_LIMIT_RAG_PDF;if(variant==='schema')s.e.ADMIN_DB.db.exec('DROP TABLE rag_pdf_job_recovery');
  let read=false;const req={method:'POST',headers:request().headers,get body(){read=true;throw Error('private');}};
  assert.equal((await run(s,req)).status,503);assert.equal(read,false);assert.equal(job(s),undefined);
 }
});
test('rate denial and unauthenticated session reject before request read',async()=>{
 const s=await setup();let read=false;const req={method:'POST',headers:request().headers,get body(){read=true;throw Error('private');}};
 s.e.RATE_LIMIT_RAG_PDF.limit=async()=>({success:false});assert.equal((await run(s,req)).status,429);assert.equal((await run(s,req,path(s),{})).status,401);assert.equal(read,false);
});
test('bounded intake creation uses canonical owner and server-side caps, not body policy',async()=>{
 const s=await setup();const p={documentId:'new-doc-2',requestId:'request-b',expectedGeneration:0,pdfSha256:s.proof.pdfSha256,byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1};
 s.e.RAG_PDF_INTAKE_LIMITS=JSON.stringify({ownerRows:5,globalRows:100,ownerPending:1,globalPending:10});assert.equal((await run(s,jsonRequest(p),'/api/rag/pdf/intakes')).status,503);
 const req=jsonRequest({...p,accountKey:'foreign',policy:{ownerPending:100}});assert.equal((await run(s,req,'/api/rag/pdf/intakes')).status,503);
});
test('raw consent GET and withdrawal and intake cancellation remain usable with flags off',async()=>{
 const s=await setup();s.e.RAG_PDF_PROCESSING_ENABLED=s.e.RAG_ENABLED=s.e.AI_PROVIDER_APPROVED='false';delete s.e.DOCLING_PROCESSOR;
 assert.equal((await run(s,new Request('https://example.test/'),'/api/rag/pdf/consent')).status,200);
 assert.equal((await run(s,jsonRequest({generation:s.proof.generation}),`/api/rag/pdf/intakes/${s.proof.intakeId}/cancel`)).status,200);
 assert.equal((await run(s,jsonRequest({enabled:false,expectedEpoch:1}),'/api/rag/pdf/consent')).status,200);
});
test('duplicate process does not consume second body or stop the original parser',async()=>{
 const s=await setup();let release;s.e.DOCLING_PROCESSOR.parse=async()=>{s.calls.push('parse');return new Promise(r=>{release=r;});};
 const first=await run(s);while(!s.calls.length)await new Promise(r=>setTimeout(r,1));let read=false;
 const req={method:'POST',headers:request().headers,signal:new AbortController().signal,get body(){read=true;throw Error('private');}};
 const second=await run(s,req);assert.equal(second.status,503);assert.deepEqual(await second.json(),{error:'pdf_processing_failed'});assert.equal(read,false);assert.deepEqual(s.calls,['parse']);release(s.manifest);assert.equal((await frames(first)).failed,false);
});
test('stream cancellation aborts processing without returning a completion frame',async()=>{
 const s=await setup();const response=await run(s);const reader=response.body.getReader();const first=await reader.read();assert.equal(JSON.parse(new TextDecoder().decode(first.value)).type,'begin');await reader.cancel();
 await new Promise(r=>setTimeout(r,30));assert.notEqual(job(s)?.state,'dispatched');
});
test('revocation during provisional delivery suppresses completion',async()=>{
 const s=await setup(),response=await run(s),reader=response.body.getReader();await reader.read();await updateRawPDFConsent(s.e,session,{enabled:false,expectedEpoch:1});
 let text='';try{for(;;){const x=await reader.read();if(x.done)break;text+=new TextDecoder().decode(x.value);}}catch{}
 assert.equal(text.includes('"type":"complete"'),false);
});
test('settlement DB failure never sends successful terminal frame',async()=>{
 const s=await setup(),original=s.e.ADMIN_DB.prepare.bind(s.e.ADMIN_DB);s.e.ADMIN_DB.prepare=sql=>{if(sql.includes("SET state='settled'"))throw Error('private database');return original(sql);};
 assert.equal((await frames(await run(s))).failed,true);assert.notEqual(job(s).state,'settled');
});
test('route accepts only opaque UUID path with no digest/query and rejects cross-owner cancellation',async()=>{
 const s=await setup();assert.equal((await run(s,request(),`/api/rag/pdf/intakes/${s.proof.pdfSha256}/process`)).status,404);assert.equal((await run(s,request(),path(s)+'?digest=x')).status,404);
 assert.equal((await run(s,jsonRequest({generation:1}),`/api/rag/pdf/intakes/${s.proof.intakeId}/cancel`,{sub:'foreign-synthetic'})).status,503);
});
test('consent granting needs privacy headers and current flags',async()=>{
 const s=await setup();await updateRawPDFConsent(s.e,session,{enabled:false,expectedEpoch:1});const p={enabled:true,expectedEpoch:2,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'};
 const req=jsonRequest(p);req.headers.delete('X-Studiquo-Raw-PDF-Consent');assert.equal((await run(s,req,'/api/rag/pdf/consent')).status,403);
 s.e.RAG_PDF_PROCESSING_ENABLED='false';assert.equal((await run(s,jsonRequest(p),'/api/rag/pdf/consent')).status,503);
});
test('slow reader holds admission during transfer then times out without completion',async()=>{
 const s=await setup(),response=await handleRawPDFHTTP(url(path(s)),request(),s.e,session,{processOptions:options,transferMs:40});
 await new Promise(r=>setTimeout(r,15));assert.equal(job(s).state,'dispatched');assert.equal(job(s).settled_units,null);
 await new Promise(r=>setTimeout(r,65));assert.equal((await frames(response)).failed,true);assert.equal(job(s).state,'settled');
});
test('withdrawal while completed result waits for terminal reader demand prevents completion',async()=>{
 const s=await setup(),response=await run(s),reader=response.body.getReader();
 assert.equal(JSON.parse(new TextDecoder().decode((await reader.read()).value)).type,'begin');
 assert.equal(JSON.parse(new TextDecoder().decode((await reader.read()).value)).type,'manifest');
 for(let i=0;i<100&&job(s).state!=='settled';i++)await new Promise(r=>setTimeout(r,1));assert.equal(job(s).state,'settled');
 await updateRawPDFConsent(s.e,session,{enabled:false,expectedEpoch:1});
 await assert.rejects(reader.read(),/pdf_transfer_failed/);
});
test('malformed or oversized JSON intake and foreign identity fields cannot create rows',async()=>{
 const s=await setup();for(const value of [{accountKey:'foreign',documentId:'another'}, {padding:'x'.repeat(9000)}, []]){
  assert.equal((await run(s,jsonRequest(value),'/api/rag/pdf/intakes')).status,503);
 }
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,1);assert.deepEqual(s.calls,[]);
});
test('raw request abort during provisional sending invalidates remaining frames',async()=>{
 const s=await setup(),controller=new AbortController(),response=await run(s,request(bytes,controller.signal)),reader=response.body.getReader();await reader.read();controller.abort();await assert.rejects(reader.read(),/pdf_transfer_failed/);
});
test('HTTP headers wait until admitted bounded upload is consumed, while parser may continue afterward',async()=>{
 const s=await setup();let input,pushed=false,readStarted=false,returned=false;
 const body=new ReadableStream({start(controller){input=controller;},pull(){readStarted=true;}},{highWaterMark:0});
 const pending=run(s,request(body)).then(response=>{returned=true;return response;});
 for(let i=0;i<100&&!readStarted;i++)await new Promise(r=>setTimeout(r,1));
 assert.equal(readStarted,true);assert.equal(returned,false);assert.equal(job(s).state,'receiving');assert.deepEqual(s.calls,[]);
 let release;s.e.DOCLING_PROCESSOR.parse=async()=>{s.calls.push('parse');return new Promise(r=>{release=r;});};
 input.enqueue(bytes);input.close();pushed=true;
 const response=await pending;assert.equal(pushed,true);assert.equal(response.status,200);
 for(let i=0;i<100&&!release;i++)await new Promise(r=>setTimeout(r,1));assert.ok(release);release(s.manifest);assert.equal((await frames(response)).failed,false);
});
test('admitted raw upload failure is an HTTP failure rather than an early streaming success',async()=>{
 const s=await setup();const response=await run(s,request(new TextEncoder().encode('not-pdf')));assert.equal(response.status,503);assert.deepEqual(await response.json(),{error:'pdf_processing_failed'});assert.deepEqual(s.calls,[]);assert.equal(job(s).state,'settled');
});
