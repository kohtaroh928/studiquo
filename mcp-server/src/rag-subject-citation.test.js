import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityEnvironment,qualitySource} from './rag-quality-fixture.js';
import {accountKey,indexSource} from './rag/storage.js';
import {retrieve} from './rag/index.js';
for(const [rerankerFailure,vectorPending] of [[false,false],[true,false],[false,true]])test(`subject-specific citations exclude other subjects, reranker failure=${rerankerFailure}, vector pending=${vectorPending}`,async()=>{
 const env=qualityEnvironment();try{
  const sub='synthetic-subject-citation-owner',key=await accountKey(sub);
  const source=qualitySource({totalPages:2,pages:[{pageNumber:1,text:'ルミナ草の葉は紫色です。'},{pageNumber:2,text:'ソラナ草の葉は黄色です。'}]});
  await indexSource(env,key,source);
  if(vectorPending)env.RAG_VECTORIZE.query=async()=>({matches:[]});
  if(rerankerFailure){const original=env.AI.run.bind(env.AI);env.AI.run=async(model,input)=>{if(model.includes('reranker'))throw Error('synthetic outage');return original(model,input);};}
  const one=await retrieve(env,{sub},{query:'ルミナ草の葉は何色ですか',scope:{type:'library'}});
  assert.deepEqual(one.citations.map(c=>c.pageNumber),[1]);assert.ok(one.context.includes('紫色'));assert.ok(!one.context.includes('ソラナ草'));
  const both=await retrieve(env,{sub},{query:'ルミナ草とソラナ草の葉を比較して',scope:{type:'notebook',sourceId:source.sourceId}});
  assert.equal(both.status,'grounded');assert.deepEqual(both.citations.map(c=>c.pageNumber).sort(),[1,2]);
 }finally{env.ADMIN_DB.db.close();}
});
