import test from 'node:test';
import assert from 'node:assert/strict';
import {multiparagraphFixture as fixture,multiparagraphControls} from '../scripts/rag-quality/multiparagraph-fixture.ts';
import {paragraphTask,paragraphMessages,validateParagraphProposal,runParagraphProposal} from '../scripts/rag-quality/paragraph-proposal.ts';
import {measureWitnesses} from '../scripts/rag-quality/paragraph-witness-evaluate.ts';
import {newResumeState,resumePlan} from '../scripts/rag-quality/paragraph-resume.ts';
const overlaps=(p,e)=>p.referenceId===e.referenceId&&p.start<e.end&&e.start<p.end;
for(const c of fixture.cases){
 test(`multi-paragraph stress has observable condition loss and bounded oracle: ${c.id}`,()=>{
  const t=paragraphTask(c.question,c.references),need=c.facts.filter(f=>f.role==='required');
  const decisions=t.references.map(r=>{
   const required=t.paragraphs.filter(p=>p.referenceId===r.id&&need.some(f=>f.evidence.some(e=>overlaps(p,e))));
   assert.ok(t.paragraphs.filter(p=>p.referenceId===r.id).length>=3);
   assert.ok(required.length<=3,'must fit real witness budget without truncation');
   return {referenceId:r.id,action:required.length?'retain':'omit',reason:required.length?'answer':'not_relevant',paragraphIds:(required.length?required:[t.paragraphs.find(p=>p.referenceId===r.id)]).map(p=>p.id)};
  });
  const checked=validateParagraphProposal(t,JSON.stringify({version:2,snapshot:t.snapshot,decision:'select',decisions}));
  assert.equal(checked.valid,true);const m=measureWitnesses(c,t,checked.references,checked.witnesses);assert.deepEqual(m.missingRequired,[]);assert.equal(m.offIntentFacts,0);
  const first=t.references.map(r=>t.paragraphs.find(p=>p.referenceId===r.id));
  assert.ok(measureWitnesses(c,t,t.references,first).protectedRequiredMissing.length>0);
 });
}
test('fixture and labels are immutable, unique exact UTF16 spans on authored synthetic sources',()=>{
 assert.equal(fixture.cases.length,4);assert.ok(Object.isFrozen(fixture));
 for(const c of fixture.cases){assert.ok(Object.isFrozen(c.facts));for(const f of c.facts)for(const e of f.evidence){
  const r=c.references.find(r=>r.id===e.referenceId);assert.match(r.sourceId,/^synthetic-/);assert.equal(r.text.slice(e.start,e.end),e.quote);assert.equal(r.text.indexOf(e.quote,e.start+1),-1);
 }}
 assert.throws(()=>{fixture.cases[0].facts[0].role='supporting';},TypeError);
});
test('required conditions and negation remain separately detectable from formulas and outputs',()=>{
 for(const [caseId,factId] of [['multi-input-output','light'],['multi-negated-comparison','dark'],['multi-formula-domain','exception'],['multi-cross-source-exception','shipping']]){
  const c=fixture.cases.find(c=>c.id===caseId),t=paragraphTask(c.question,c.references),missing=c.facts.find(f=>f.id===factId);
  const witnesses=t.paragraphs.filter(p=>!missing.evidence.some(e=>overlaps(p,e)));
  assert.ok(measureWitnesses(c,t,t.references,witnesses).protectedRequiredMissing.includes(factId));
 }
});
test('gold labels never enter model input; changing only labels invalidates resume experiment identity',()=>{
 const c=fixture.cases[0],t=paragraphTask(c.question,c.references),data=JSON.parse(paragraphMessages(t)[1].content);
 assert.deepEqual(Object.keys(data).sort(),['question','references','snapshot']);
 assert.ok(data.references.every(r=>!Object.hasOwn(r,'facts')));
 const state=newResumeState(fixture),changed=structuredClone(fixture);changed.cases[0].facts[0].protected=!changed.cases[0].facts[0].protected;
 assert.throws(()=>resumePlan(changed,state),/stale/);
 assert.equal(paragraphTask(changed.cases[0].question,changed.cases[0].references).snapshot,t.snapshot);
});
test('diagnostics separate label-reading control from model accuracy and exclude source text',()=>{
 const out=multiparagraphControls();assert.deepEqual(out.summary,{cases:4,singleParagraphReferences:0,totalReferences:9,fullReferenceCoveredCases:4,firstParagraphMissingCases:4,labelOracleMissingCases:0});
 assert.match(out.method,/zero model calls/);assert.match(out.method,/Oracle reads draft labels/);assert.equal(out.fixtureHash.length,64);
 for(const c of fixture.cases){assert.ok(!JSON.stringify(out).includes(c.question));for(const r of c.references)assert.ok(!JSON.stringify(out).includes(r.text));}
});
test('observed valid formula proposal can consume three slots on introduction and omit units',async()=>{
 const c=fixture.cases.find(c=>c.id==='multi-formula-domain'),t=paragraphTask(c.question,c.references);
 const p={version:2,snapshot:t.snapshot,decision:'select',decisions:[
  {referenceId:'r1',action:'retain',reason:'answer',paragraphIds:['r1_p1','r1_p2','r1_p3']},
  {referenceId:'r2',action:'retain',reason:'condition',paragraphIds:['r2_p1','r2_p2']}
 ]};
 const out=await runParagraphProposal(t,async()=>JSON.stringify(p));
 assert.equal(out.status,'shadow');assert.equal(out.productionEligible,false);assert.deepEqual(out.safeReferences,t.references);
 const m=measureWitnesses(c,t,out.shadowReferences,out.witnesses);
 assert.deepEqual(m.missingRequired,['units']);assert.deepEqual(m.protectedRequiredMissing,['units']);assert.equal(m.requiredFacts,4);
 // Required formula/definitions/units fit the same three-slot contract without the introduction.
 p.decisions[0].paragraphIds=['r1_p2','r1_p3','r1_p4'];
 const good=validateParagraphProposal(t,JSON.stringify(p));assert.equal(good.valid,true);
 assert.deepEqual(measureWitnesses(c,t,good.references,good.witnesses).missingRequired,[]);
});
