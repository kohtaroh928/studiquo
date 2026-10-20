// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {validateFixture,shadowSelection,measureSelection,labelledLowerBound,evaluateFixture} from '../scripts/rag-quality/citation-intent-evaluate.ts';
const fixture=JSON.parse(await readFile(new URL('../scripts/rag-quality/citation-intent-fixture.json',import.meta.url)));
const get=id=>fixture.cases.find(c=>c.id===id);
const tiny=()=>({schemaVersion:1,cases:[{id:'unicode',split:'dev',question:'価格は？',references:[{id:'r1',sourceId:'synthetic',pageNumber:1,title:'合成資料',text:'😀価格100円。'}],facts:[{id:'price',role:'required',protected:true,evidence:[{referenceId:'r1',start:2,end:9,quote:'価格100円。'}]}]}]});
test('labels use exact UTF16 spans, including surrogate pairs',()=>{
 assert.equal(validateFixture(tiny()).cases.length,1);
 const f=tiny();f.cases[0].facts[0].evidence[0].start=1;assert.throws(()=>validateFixture(f),/invalid_original_span/);
});
for(const [name,mutate] of [
 ['clamped end',f=>f.cases[0].facts[0].evidence[0].end=999],
 ['missing reference',f=>f.cases[0].facts[0].evidence[0].referenceId='missing'],
 ['empty text',f=>f.cases[0].references[0].text=''],
 ['invalid page',f=>f.cases[0].references[0].pageNumber=0],
 ['non-string question',f=>f.cases[0].question=42],
 ['duplicate references',f=>f.cases[0].references.push({...f.cases[0].references[0]})],
 ['duplicate facts',f=>f.cases[0].facts.push({...f.cases[0].facts[0]})],
 ['unknown role',f=>f.cases[0].facts[0].role='guess'],
 ['missing required',f=>f.cases[0].facts[0].role='supporting'],
 ['missing fact array',f=>delete f.cases[0].facts],
 ['empty case ID',f=>f.cases[0].id=''],
 ['invalid protected',f=>f.cases[0].facts[0].protected='true'],
 ])test(`invalid label dataset is rejected: ${name}`,()=>{const f=tiny();mutate(f);assert.throws(()=>validateFixture(f));});
test('shadow comparison does not mutate the fixed references or labels',()=>{
 const before=JSON.stringify(fixture),report=evaluateFixture(fixture);
 assert.equal(JSON.stringify(fixture),before);assert.equal(report.cases.length,16);
 assert.equal(report.dev.baseline.fullyCoveredCases,8);assert.equal(report.holdout.baseline.fullyCoveredCases,8);
});
test('topic presence alone loses mechanism and distributed input/output facts',()=>{
 for(const id of ['biology-comparison','split-materials']){
  const c=get(id);assert.equal(measureSelection(c,shadowSelection(c,'baseline')).missingRequired.length,0);
  assert.ok(measureSelection(c,shadowSelection(c,'topic_representatives')).missingRequired.length>0);
 }
});
test('example and experiment headings can contain mandatory conditions or formulas',()=>{
 for(const id of ['hidden-condition','formula-scope','unknown-topic']){
  const c=get(id);assert.ok(measureSelection(c,shadowSelection(c,'prefer_direct_headings')).protectedRequiredMissing.length>0);
 }
});
test('explicit example and observation questions keep their evidence',()=>{
 for(const id of ['biology-example','biology-experiment']){const c=get(id);assert.deepEqual(shadowSelection(c,'prefer_direct_headings'),shadowSelection(c,'baseline'));}
});
test('same-page complete containment keeps price and shipping qualifiers',()=>{
 const c=get('same-page-overlap'),refs=shadowSelection(c,'same_page_containment');
 assert.equal(refs.length,1);assert.match(refs[0].text,/送料別途/);assert.equal(measureSelection(c,refs).missingRequired.length,0);
});
test('containment preserves source and page provenance and formula layout',()=>{
 for(const id of ['cross-source-confirmation','cross-page-qualification','sequence-layout']){
  const c=get(id);assert.deepEqual(shadowSelection(c,'same_page_containment'),shadowSelection(c,'baseline'));
 }
});
test('different biology explanations are not full-text duplicates',()=>{
 const c=get('biology-comparison');assert.equal(shadowSelection(c,'same_page_containment').length,5);
});
test('required negation is counted as missing when its citation is removed',()=>{
 const c=get('negated-distinction'),protectedFact=c.facts.find(f=>f.protected),without=c.references.filter(r=>!protectedFact.evidence.some(e=>e.referenceId===r.id));
 assert.ok(measureSelection(c,without).protectedRequiredMissing.includes(protectedFact.id));
});
test('scope-ambiguous supporting references are not classified as erroneous citations',()=>{
 const c=get('biology-input-output'),out=measureSelection(c,c.references);
 assert.equal(out.missingRequired.length,0);assert.ok(out.supportingFacts>0);assert.equal(out.offIntentFacts,0);
 assert.equal('erroneousCitations' in out,false);
});
test('labelled minimum is an oracle and cannot recover evidence outside Top5',()=>{
 const c=get('biology-comparison'),lower=labelledLowerBound(c);
 assert.equal(lower.referenceCount,2);assert.equal(lower.missingRequired.length,0);
 const f=tiny().cases[0];const original=f.references[0];f.references=Array.from({length:5},(_,i)=>({...original,id:'unused'+i,text:'補足'})).concat(original);
 assert.equal(labelledLowerBound(f),null);
});
test('unparsed question uses baseline for topic hypothesis and unknown policies fail',()=>{
 const c=get('unknown-topic');assert.deepEqual(shadowSelection(c,'topic_representatives'),shadowSelection(c,'baseline'));
 assert.throws(()=>shadowSelection(c,'missing'),/unknown_policy/);
});

test('the same fact in independent sources counts either source as support',()=>{
 const c=get('cross-source-confirmation');
 for(const r of c.references)assert.equal(measureSelection(c,[r]).missingRequired.length,0);
 assert.equal(measureSelection(c,c.references).distinctSources,2);
 assert.equal(labelledLowerBound(c).referenceCount,1);
});
