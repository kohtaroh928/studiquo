import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityEnvironment,qualitySource} from './rag-quality-fixture.ts';
import {indexSource,accountKey} from './rag/storage.ts';
import {retrieve} from './rag/retrieval.ts';
import {compoundReferenceSubject,referenceEligibility} from './rag/reference-selection.ts';
import {queryPlan} from './rag/query.ts';
const sub='synthetic-topic-citation-user';
for(const failure of [false,true,'malformed'])for(const query of ['光合成と呼吸のしくみを比較して','光合成の入力と出力の仕組みを説明して'])test(`topic citations exclude distractors, reranker failure=${failure}, ${query}`,async()=>{
 const env=qualityEnvironment();try{
  const texts=['蒸発は液体が気体に変わる。入力と出力を紹介する。','光合成は光を利用し、二酸化炭素と水から糖と酸素を作る。','呼吸は糖を分解してエネルギーを得る。','光の屈折は光の向きが変わる。'];
  await indexSource(env,await accountKey(sub),qualitySource({title:'光合成と呼吸',totalPages:4,pages:texts.map((text,i)=>({pageNumber:i+1,text}))}));
  if(failure===true){const run=env.AI.run;env.AI.run=async(m,p)=>{if(m.includes('reranker'))throw Error('synthetic outage');return run(m,p);};}
  if(failure==='malformed'){const run=env.AI.run;env.AI.run=async(m,p)=>m.includes('reranker')?{response:[]}:run(m,p);}
  const hit=await retrieve(env,{sub},{query});
  assert.equal(hit.status,'grounded');assert.deepEqual(hit.citations.map(c=>c.pageNumber).sort(),query.includes('比較')?[2,3]:[2]);
  assert.ok(!hit.context.includes('蒸発'));assert.ok(!hit.context.includes('屈折'));
  assert.equal((await retrieve(env,{sub:'synthetic-other'},{query})).citations.length,0);
  assert.equal((await retrieve(env,{sub},{query,scope:{type:'folder',folderId:'none'}})).citations.length,0);
 }finally{env.ADMIN_DB.db.close();}
});
test('compound shared-subject parser is bounded and never changes the original question',()=>{
 for(const q of ['ABCの入力と出力は？','ABCの材料と生成物を教えて','ABCの働きと構造について説明して'])assert.equal(compoundReferenceSubject(q),'ABC');
 for(const q of ['ABCとXYZの入力と出力は？','ABCやXYZの材料と生成物を教えて','入力と出力は？','ABCの入力と入力は？','ABCの入力と出力は？XYZとは？','ABCの価格と速度を教えて','資料全体を要約して'])assert.equal(compoundReferenceSubject(q),'');
});
test('comparison references require body qualifiers, not metadata or separate sentences',()=>{
 const q='温度座標系の流速と熱流を比較して',accept=referenceEligibility(q,queryPlan(q));
 assert.equal(accept({text:'流速（距離座標系）を定義する。',title:'温度座標系の流速',vectorScore:.99,vectorRank:1}),false);
 assert.equal(accept({text:'温度座標系。別の流速。',vectorScore:.99,vectorRank:1}),false);
 assert.equal(accept({text:'流速（温度座標系）を説明する。',vectorScore:.8,vectorRank:1}),true);
});
test('distributed price evidence for both targets is preserved',async()=>{
 const env=qualityEnvironment();try{
  const texts=['甲製品の価格は100円。','乙製品の価格は200円。','無関係な商品の価格は500円。'];
  await indexSource(env,await accountKey(sub),qualitySource({totalPages:3,pages:texts.map((text,i)=>({pageNumber:i+1,text}))}));
  const hit=await retrieve(env,{sub},{query:'甲製品と乙製品の価格を比較して'});
  assert.equal(hit.status,'grounded');assert.deepEqual(hit.citations.map(c=>c.pageNumber).sort(),[1,2]);
 }finally{env.ADMIN_DB.db.close();}
});
test('compound input/output can be supported across pages without those literal labels',async()=>{
 const env=qualityEnvironment();try{
  const texts=['光合成には光、二酸化炭素、水が使われる。','光合成によって糖と酸素が作られる。','呼吸は糖を分解する。'];
  await indexSource(env,await accountKey(sub),qualitySource({totalPages:3,pages:texts.map((text,i)=>({pageNumber:i+1,text}))}));
  const hit=await retrieve(env,{sub},{query:'光合成の入力と出力の仕組みを説明して'});
  assert.deepEqual(hit.citations.map(c=>c.pageNumber).sort(),[1,2]);
 }finally{env.ADMIN_DB.db.close();}
});

test('missing subjects remain partial or fallback, never filled by other topics',async()=>{
 for(const text of ['光合成は光で糖を作る。','蒸発は液体が気体に変わる。']){
  const env=qualityEnvironment();try{
   await indexSource(env,await accountKey(sub),qualitySource({pages:[{pageNumber:1,text}]}));
   const hit=await retrieve(env,{sub},{query:'光合成と呼吸のしくみを比較して'});
   assert.equal(hit.status,text.includes('光合成')?'partial':undefined);
   assert.equal(hit.citations.length,text.includes('光合成')?1:0);
  }finally{env.ADMIN_DB.db.close();}
 }
});
test('truncated excerpt cannot cite a subject present only in the omitted tail',async()=>{
 const env=qualityEnvironment();try{
  await indexSource(env,await accountKey(sub),qualitySource({totalPages:2,pages:[{pageNumber:1,text:'光合成は光で糖を作る。'},{pageNumber:2,text:'呼吸は糖を分解する。'}]}));
  const prepare=env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare=sql=>{
   const prepared=prepare(sql);if(!sql.includes('c.ordinal BETWEEN'))return prepared;
   return {bind(...args){const statement=prepared.bind(...args);return {...statement,async all(){const out=await statement.all();return {results:out.results.map(row=>row.page_number===1?{...row,text:'無関係な長い説明。'.repeat(1000)+row.text}:row)};}};}};
  };
  const hit=await retrieve(env,{sub},{query:'光合成と呼吸のしくみを比較して'});
  assert.equal(hit.status,'partial');assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
 }finally{env.ADMIN_DB.db.close();}
});
