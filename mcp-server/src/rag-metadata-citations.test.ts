// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment,qualitySource} from './rag-quality-fixture.ts';
import {accountKey,indexSource} from './rag/storage.ts';
import {retrieve} from './rag/retrieval.ts';
import {revalidateRetrieval} from './rag/authorization.ts';
import {canonicalJSON} from './rag/structured-input.ts';
import {sha256Hex} from './auth.ts';
async function sample(){
 const parser={name:'docling',version:'2.139.0',profile:'native-layout-table-v1'},pdfSha256='a'.repeat(64);
 const documentNamespace=await sha256Hex(canonicalJSON({parser,pdfSha256}));
 const document={parser,pdfSha256,strategy:'structure-semantic-recursive-v1',semanticApplied:false,semanticModel:null,maxEstimatedTokens:400,maxOverlapEstimatedTokens:65,semanticDistanceThreshold:0.35,semanticFallbackReason:'no_vectors',namespaceScope:'document_parser_only_not_authentication',offsetUnit:'unicode_codepoint',provenanceScope:'element'};
 const texts=['光合成は光を使って糖を作る。','光合成には水と二酸化炭素が必要。'];
 const records=await Promise.all(texts.map(async(text,i)=>({text,metadata:{documentNamespace,kind:'text',elementId:`e${i}`,localId:`c${i}`,idSource:'docling_self_ref',pageNumbers:[1],provenanceScope:'element',provenance:[{pageNumber:1,bbox:{l:i,t:0,r:2,b:2,coordOrigin:'TOPLEFT'},charspan:[0,text.length]}],coordinateState:'known',headingPath:{state:'unknown',reason:'no_explicit_heading',items:[]},contextRefs:[],review:{needsReview:false,needsOCR:false,reviewRequired:false,oversized:false},source:{start:0,end:Array.from(text).length,offsetUnit:'unicode_codepoint',textSha256:await sha256Hex(text)}}})));
 return qualitySource({kind:'pdf',structure:{version:1,documentNamespace,document},pages:[{pageNumber:1,text:texts.join('\n\n'),structured:{version:1,records}}]});
}
function environment(){const env=qualityEnvironment();env.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0023_rag_metadata.sql',import.meta.url),'utf8'));return env;}
const question={query:'光合成を説明して',scope:{type:'page',sourceId:'quality-source',pageNumber:1}};
test('structured retrieval carries authorized neighbor elements separately',async()=>{
 const env=environment();try{
  await indexSource(env,await accountKey('metadata-owner'),await sample());
  const result=await retrieve(env,{sub:'metadata-owner'},question);
  assert.ok(result.context);assert.ok(result.citations.length);
  const metadata=result.citations[0].metadata;
  assert.equal(metadata.provenanceScope,'element');
  assert.ok(metadata.segments.every(s=>s.rangeScope==='stored_chunk_not_excerpt'));
  assert.deepEqual(metadata.segments.map(s=>s.elementId),['e0','e1']);
  assert.ok(metadata.segments.every(s=>s.provenance[0].pageNumber===1));
  assert.deepEqual((await retrieve(env,{sub:'foreign-owner'},question)).citations,[]);
 }finally{env.ADMIN_DB.db.close();}
});
test('metadata-only replacement invalidates already retrieved proof',async()=>{
 const env=environment();try{
  const key=await accountKey('metadata-owner'),source=await sample();
  await indexSource(env,key,source);
  const before=await retrieve(env,{sub:'metadata-owner'},question);assert.ok(before.context);
  source.pages[0].structured.records[0].metadata.provenance[0].bbox.l=0.5;
  await indexSource(env,key,source);
  assert.equal((await revalidateRetrieval(env,{sub:'metadata-owner'},before)).context,'');
  const after=await retrieve(env,{sub:'metadata-owner'},question);
  assert.equal(after.citations[0].metadata.segments[0].provenance[0].bbox.l,0.5);
 }finally{env.ADMIN_DB.db.close();}
});
test('invalid stored metadata never becomes a legacy citation',async()=>{
 const env=environment();try{
  await indexSource(env,await accountKey('metadata-owner'),await sample());
  env.ADMIN_DB.db.exec("UPDATE rag_chunks SET metadata_json='{}'");
  const result=await retrieve(env,{sub:'metadata-owner'},question);
  assert.equal(result.context,'');assert.deepEqual(result.citations,[]);
 }finally{env.ADMIN_DB.db.close();}
});
test('100 structured pages complete only after all matching batches; new common metadata invalidates completion',async()=>{
 const env=environment();try{
  const key=await accountKey('metadata-owner'),source=await sample(),base=source.pages[0];
  source.totalPages=100;
  const pages=Array.from({length:100},(_,i)=>{
   const page=structuredClone(base);page.pageNumber=i+1;
   for(const row of page.structured.records){row.metadata.pageNumbers=[i+1];row.metadata.provenance[0].pageNumber=i+1;row.metadata.localId+=`p${i+1}`;}
   return page;
  });
  for(let i=0;i<100;i+=5){
   await indexSource(env,key,{...source,pages:pages.slice(i,i+5)});
   assert.equal(env.ADMIN_DB.db.prepare('SELECT complete FROM rag_sources').get().complete,i===95?1:0);
  }
  assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks WHERE ready=1').get().n,200);
  source.structure.document.maxEstimatedTokens=399;
  await indexSource(env,key,{...source,pages:pages.slice(0,5)});
  assert.equal(env.ADMIN_DB.db.prepare('SELECT complete FROM rag_sources').get().complete,0);
  assert.equal((await retrieve(env,{sub:'metadata-owner'},question)).context,'');
 }finally{env.ADMIN_DB.db.close();}
});
test('HTTP rejects malformed structured input with a fixed 400 before indexing',async()=>{
 const {handleRAG}=await import('./rag/index.ts');
 const env=environment();try{
  env.RATE_LIMIT_RAG_INDEX={limit:async()=>({success:true})};
  const source=await sample();source.pages[0].structured.records[0].metadata.review.needsOCR=true;
  const url=new URL('https://synthetic.invalid/api/rag/index');
  const response=await handleRAG(url,new Request(url,{method:'POST',body:JSON.stringify(source)}),env,{sub:'metadata-owner'});
  assert.equal(response.status,400);assert.deepEqual(await response.json(),{error:'invalid_structured_input'});
  assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks').get().n,0);
 }finally{env.ADMIN_DB.db.close();}
});
test('status advertises structured ingest only for enabled upgraded databases',async()=>{
 const {handleRAG}=await import('./rag/index.ts');
 for(const upgraded of [false,true]){
  const env=upgraded?environment():qualityEnvironment();
  try{
   const url=new URL('https://synthetic.invalid/api/rag/status');
   const result=await handleRAG(url,new Request(url),env,{sub:'metadata-owner'});
   assert.equal((await result.json()).structuredIngestVersion,upgraded?1:0);
   env.RAG_ENABLED='false';
   const disabled=await handleRAG(url,new Request(url),env,{sub:'metadata-owner'});
   assert.equal((await disabled.json()).structuredIngestVersion ?? 0,0);
  }finally{env.ADMIN_DB.db.close();}
 }
});
