import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {clarificationInputBinding} from '../scripts/rag-quality/clarification-decision.mjs';
import {clarificationReviewBinding as binding,evaluateClarificationReview as evaluate,CLARIFICATION_REVIEW_DIMENSIONS as dims} from '../scripts/rag-quality/clarification-semantic-review.mjs';
const read=n=>JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/'+n,import.meta.url),'utf8'));
const inputs=read('clarification-inputs-v1.json').cases,oracles=read('clarification-oracle-v1.json').cases;
function sample(id='clarify-named-fee'){
 const input=JSON.stringify(inputs.find(c=>c.id===id).input),oracle=structuredClone(oracles.find(c=>c.id===id));
 const decision={version:1,inputHash:clarificationInputBinding(input).inputHash,technicalState:oracle.technicalState,decisions:oracle.requirements.map((r,i)=>({id:'d'+(i+1),requestLabel:r.requestLabel,requestRefs:['q'],...r.allowed[0],targetRefs:structuredClone(r.requiredTargetRefs)}))};return {input,oracle,decision};
}
function review(s){return {...binding(s.input,JSON.stringify(s.decision),JSON.stringify(s.oracle)),reviewerRole:'independent_clarification_reviewer',artifactHash:'a'.repeat(64),representability:s.oracle.requirements.map(r=>({requirementId:r.id,status:'representable'})),pairs:s.decision.decisions.flatMap((d,i)=>s.oracle.requirements.map((r,j)=>({decisionId:d.id,requirementId:r.id,dimensions:Object.fromEntries(dims.map(k=>[k,i===j?'pass':'fail']))}))),actionAssessments:s.decision.decisions.map(d=>({decisionId:d.id,judgment:'appropriate'}))};}
const run=(s,r)=>evaluate(s.input,JSON.stringify(s.decision),JSON.stringify(s.oracle),r===null?null:JSON.stringify(r));
test('clarification external-review roundtrip never authenticates reviewer or enables release',()=>{
 for(const c of inputs){const s=sample(c.id),r=run(s,c.harness.technicalState==='ok'?review(s):null);assert.equal(r.releaseAccepted,false);assert.equal(r.reviewerAuthenticated,false);assert.equal(r.harnessAuthenticated,false);assert.equal(r.semanticStatus,c.harness.technicalState==='ok'?'reviewed_match':'technical_unassessed');}
});
test('clarification no review keeps representation and action uncertainty in the denominator',()=>{
 const r=run(sample(),null);assert.equal(r.semanticStatus,'pending');assert.equal(r.reviewComplete,false);assert.equal(r.missing.lower,0);assert.equal(r.missing.upper,1);assert.equal(r.actionCounts.unreviewed,1);assert.equal(r.actionCounts.appropriate,0);
});
test('clarification binding rejects a review for another decision, oracle, or context',()=>{
 const s=sample(),r=review(s);s.decision.decisions[0].requestLabel+='変化';assert.throws(()=>run(s,r),/clarification_review_shape/);
 const t=sample(),old=review(t);t.oracle.requirements[0].rationale+='別注釈';assert.throws(()=>run(t,old),/clarification_review_shape/);
 const u=sample();u.oracle.inputHash='0'.repeat(64);assert.throws(()=>run(u,null),/clarification_review_oracle/);
});
test('clarification approved matching is independent of decision order',()=>{
 const s=sample('clarify-partial-requests');s.decision.decisions.reverse();const r=review(s);r.pairs.forEach(p=>{const good=p.decisionId.slice(1)===p.requirementId.slice(1);p.dimensions=Object.fromEntries(dims.map(k=>[k,good?'pass':'fail']));});const v=run(s,r);assert.equal(v.semanticStatus,'reviewed_match');assert.equal(v.approvedMatches,2);assert.deepEqual(v.missing,{lower:0,upper:0});
});
test('clarification fully reviewed failure is complete, not a pending success',()=>{
 const s=sample(),r=review(s);r.pairs[0].dimensions.target='fail';const v=run(s,r);assert.equal(v.semanticStatus,'mismatch_detected');assert.equal(v.reviewComplete,true);assert.deepEqual(v.missing,{lower:1,upper:1});assert.deepEqual(v.extra,{lower:1,upper:1});
});
test('clarification uncertain and unsupported representation remain explicit',()=>{
 for(const status of ['uncertain','unsupported']){const s=sample(),r=review(s);r.representability[0].status=status;const v=run(s,r);assert.equal(v.semanticStatus,status==='unsupported'?'contract_unsupported':'pending');assert.equal(v.representationCounts[status],1);}
 const s=sample(),r=review(s);r.pairs[0].dimensions.target='uncertain';const v=run(s,r);assert.equal(v.semanticStatus,'pending');assert.equal(v.possibleMatches,1);assert.equal(v.approvedMatches,0);assert.equal(v.reviewComplete,false);
});
test('clarification matching prevents duplicate decisions from satisfying one requirement twice',()=>{
 const s=sample();s.decision.decisions.push({...s.decision.decisions[0],id:'d2'});const r=review(s);r.pairs.forEach(p=>p.dimensions=Object.fromEntries(dims.map(k=>[k,'pass'])));const v=run(s,r);assert.equal(v.approvedMatches,1);assert.deepEqual(v.extra,{lower:1,upper:1});assert.equal(v.semanticStatus,'mismatch_detected');
});
test('clarification maximum matching reassigns an overlapping candidate instead of losing a requirement',()=>{
 const s=sample();s.decision.decisions.push({...s.decision.decisions[0],id:'d2'});s.oracle.requirements.push({...structuredClone(s.oracle.requirements[0]),id:'r2'});
 const r=review(s);r.pairs.forEach(p=>p.dimensions=Object.fromEntries(dims.map(k=>[k,p.decisionId==='d2'&&p.requirementId==='r2'?'fail':'pass'])));
 const v=run(s,r);assert.equal(v.approvedMatches,2);assert.equal(v.possibleMatches,2);assert.equal(v.semanticStatus,'reviewed_match');assert.deepEqual(v.missing,{lower:0,upper:0});
 assert(v.assignedPairs.some(p=>p.decisionId==='d1'&&p.requirementId==='r2'));assert(v.assignedPairs.some(p=>p.decisionId==='d2'&&p.requirementId==='r1'));
});
test('clarification rejects all-pass reviews that contradict fixed tuples or required provenance',()=>{
 const s=sample('clarify-no-history');s.decision.decisions[0].nextAction='review_required';s.decision.decisions[0].targetState='uncertain';assert.throws(()=>run(s,review(s)),/clarification_review_tuple_conflict/);
 const t=sample('clarify-one-history');t.oracle.requirements[0].requiredTargetRefs=['q','c1'];assert.throws(()=>run(t,review(t)),/clarification_review_tuple_conflict/);
});
test('clarification counts only independently judged unnecessary and missed clarifications',()=>{
 const s=sample('clarify-no-history');s.oracle.requirements[0].allowed=[{targetState:'not_required',basis:'question',evidenceState:'not_checked',nextAction:'proceed',inspectionPurpose:'none'}];s.oracle.requirements[0].requiredTargetRefs=['q'];const r=review(s);r.pairs[0].dimensions.action='fail';r.actionAssessments[0].judgment='unnecessary_clarification';const v=run(s,r);assert.equal(v.actionCounts.unnecessary_clarification,1);assert.equal(v.semanticStatus,'mismatch_detected');
 const t=sample('clarify-no-history');t.decision.decisions[0].targetState='not_required';t.decision.decisions[0].basis='question';t.decision.decisions[0].targetRefs=['q'];t.decision.decisions[0].nextAction='proceed';const a=review(t);a.pairs[0].dimensions.action='fail';a.actionAssessments[0].judgment='missed_clarification';assert.equal(run(t,a).actionCounts.missed_clarification,1);
});
test('clarification action assessments cannot conflict with actual actions or all-pass matching',()=>{
 const s=sample(),r=review(s);r.actionAssessments[0].judgment='unnecessary_clarification';assert.throws(()=>run(s,r),/clarification_review_action/);
 const t=sample('clarify-no-history'),a=review(t);a.actionAssessments[0].judgment='unnecessary_clarification';assert.throws(()=>run(t,a),/clarification_review_action_conflict/);
 const u=sample(),b=review(u);b.actionAssessments=[];const v=run(u,b);assert.equal(v.reviewComplete,false);assert.equal(v.semanticStatus,'pending');assert.equal(v.actionCounts.unreviewed,1);
});
test('clarification technical-state mismatch never becomes semantic success for zero decisions',()=>{
 const s=sample();s.decision.technicalState='failed';s.decision.decisions=[];const r=run(s,null);assert.equal(r.semanticStatus,'technical_mismatch');assert.equal(r.reviewComplete,false);assert.equal(r.missing,null);
 const t=sample('clarify-evaluator-failed');assert.equal(run(t,null).semanticStatus,'technical_unassessed');assert.throws(()=>run(t,review(t)),/clarification_review_technical_review/);
});
test('clarification malformed, oversized, duplicate and foreign reviews are rejected',()=>{
 const s=sample(),r=review(s);r.pairs.push(structuredClone(r.pairs[0]));assert.throws(()=>run(s,r),/clarification_review_shape|clarification_review_pair/);
 const t=sample(),a=review(t);a.actionAssessments.push(structuredClone(a.actionAssessments[0]));assert.throws(()=>run(t,a),/clarification_review_shape|clarification_review_action/);
 const u=sample(),b=review(u);b.pairs[0].decisionId='d9';assert.throws(()=>run(u,b),/clarification_review_pair/);
 assert.throws(()=>evaluate(s.input,JSON.stringify(s.decision),JSON.stringify(s.oracle),'x'.repeat(262145)),/clarification_review_input/);assert.throws(()=>binding(s.input),/clarification_review_arguments/);
});
