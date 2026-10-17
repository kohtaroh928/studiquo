import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {clarificationInputBinding as bind,validateClarificationDecision as validate} from '../scripts/rag-quality/clarification-decision.mjs';
const read=n=>JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/'+n,import.meta.url),'utf8'));
const inputs=read('clarification-inputs-v1.json').cases,oracle=read('clarification-oracle-v1.json').cases;
const clone=structuredClone;
function sample(id='clarify-named-fee'){
 const input=clone(inputs.find(c=>c.id===id).input),o=oracle.find(c=>c.id===id);
 return {input,output:{version:1,inputHash:bind(JSON.stringify(input)).inputHash,technicalState:o.technicalState,decisions:o.requirements.map((r,i)=>({id:'d'+(i+1),requestLabel:r.requestLabel,requestRefs:['q'],...r.allowed[0],targetRefs:clone(r.requiredTargetRefs)}))}};
}
const run=s=>validate(JSON.stringify(s.input),JSON.stringify(s.output));
function inputMutation(id,mutate){const s=sample(id);mutate(s.input);assert.throws(()=>bind(JSON.stringify(s.input)),/^Error: clarification_/);}
function outputMutation(id,mutate){const s=sample(id);mutate(s.output,s.input);assert.throws(()=>run(s),/^Error: clarification_/);}
test('clarification structural roundtrip covers all 30 fixtures without claiming semantics',()=>{
 for(const c of inputs){const s=sample(c.id),r=run(s);assert.deepEqual(r.decision,s.output);assert.equal(r.semantics,'pending');assert.equal(r.authorizationVerified,false);assert.equal(r.technicalStateVerified,false);assert.equal(r.releaseAccepted,false);}
});
test('clarification binds full mode/context and normalized parsed JSON, not whitespace bytes',()=>{
 const s=sample('clarify-one-history'),before=bind(JSON.stringify(s.input));assert.equal(bind(JSON.stringify(s.input,null,2)).inputHash,before.inputHash);
 s.input.contextItems[0].text+='別の文。';assert.notEqual(bind(JSON.stringify(s.input)).inputHash,before.inputHash);assert.throws(()=>run(s),/clarification_decision_shape/);
 const original=sample();original.output.inputHash='0'.repeat(64);assert.throws(()=>run(original),/clarification_decision_shape/);
});
test('clarification rejects extra fields, invalid JSON, nonstrings and wrong call arity',()=>{
 inputMutation('clarify-named-fee',i=>i.accountId='synthetic-account');outputMutation('clarify-named-fee',o=>o.authorized=true);
 assert.throws(()=>bind('{}'),/clarification_input_shape/);assert.throws(()=>bind('{'),/clarification_input_json/);assert.throws(()=>bind(null),/clarification_input_size/);
 assert.throws(()=>bind('{}',null),/clarification_arguments/);assert.throws(()=>validate('{}'),/clarification_arguments/);
 const s=sample();assert.throws(()=>validate(JSON.stringify(s.input),'{'),/clarification_decision_json/);
});
test('clarification enforces UTF8 bytes, labels, counts and valid scalar strings without truncation',()=>{
 inputMutation('clarify-named-fee',i=>i.question='あ'.repeat(6000));inputMutation('clarify-named-fee',i=>i.question='\ud800');
 inputMutation('clarify-one-history',i=>i.contextItems[0].text='あ'.repeat(3000));inputMutation('clarify-one-history',i=>i.contextItems[0].revision='x'.repeat(65));
 inputMutation('clarify-one-history',i=>i.contextItems=Array.from({length:17},(_,n)=>({...i.contextItems[0],id:'c'+(n+1)})));
 outputMutation('clarify-named-fee',o=>o.decisions[0].requestLabel='x'.repeat(257));outputMutation('clarify-named-fee',o=>o.decisions[0].requestLabel='\udfff');
 outputMutation('clarify-named-fee',o=>o.decisions=Array.from({length:17},(_,n)=>({...o.decisions[0],id:'d'+(n+1)})));
 const s=sample();assert.throws(()=>bind(' '.repeat(65536)+JSON.stringify(s.input)),/clarification_input_size/);assert.throws(()=>validate(JSON.stringify(s.input),' '.repeat(32768)+JSON.stringify(s.output)),/clarification_decision_size/);
 s.input.question='x'.repeat(16384);assert.equal(bind(JSON.stringify(s.input)).input.question.length,16384);
});
test('clarification rejects duplicate and missing context IDs and mismatched scope versions',()=>{
 inputMutation('clarify-one-history',i=>i.contextItems.push(clone(i.contextItems[0])));
 inputMutation('clarify-page-one-after',i=>i.contextItems[1].scopeRef='c9');inputMutation('clarify-page-one-after',i=>i.contextItems[1].revision='v2');
 inputMutation('clarify-page-one-after',i=>i.contextItems[1].scopeRef='c2');
});
test('clarification never accepts withheld text or content from an unavailable scope',()=>{
 inputMutation('clarify-withheld-context',i=>i.contextItems[0].text='synthetic withheld content');
 inputMutation('clarify-page-one-after',i=>{i.contextItems[0].availability='unavailable';i.contextItems[0].text='';});
 inputMutation('clarify-search-failed',i=>i.contextItems[1].availability='available');
 inputMutation('clarify-named-no-hits',i=>i.contextItems[1].text='not an empty result');
 inputMutation('clarify-page-one-after',i=>i.contextItems[1].text='');
});
test('clarification rejects evidence before inspection and invalid mode/context combinations',()=>{
 inputMutation('clarify-one-history',i=>i.mode='question_only');inputMutation('clarify-page-one-after',i=>i.mode='contextual_pre_search');inputMutation('clarify-page-before',i=>i.mode='scoped_inspection');
 outputMutation('clarify-named-fee',o=>o.decisions[0].evidenceState='supported');
 outputMutation('clarify-page-one-after',o=>o.decisions[0].evidenceState='no_hits');
 outputMutation('clarify-named-no-hits',o=>o.decisions[0].evidenceState='supported');
 outputMutation('clarify-page-one-after',o=>o.decisions[0].evidenceState='unavailable');
 outputMutation('clarify-page-one-after',o=>o.decisions[0].evidenceState='invented');
});
test('clarification restricts provenance kinds and closes inspection to its corresponding scope',()=>{
 outputMutation('clarify-one-history',o=>o.decisions[0].targetRefs=['q']);
 outputMutation('clarify-page-one-after',o=>o.decisions[0].targetRefs=['c2']);
 outputMutation('clarify-page-one-after',(o,i)=>{i.contextItems.push({id:'c3',kind:'scope_page',availability:'available',text:'別ページ範囲',revision:'v1',scopeRef:null,outcome:null});o.inputHash=bind(JSON.stringify(i)).inputHash;o.decisions[0].targetRefs=['c2','c3'];});
 outputMutation('clarify-page-one-after',o=>o.decisions[0].targetRefs=['c1','c2','q','q']);
 outputMutation('clarify-withheld-context',o=>{o.decisions[0].basis='selected_scope';o.decisions[0].targetRefs=['c1'];});
 outputMutation('clarify-named-fee',o=>o.decisions[0].requestRefs=['c1']);
 outputMutation('clarify-page-one-after',(o,i)=>{i.contextItems.push({id:'c3',kind:'user_history',availability:'available',text:'別の文',revision:'v1',scopeRef:null,outcome:null});o.inputHash=bind(JSON.stringify(i)).inputHash;o.decisions[0].targetRefs.push('c3');});
});
test('clarification separates scope content inspection from unresolved target inspection',()=>{
 for(const id of ['clarify-page-summary','clarify-page-before'])assert.equal(run(sample(id)).decision.decisions[0].nextAction,'inspect_scope');
 outputMutation('clarify-page-summary',o=>o.decisions[0].inspectionPurpose='target');
 outputMutation('clarify-page-before',o=>o.decisions[0].inspectionPurpose='content');
 outputMutation('clarify-no-history',o=>{o.decisions[0].nextAction='inspect_scope';o.decisions[0].inspectionPurpose='target';});
});
test('clarification accepts uncertain formal output but refuses inconsistent actions and invented certainty',()=>{
 const s=sample('clarify-no-history'),d=s.output.decisions[0];d.targetState='uncertain';d.nextAction='review_required';assert.equal(run(s).semantics,'pending');
 outputMutation('clarify-no-history',o=>o.decisions[0].nextAction='review_required');
 outputMutation('clarify-no-history',o=>o.decisions[0].nextAction='proceed');
 outputMutation('clarify-named-fee',o=>o.decisions[0].nextAction='clarify_target');
 outputMutation('clarify-general-concept',o=>o.decisions[0].targetRefs=[]);
 outputMutation('clarify-named-fee',o=>o.decisions[0].basis='none');
});
test('clarification preserves mixed partial decisions and permits legitimately repeated states',()=>{
 const s=sample('clarify-partial-requests');assert.equal(run(s).decision.decisions.length,2);
 const same=sample();same.output.decisions.push({...clone(same.output.decisions[0]),id:'d2'});assert.equal(run(same).decision.decisions.length,2);
 same.output.decisions[1].id='d1';assert.throws(()=>run(same),/clarification_decision_fields/);
});
test('clarification technical self-report remains unverified and cannot carry semantic decisions',()=>{
 const s=sample('clarify-search-failed');assert.equal(run(s).decision.technicalState,'ok');assert.equal(run(s).decision.decisions[0].evidenceState,'unavailable');
 for(const state of ['unsupported','failed']){const x=sample();x.output.technicalState=state;assert.throws(()=>run(x),/clarification_technical_state/);x.output.decisions=[];const r=run(x);assert.equal(r.technicalStateVerified,false);}
 outputMutation('clarify-named-fee',o=>o.decisions=[]);
});
test('clarification formal validity cannot prove labels, instructions, coverage or evidence meaning',()=>{
 const s=sample();s.output.decisions[0].requestLabel='質問にない対象を想像した解釈';assert.equal(run(s).semantics,'pending');
 const p=sample('clarify-partial-requests');p.output.decisions.pop();assert.equal(run(p).decision.decisions.length,1);
 const injection=sample('clarify-inspection-injection');injection.output.decisions[0].evidenceState='supported';assert.equal(run(injection).authorizationVerified,false);assert.equal(run(injection).semantics,'pending');
});
