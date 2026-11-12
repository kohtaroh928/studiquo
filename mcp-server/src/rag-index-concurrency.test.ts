// @ts-nocheck -- test fixture helpers are untyped.
import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityEnvironment,qualitySource} from './rag-quality-fixture.ts';
import {accountKey,indexSource} from './rag/storage.ts';
const pages=n=>Array.from({length:n},(_,i)=>({pageNumber:i+1,text:`合成ページ${i+1}の本文。数字${i+1}00円。`}));
const source=n=>({...qualitySource(),totalPages:n,pages:pages(n)});
const stored=env=>env.ADMIN_DB.db.prepare('SELECT * FROM rag_chunks WHERE ready=1').all();
test('pages of one batch are embedded concurrently (bounded) and all become ready',async()=>{
 const env=qualityEnvironment(),key=await accountKey('owner'),original=env.AI.run;let active=0,peak=0;
 env.AI.run=async(...a)=>{active++;peak=Math.max(peak,active);await new Promise(r=>setTimeout(r,20));try{return await original(...a);}finally{active--;}};
 try{await indexSource(env,key,source(5));assert.ok(peak>=2,`peak ${peak}`);assert.ok(peak<=5);assert.equal(new Set(stored(env).map(r=>r.page_number)).size,5);}finally{env.ADMIN_DB.db.close();}
});
test('a failing page stops new pages and in-flight pages settle before the error surfaces',async()=>{
 const env=qualityEnvironment(),key=await accountKey('owner'),original=env.AI.run;let calls=0,active=0;
 env.AI.run=async(...a)=>{const n=++calls;active++;try{await new Promise(r=>setTimeout(r,10));if(n===1)throw new Error('embedding_unavailable');return await original(...a);}finally{active--;}};
 try{await assert.rejects(indexSource(env,key,source(10)),/embedding_unavailable/);assert.equal(active,0);const seen=calls;await new Promise(r=>setTimeout(r,50));assert.equal(calls,seen);assert.ok(seen<10);}finally{env.ADMIN_DB.db.close();}
});
