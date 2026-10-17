import test from 'node:test';
import assert from 'node:assert/strict';
import { queryPlan } from './rag/query.js';
import { coversSubject, selectDiverse } from './rag/ranking.js';
import { retrieve } from './rag/retrieval.js';
import { indexSource, accountKey } from './rag/storage.js';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.js';

test('shared motion and representative-value aspects are separate from comparison targets', () => {
 for (const [query, groups, aspect] of [
  ['長距離列車と短距離列車の進み方の違いを教えて',['長距離列車','短距離列車'],'進み方'],
  ['模型実験の水平距離と鉛直距離の代表値を比較して',['模型実験の水平距離','鉛直距離'],'代表値'],
 ]) {
  const plan=queryPlan(query);
  assert.deepEqual(plan.coverageGroups,groups);assert.equal(plan.canonicalQuery,query);
  assert.ok(plan.queries.slice(1).every(q=>q.includes(aspect)));assert.equal(plan.queries.length,3);
 }
});
test('qualified subject accepts reversed nearby body terms and preserves all qualifiers', () => {
 const subject='温度座標系の流速';
 assert.equal(coversSubject({text:'流速（温度座標系）\n定義を説明する。'},subject),true);
 for (const text of ['流速（距離座標系）を説明する。','温度座標系を説明する。','温度座標系。別の流速を説明する。','温度座標系\n\n流速を説明する。','温度座標系'+ '別'.repeat(170)+'流速']) assert.equal(coversSubject({text},subject),false);
 assert.equal(coversSubject({text:'流速を説明する。',title:subject,heading_context:subject},subject),false);
});
test('subject matching preserves quoted names, limits and ordinary queries', () => {
 for(const query of ['「光の屈折」と「音の伝達」の違い','光の屈折と音の伝達の違い']) assert.deepEqual(queryPlan(query).coverageGroups,['光の屈折','音の伝達']);
 assert.equal(coversSubject({text:'音は伝わる。'},'光の屈折'),false);
 assert.deepEqual(queryPlan('代表値とは何か').coverageGroups,[]);
 assert.deepEqual(queryPlan('価格と速度の違い').coverageGroups,['価格','速度']);
 assert.equal(queryPlan('光合成と呼吸と消化の違い').queries.length,3);
});
test('qualified representatives survive Top15 and Top5 without metadata-only evidence', () => {
 const a={source_id:'a',page_number:1,chunk_id:'a',text:'流速（温度座標系）を定義する。'};
 const b={source_id:'a',page_number:2,chunk_id:'b',text:'熱流を定義する。'};
 const rows=[...Array.from({length:20},(_,i)=>({...a,chunk_id:'x'+i,page_number:i+3,text:'別の説明。',title:'温度座標系の流速'})),a,b];
 for(const limit of [15,5]) assert.ok(selectDiverse(rows,['温度座標系の流速','熱流'],limit).some(c=>c.chunk_id==='a'));
});
async function search(query,pages,title='合成教材') {
 const env=qualityEnvironment();
 try {
  await indexSource(env,await accountKey('synthetic-comparison-user'),qualitySource({title,totalPages:pages.length,pages:pages.map((text,i)=>({pageNumber:i+1,text}))}));
  return await retrieve(env,{sub:'synthetic-comparison-user'},{query});
 } finally { env.ADMIN_DB.db.close(); }
}
test('complete qualified comparison is grounded from actual returned body', async () => {
 const hit=await search('温度座標系の流速と熱流の違い',['流速（温度座標系）を定義する。','熱流は熱の移動を表す。']);
 assert.equal(hit.status,'grounded');assert.ok(hit.citations.some(c=>c.pageNumber===1));assert.ok(hit.citations.some(c=>c.pageNumber===2));
});
test('shared motion comparison is grounded without requiring request wording in source', async () => {
 const hit=await search('長距離列車と短距離列車の進み方の違い',['長距離列車は高速で移動する。短距離列車は低速で移動する。']);
 assert.equal(hit.status,'grounded');assert.equal(hit.citations[0].pageNumber,1);
});
test('missing qualifiers, unrelated passages and missing subjects stay partial', async () => {
 for(const text of ['流速（距離座標系）を定義する。熱流は熱の移動。','温度座標系を説明する。流速は別の定義。熱流は熱の移動。','温度座標系\n\n流速は別の定義。熱流は熱の移動。']) {
  const hit=await search('温度座標系の流速と熱流の違い',[text],'温度座標系の流速と熱流');assert.equal(hit.status,'partial');
 }
 const hit=await search('長距離列車と量子色力学の進み方の違い',['長距離列車は高速で移動する。']);assert.equal(hit.status,'partial');
});
test('requested prices still need concrete values for both named targets', async () => {
 const hit=await search('甲製品と乙製品の価格を比較して',['甲製品の価格は100円。乙製品の紹介。']);
 assert.equal(hit.status,'insufficient');assert.equal(hit.citations.length,0);
});
test('repeated attributes are retained for both targets and cannot be supplied by an introduction', async () => {
 const query='水平距離の代表値と鉛直距離の代表値を比較して';
 const plan=queryPlan(query);
 assert.deepEqual(plan.coverageGroups,['水平距離の代表値','鉛直距離の代表値']);
 assert.ok(plan.queries.every(q=>!q.includes('代表値の代表値')));
 const hit=await search(query,['水平距離の代表値は10m。鉛直距離を紹介する。']);
 assert.equal(hit.status,'partial');
});
