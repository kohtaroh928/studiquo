// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';
import { accountKey, indexSource } from './rag/storage.ts';
import { retrieve } from './rag/index.ts';
import { queryPlan } from './rag/query.ts';
import { detailRequirements } from './rag/answerability.ts';
import { singleRankedReference, simpleReferenceQuestion } from './rag/reference-selection.ts';
import { boundedSearch } from './rag/search-branches.ts';
const sub = 'synthetic-citation-stability-owner';
const query = '植物が光を使って養分を作る仕組みは？';
async function rig() {
 const env = qualityEnvironment();
 await indexSource(env, await accountKey(sub), qualitySource({totalPages:3, pages:[
  {pageNumber:1,text:'根は植物を支え、土から水や無機養分を吸収する。'},
  {pageNumber:2,text:'光合成は植物が光を使って養分を作るしくみ。葉緑体では二酸化炭素と水から糖と酸素を作る。'},
  {pageNumber:3,text:'根毛は根の表面積を増やし、水や無機養分の吸収を助ける。'},
 ]}));
 const original = env.AI.run.bind(env.AI);
 env.AI.run = async (model,input) => model.includes('reranker') ? {response:input.contexts.map((c,id)=>({id,score:JSON.parse(c.text).text.includes('光合成')?.9:.1}))} : original(model,input);
 return env;
}
test('simple mechanism citation follows reranker rather than roots ranked first by RRF', async () => {
 const env=await rig();try {
  const hit=await retrieve(env,{sub},{query});
  assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
  assert.ok(!hit.context.includes('根毛'));assert.equal(hit.status,'grounded');
 }finally{env.ADMIN_DB.db.close();}
});
for(const mode of ['vector','embedding','fts','both'])test(`one failed search branch does not erase the other: ${mode}`, async()=>{
 const env=await rig();try{
  if(mode==='vector'||mode==='both')env.RAG_VECTORIZE.query=async()=>{throw Error('synthetic outage');};
  if(mode==='embedding'){const original=env.AI.run;env.AI.run=async(model,input)=>{if(!model.includes('reranker'))throw Error('synthetic outage');return original(model,input);};}
  if(mode==='fts'||mode==='both'){const prepare=env.ADMIN_DB.prepare;env.ADMIN_DB.prepare=sql=>{if(sql.includes('rag_chunks_fts MATCH'))throw Error('synthetic outage');return prepare(sql);};}
  const hit=await retrieve(env,{sub},{query});
  assert.equal(hit.citations.length,mode==='both'?0:1);
  if(mode!=='both')assert.equal(hit.citations[0].pageNumber,2);
  assert.equal((await retrieve(env,{sub:'synthetic-foreign'},{query})).citations.length,0);
  assert.equal((await retrieve(env,{sub},{query,scope:{type:'folder',folderId:'absent'}})).citations.length,0);
 }finally{env.ADMIN_DB.db.close();}
});
test('hung vector search still returns successful FTS before the global deadline',async()=>{
 const env=await rig();try{
  env.RAG_VECTORIZE.query=()=>new Promise(()=>{});
  const hit=await retrieve(env,{sub},{query});assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
 }finally{env.ADMIN_DB.db.close();}
});
test('bounded branch discards late completion and clears its timer',async()=>{
 let finish;const result=boundedSearch(()=>new Promise(resolve=>{finish=resolve;}),5);
 await assert.rejects(result,/search_timeout/);finish('late');
 assert.equal(await boundedSearch(()=>Promise.resolve('ok'),5),'ok');
});
for(const question of [query,'光合成とは？','光合成の意味を教えて','光合成のしくみを説明して'])test(`simple citation opt-in: ${question}`,()=>{
 const plan=queryPlan(question);assert.equal(simpleReferenceQuestion(question,plan,detailRequirements(question,plan.coverageGroups)),true);
});
for(const question of ['光合成と呼吸の仕組みを比較して','光合成の価格と数式を教えて','光合成のしくみを詳しく説明して','細胞の働きと構造を説明して','原因から対策までまとめて','光合成の特徴は？','資料全体を要約して','光合成とは？呼吸とは？','光合成の手順と具体例を教えて','光合成や呼吸の定義を教えて'])test(`distributed evidence keeps multiple references: ${question}`,()=>{
 const plan=queryPlan(question);assert.equal(simpleReferenceQuestion(question,plan,detailRequirements(question,plan.coverageGroups)),false);
});
test('tied, malformed or incomplete reranker output cannot minimize citations',()=>{
 const c=[{chunk_id:'a'},{chunk_id:'b'}],p=queryPlan(query),r=detailRequirements(query);
 for(const out of [undefined,[],[{id:0,score:1}],[{id:0,score:1},{id:0,score:0}],[{id:0,score:NaN},{id:1,score:0}],[{id:0,score:1},{id:1,score:1}]])assert.equal(singleRankedReference(c,out,query,p,r),null);
 assert.deepEqual(singleRankedReference(c,[{id:0,score:-100},{id:1,score:-99}],query,p,r),[c[1]],'Ranks are not calibrated confidence thresholds');
});

import { sourceReadiness } from './rag/readiness.ts';
test('100 visible IDs do not mean ready when middle or last page is not searchable',async()=>{
 const env=qualityEnvironment(),key=await accountKey(sub);try{
  for(let n=0;n<100;n+=5)await indexSource(env,key,qualitySource({kind:'pdf',totalPages:100,pages:Array.from({length:5},(_,i)=>({pageNumber:n+i+1,text:`Synthetic page ${n+i+1}.`}))}));
  const original=env.RAG_VECTORIZE.query;const pages=[];
  env.RAG_VECTORIZE.query=async(v,o)=>{
   assert.deepEqual(o.filter,{accountKey:key,sourceId:'quality-source',folderId:'',pageNumber:o.filter.pageNumber});pages.push(o.filter.pageNumber);
   if(o.filter.pageNumber!==1)return {matches:[]};return original(v,o);
  };
  assert.equal((await sourceReadiness(env,key,'quality-source')).reason,'query_pending');
  assert.deepEqual(pages.sort((a,b)=>a-b),[1,51,100]);
  env.RAG_VECTORIZE.query=original;
  assert.equal((await sourceReadiness(env,key,'quality-source')).state,'ready');
  assert.equal(env.calls.length,100,'Readiness never calls an AI model');
 }finally{env.ADMIN_DB.db.close();}
});
test('readiness never accepts a current chunk from another page as a probe match',async()=>{
 const env=await rig(),key=await accountKey(sub);try{
  const first=[...env.vectors.values()].find(v=>v.metadata.pageNumber===1);
  env.RAG_VECTORIZE.query=async()=>({matches:[{id:first.id}]});
  assert.equal((await sourceReadiness(env,key,'quality-source')).reason,'query_pending');
 }finally{env.ADMIN_DB.db.close();}
});

test('vector hydration failure preserves independently authorized keyword hits',async()=>{
 const env=await rig();try{
  const prepare=env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare=sql=>{if(sql.includes('c.chunk_id IN'))throw Error('synthetic hydration outage');return prepare(sql);};
  const hit=await retrieve(env,{sub},{query});assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
 }finally{env.ADMIN_DB.db.close();}
});
test('complementary mechanism pages survive an explicit compound request',async()=>{
 const env=qualityEnvironment();try{
  await indexSource(env,await accountKey(sub),qualitySource({totalPages:2,pages:[
   {pageNumber:1,text:'光合成の入力は光、二酸化炭素、水である。'},
   {pageNumber:2,text:'光合成の出力は糖と酸素である。'},
  ]}));
  const hit=await retrieve(env,{sub},{query:'光合成の入力と出力の仕組みを説明して'});
  assert.deepEqual(hit.citations.map(c=>c.pageNumber).sort(),[1,2]);
  assert.match(hit.context,/二酸化炭素/);assert.match(hit.context,/酸素/);
 }finally{env.ADMIN_DB.db.close();}
});

test('stalled vector hydration preserves independently authorized keyword evidence',async()=>{
 const env=await rig();try{
  const prepare=env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare=sql=>sql.includes('c.chunk_id IN')?{bind:()=>({all:()=>new Promise(()=>{})})}:prepare(sql);
  const hit=await retrieve(env,{sub},{query});assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
 }finally{env.ADMIN_DB.db.close();}
});
