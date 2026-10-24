// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { importantText, relevanceEvidence } from './rag/relevance.ts';
import { queryPlan } from './rag/query.ts';
import { detailRequirements } from './rag/answerability.ts';
const fixture = JSON.parse(readFileSync(new URL('../scripts/rag-quality/fixture.json', import.meta.url)));
const misses = [
 { id: 'def-2', page: 6, score: .532, rank: 1, expected: '液体が表面から気体に変わる現象' },
 { id: 'def-12', page: 56, score: .538, rank: 11, expected: '比べる量が基準の量の求める式' },
 { id: 'ocr-17', page: 85, score: .507, rank: 2, expected: '冬に日本海側で大雪' },
];
for (const c of misses) test(`relevant moderate-score evidence reaches reranking despite request frame: ${c.id}`, () => {
 const query=fixture.queries.find(q=>q.id===c.id).query;
 const page=fixture.pages[c.page-1];
 const candidate={text:page.text,title:'合成教材 検索品質評価',vectorScore:c.score,vectorRank:c.rank};
 assert.equal(importantText(query),c.expected);
 assert.equal(relevanceEvidence(candidate,query).accepted,true);
 assert.equal(queryPlan(query).canonicalQuery,query);
});
test('question frames preserve target conditions and requested formula instead of weakening detail gates', () => {
 for(const [query,expected] of [
  ['距離が時間のどのくらいかを求める式は？','距離が時間の求める式'],
  ['人数が全体のどれだけかを求める式は？','人数が全体の求める式'],
  ['冬に太平洋側で雨になるしくみは？','冬に太平洋側で雨'],
  ['水が20℃で気体に変わる現象の名称は？','水が20°Cで気体に変わる現象'],
 ])assert.equal(importantText(query),expected);
 for(const query of ['ルミ計の2026年の正確な価格を教えて','蒸発の潜熱の正確な値を20℃で教えて','月の2027年の満月日時を教えて']) {
  assert.equal(queryPlan(query).canonicalQuery,query);
  assert.ok(detailRequirements(query).facets.length);
  assert.match(importantText(query),/2026|20°C|2027/);
 }
});
test('definitions, meaningful compound words and unresolved names retain their subjects', () => {
 for(const [query,subject] of [
  ['名前とは？','名前'],['名称の意味とは？','名称'],['仕組みの意味を教えて','仕組み'],
  ['数式とは？','数式'],['説明責任とは？','説明責任'],['比較演算子とは？','比較演算子'],['内容証明とは？','内容証明'],
  ['それの名前は？','それの名前'],['どれほどかを求める式は？','求める式'],
 ])assert.ok(importantText(query).includes(subject),query);
});
test('ordinary negative controls and unrelated descriptive frames do not gain evidence', () => {
 for(const query of fixture.queries.filter(q=>q.expectedPages.length===0).map(q=>q.query)) {
  const candidate={text:fixture.pages[5].text,title:'合成教材',vectorScore:.35,vectorRank:10};
  assert.equal(relevanceEvidence(candidate,query).accepted,false,query);
 }
 for(const query of ['星の中心で原子核が合体する現象の名前は？','大統領が選挙で決まる仕組みは？']) {
  assert.equal(relevanceEvidence({text:fixture.pages[5].text,vectorScore:.35,vectorRank:10},query).accepted,false);
 }
});

test('more-detail request frame is removed after referential rewriting, without weakening relevance', () => {
 const plan=queryPlan('もっと詳しく','ABCについて説明して');
 assert.equal(plan.canonicalQuery,'ABCについてもっと詳しく');
 assert.equal(importantText(plan.canonicalQuery),'ABC');
 const candidate={text:'ABC\n合成概念の説明。'};
 assert.equal(relevanceEvidence(candidate,plan.canonicalQuery).accepted,true);
 assert.equal(relevanceEvidence(candidate,queryPlan('もっと詳しく','XYZとは').canonicalQuery).accepted,false);
 for(const query of ['ABCをもっと詳しく教えて','ABCについてもっと詳しく説明してください','ABCについてもっと詳しく解説して']) {
  assert.ok(!importantText(query).includes('もっと'));
  assert.ok(importantText(query).includes('ABC'));
  assert.equal(queryPlan(query).canonicalQuery,query);
 }
});
test('more-detail cleanup preserves meaningful more/most phrases and unresolved followups', () => {
 for(const query of ['もっとも小さい値を教えて','もっと大きい値を教えて','もっと詳しく学ぶ方法を教えて'])assert.ok(importantText(query).includes('もっと'));
 assert.equal(queryPlan('もっと詳しく').needsClarification,true);
 assert.equal(queryPlan('もっと詳しく','もっと詳しく').needsClarification,true);
 assert.equal(importantText('ABCの2026年の価格をもっと詳しく教えて').includes('2026'),true);
 assert.ok(detailRequirements('ABCの2026年の価格をもっと詳しく教えて').facets.includes('price'));
});

test('named subjects exclude a different name sharing the same predicate, including high vectors',()=>{
 const query='ルミナ草の葉は何色ですか';
 const wrong={text:'ソラナ草の葉は黄色です。',title:'ルミナ草とソラナ草の教材'};
 assert.equal(relevanceEvidence(wrong,query).accepted,false);
 assert.equal(relevanceEvidence({...wrong,vectorScore:.95,vectorRank:1},query).accepted,false);
 assert.equal(relevanceEvidence({text:'ウルミナ草の葉は黄色です。',vectorScore:.95,vectorRank:1},query).accepted,false);
 assert.equal(relevanceEvidence({text:'ルミナ草の葉は紫色です。'},query).accepted,true);
});
test('named subject guard preserves comparison, local headings and semantic synonym rescue',()=>{
 const query='ルミナ草とソラナ草の葉を比較して';
 for(const text of ['ルミナ草の葉は紫色です。','ソラナ草の葉は黄色です。'])assert.equal(relevanceEvidence({text},query).accepted,true);
 assert.equal(relevanceEvidence({heading_context:'ルミナ草',text:'葉は紫色です。'},'ルミナ草の葉は何色ですか').accepted,true);
 assert.equal(relevanceEvidence({text:'電子計算機の説明',vectorScore:.9,vectorRank:1},'コンピュータ装置の説明').accepted,true);
});
