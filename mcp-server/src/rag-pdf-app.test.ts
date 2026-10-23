// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import app from './app.ts';
import {mintSession} from './session.ts';
import {sha256Hex} from './auth.ts';
import {canonicalJSON} from './rag/structured-input.ts';
import {qualityEnvironment} from './rag-quality-fixture.ts';
import {accountKey} from './rag/storage.ts';
import {updateConsent} from './rag/control.ts';
import {updateRawPDFConsent} from './rag/pdf-authorization.ts';
import {prepareRawPDFIntake} from './rag/pdf-intake.ts';
const session={sub:'synthetic-process-owner'},bytes=new TextEncoder().encode('%PDF-synthetic');
const limits={perOwnerActive:1,globalActive:1,globalMemoryBytes:67108864,perOwnerDailyUnits:10,globalDailyUnits:10,reservationUnits:1,perOwnerDailyRequests:10,globalDailyRequests:10};
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
async function authenticated(){
 const s=await setup(),values=new Map();
 s.e.STUDIQUO_DATA={async get(key,type){const value=values.get(key);return value===undefined?null:type==='json'?JSON.parse(value):value;},async put(key,value){values.set(key,value);},async delete(key){values.delete(key);}};
 s.e.RATE_LIMIT_RAG_INDEX={limit:async()=>({success:true})};
 // Tokens exist only in this test's ephemeral in-memory KV/request objects.
 s.token=await mintSession(s.e,session.sub,crypto.randomUUID());assert.ok(s.token);s.values=values;return s;
}
function req(s,path,{method='GET',body,token=s.token,headers={}}={}){
 const h=new Headers(request().headers);if(token)h.set('Authorization',`Bearer ${token}`);for(const[k,v]of Object.entries(headers))h.set(k,v);
 if(method==='GET')h.delete('Content-Type');return new Request('https://example.test'+path,{method,headers:h,...(body===undefined?{}:{body,duplex:'half'})});
}
const processPath=s=>`/api/rag/pdf/intakes/${s.proof.intakeId}/process`;
const fetch=(s,r)=>app.fetch(r,s.e,{waitUntil(p){p.catch(()=>{});}});
async function wire(response){return (await response.text()).trim().split('\n').filter(Boolean).map(v=>JSON.parse(v));}

test('app rejects absent and invented bearer tokens before PDF body/clone access',async()=>{
 const s=await authenticated();for(const token of [null,`${Math.floor(Date.now()/1000)}.${crypto.randomUUID()}`]){
  const r=req(s,processPath(s),{method:'POST',body:bytes,token});Object.defineProperty(r,'body',{get(){throw Error('body must remain unread');}});r.clone=()=>{throw Error('no clone');};
  assert.equal((await fetch(s,r)).status,401);assert.deepEqual(s.calls,[]);
 }
});
test('real minted session reaches raw consent and request headers gate processing without JSON cloning raw PDF',async()=>{
 const s=await authenticated(),consent=await fetch(s,req(s,'/api/rag/pdf/consent'));
 assert.equal(consent.status,200);assert.equal((await consent.json()).enabled,true);
 const r=req(s,processPath(s),{method:'POST',body:bytes});r.clone=()=>{throw Error('raw PDF must never enter JSON clone privacy gate');};r.json=()=>{throw Error('raw PDF must not parse as JSON');};
 const response=await fetch(s,r);assert.equal(response.status,200);const frames=await wire(response);assert.equal(frames.at(-1).type,'complete');assert.deepEqual(s.calls,['parse']);
 assert.equal(s.e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_jobs').get().state,'settled');
});
test('app processing requires raw consent and AI age headers before touching raw body',async()=>{
 for(const name of ['X-Studiquo-Raw-PDF-Consent','X-Studiquo-AI-Consent','X-Studiquo-Age','X-Studiquo-RAG-Consent']){
  const s=await authenticated(),r=req(s,processPath(s),{method:'POST',body:bytes});r.headers.delete(name);let read=false;Object.defineProperty(r,'body',{get(){read=true;throw Error('must not read');}});r.clone=()=>{throw Error('must not clone');};
  assert.equal((await fetch(s,r)).status,403);assert.equal(read,false);assert.deepEqual(s.calls,[]);
 }
});
test('canonical linked session resolves the existing owner rather than mint identity or client fields',async()=>{
 const s=await authenticated(),alias='synthetic-app-alias';s.values.set(`identity-canonical:${alias}`,session.sub);const aliasToken=await mintSession(s.e,alias,crypto.randomUUID());
 const response=await fetch(s,req(s,'/api/rag/pdf/consent',{token:aliasToken}));assert.equal(response.status,200);assert.equal((await response.json()).enabled,true);
 const process=await fetch(s,req(s,processPath(s),{method:'POST',body:bytes,token:aliasToken}));assert.equal((await wire(process)).at(-1).type,'complete');assert.deepEqual(s.calls,['parse']);
});
test('a different real session cannot process another owner intake even with valid privacy headers',async()=>{
 const s=await authenticated(),otherToken=await mintSession(s.e,'synthetic-app-other',crypto.randomUUID());let read=false;
 const r=req(s,processPath(s),{method:'POST',body:bytes,token:otherToken});Object.defineProperty(r,'body',{get(){read=true;throw Error('foreign owner body');}});r.clone=()=>{throw Error('no clone');};
 assert.equal((await fetch(s,r)).status,503);assert.equal(read,false);assert.deepEqual(s.calls,[]);assert.equal(s.e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_jobs').get().n,0);
});
test('revoked and account-deleting real sessions cannot reach PDF consent or processing',async()=>{
 for(const kind of ['revoked','deleting']){
  const s=await authenticated();if(kind==='revoked')s.values.set(`revoked:${await sha256Hex(s.token)}`,'1');else s.values.set(`account-deletion:${await sha256Hex(session.sub)}`,JSON.stringify({status:'deleting'}));
  assert.equal((await fetch(s,req(s,'/api/rag/pdf/consent'))).status,401);assert.deepEqual(s.calls,[]);
 }
});
test('legacy RAG consent routes retain existing behavior through app while PDF flags are disabled',async()=>{
 const s=await authenticated();s.e.RAG_PDF_PROCESSING_ENABLED='false';delete s.e.RATE_LIMIT_RAG_PDF;
 const response=await fetch(s,req(s,'/api/rag/consent'));assert.equal(response.status,200);const control=await response.json();assert.equal(control.enabled,true);assert.equal(control.consentEpoch,1);
 const post=req(s,'/api/rag/consent',{method:'POST',body:JSON.stringify({enabled:false,expectedEpoch:1}),headers:{'Content-Type':'application/json'}});post.headers.delete('X-Studiquo-AI-Consent');post.headers.delete('X-Studiquo-RAG-Consent');
 const revoked=await fetch(s,post);assert.equal(revoked.status,200);assert.equal((await revoked.json()).enabled,false);
});
