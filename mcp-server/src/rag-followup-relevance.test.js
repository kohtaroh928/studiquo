import test from 'node:test';
import assert from 'node:assert/strict';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.js';
import { accountKey, indexSource } from './rag/storage.js';
import { retrieve } from './rag/index.js';

test('more-detail followup retrieves previous subject via keyword-only path', async () => {
 const env=qualityEnvironment();
 try {
  const key=await accountKey('synthetic-followup-owner');
  const source=qualitySource({pages:[{pageNumber:1,text:'ABC\n合成概念の説明。'}]});
  await indexSource(env,key,source);
  env.RAG_VECTORIZE.query=async()=>({matches:[]});
  const result=await retrieve(env,{sub:'synthetic-followup-owner'},{query:'もっと詳しく',previousQuestion:'ABCとは',rag:{scope:{kind:'notebook',sourceId:source.sourceId}}});
  assert.ok(result.citations.some(c=>c.pageNumber===1 && c.sourceId===source.sourceId));
  const other=await retrieve(env,{sub:'synthetic-followup-owner'},{query:'もっと詳しく',previousQuestion:'XYZとは',rag:{scope:{kind:'notebook',sourceId:source.sourceId}}});
  assert.equal(other.citations.length,0);
 } finally { env.ADMIN_DB.db.close(); }
});

test('unresolved more-detail request clarifies without embedding or searching', async () => {
 const env=qualityEnvironment();
 try {
  let searches=0;env.RAG_VECTORIZE.query=async()=>{searches++;return {matches:[]};};
  for(const previousQuestion of [undefined,'もっと詳しく']) {
   const result=await retrieve(env,{sub:'synthetic-followup-owner'},{query:'もっと詳しく',previousQuestion,rag:{scope:{kind:'library'}}});
   assert.equal(result.status,'clarification');assert.deepEqual(result.citations,[]);
  }
  assert.equal(env.calls.length,0);assert.equal(searches,0);
 } finally { env.ADMIN_DB.db.close(); }
});
