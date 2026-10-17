import test from 'node:test';
import assert from 'node:assert/strict';
import {queryPlan} from './rag/query.js';
import {retrieve} from './rag/index.js';
import {qualityEnvironment} from './rag-quality-fixture.js';

test('unresolved usage-condition references require clarification; named questions do not',()=>{
 for(const q of ['それを使う条件をもう一度教えて。','これの適用条件を説明して。','あれの使用条件を改めて教えてください。'])assert.equal(queryPlan(q).needsClarification,true);
 for(const q of ['ノアを使う条件をもう一度教えて。','それを使う条件は温度10度以上ですか？','それぞれの使用条件を教えて。'])assert.equal(queryPlan(q).needsClarification,false);
});

test('known singular history rewrites but previous comparison cannot resolve singular referent',()=>{
 const known=queryPlan('それを使う条件をもう一度教えて。','ノアとは');
 assert.equal(known.needsClarification,false);assert.match(known.canonicalQuery,/ノアについて使う条件/);
 const multi=queryPlan('それを使う条件をもう一度教えて。','ノアとセナの違いを教えて');
 assert.equal(multi.needsClarification,true);
 for(const previous of ['合成機器ノアの用途と使用条件を教えて。','オームの法則の成立条件と適用範囲を説明して。','ノアの用途と使用条件を比較して。'])assert.equal(queryPlan('それを使う条件をもう一度教えて。',previous).needsClarification,false);
 assert.equal(queryPlan('それを使う条件をもう一度教えて。','ノアの使用条件とセナの使用条件を比較して。').needsClarification,true);
});

test('usage-condition clarification bypasses embedding vector and keyword searches',async()=>{
 const env=qualityEnvironment();let vectors=0,keywords=0;
 try {
  env.RAG_VECTORIZE.query=async()=>{vectors++;return{matches:[]};};
  const prepare=env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare=sql=>{if(/rag_chunks_fts|bm25\(/i.test(sql))keywords++;return prepare(sql);};
  for(const kind of ['library','notebook']) {
   const r=await retrieve(env,{sub:'synthetic-reference-owner'},{query:'それを使う条件をもう一度教えて。',rag:{scope:{kind,...(kind==='notebook'?{sourceId:'synthetic-source'}:{})}}});
   assert.equal(r.status,'clarification');assert.deepEqual(r.citations,[]);
  }
  assert.equal(vectors,0);assert.equal(keywords,0);assert.equal(env.calls.length,0);
 }finally{env.ADMIN_DB.db.close();}
});
