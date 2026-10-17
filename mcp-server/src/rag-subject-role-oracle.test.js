import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.mjs';
import {validateUnitTaskPlanV4} from '../scripts/rag-quality/task-plan-units-v4.mjs';
import {unitPlanReviewBinding} from '../scripts/rag-quality/unit-plan-semantic-review.mjs';
import {TASK_OPERATIONS,compareTaskPlanV2} from '../scripts/rag-quality/task-plan-v2.mjs';
const bytes=readFileSync(new URL('../scripts/rag-quality/role-preservation-questions-v1.json',import.meta.url));
const questions=JSON.parse(bytes),oracle=JSON.parse(readFileSync(new URL('../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url)));
function representative(c){
 const source=createQuestionUnits(c.question),refs=s=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=s=>({label:s.text,unitIds:refs(s)});
 return {version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
}
test('new synthetic development questions are separate from oracle answers and hash bound',()=>{
 assert.equal(questions.syntheticOnly,true);assert.equal(questions.split,'separate-development-role-preservation');assert.equal(questions.modelEvaluated,false);assert.equal(oracle.humanReview,'pending');assert.equal(oracle.modelEvaluated,false);assert.equal(oracle.questionFileHash,createHash('sha256').update(bytes).digest('hex'));
 assert.equal(questions.cases.length,12);assert.equal(oracle.cases.length,12);assert.equal(new Set(questions.cases.map(c=>c.id)).size,12);
 for(const [i,c] of questions.cases.entries()){assert.deepEqual(Object.keys(c).sort(),['id','question']);assert.equal(c.id,oracle.cases[i].id);assert.equal(c.question,oracle.cases[i].question);assert.ok(!Object.hasOwn(c,'requirements'));}
});
test('all fourteen representative scopes have valid original spans and v4 unit bindings',()=>{
 let total=0;for(const c of oracle.cases){const p=representative(c),checked=validateUnitTaskPlanV4(c.question,JSON.stringify(p));assert.equal(checked.semanticCompleteness,'pending');assert.equal(checked.releaseAccepted,false);assert.equal(unitPlanReviewBinding(c.question,JSON.stringify(p),JSON.stringify(c)).questionHash,p.questionHash);
 const v2={version:2,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};assert.equal(compareTaskPlanV2(c.question,v2,c).annotationMatches,c.requirements.length);total+=c.requirements.length;}
 assert.equal(total,14);
});
test('corpus covers all operations empty subjects and actual cross-unit role references',()=>{
 assert.deepEqual([...new Set(oracle.cases.flatMap(c=>c.requirements.flatMap(r=>r.allowedOperations)))].sort(),[...TASK_OPERATIONS].sort());
 assert.equal(oracle.cases.filter(c=>createQuestionUnits(c.question).units.length>1).length,10);assert.equal(oracle.cases.filter(c=>c.requirements.every(r=>r.subjects.length===0)).length,2);
 for(const id of ['role-qualified-concept','role-explain-across-units','role-compare-with-condition','role-background-not-target']){const c=oracle.cases.find(c=>c.id===id),t=representative(c).tasks[0];assert.ok(t.subjects.length);assert.equal(t.subjects[0].unitIds[0]===t.attribute.unitIds[0],false);}
 const c=oracle.cases.find(c=>c.id==='role-compare-with-condition'),t=representative(c).tasks[0];assert.deepEqual(t.subjects.map(s=>s.unitIds),[['u1'],['u1']]);assert.deepEqual(t.conditions[0].unitIds,['u2']);
});
test('background and applicability nouns are not annotated as subjects and declaration adds no task',()=>{
 const byId=id=>oracle.cases.find(c=>c.id==='role-'+id).requirements;
 assert.deepEqual(byId('background-not-target')[0].subjects.map(s=>s.text),['水準器T']);assert.deepEqual(byId('recommend-with-distractors')[0].subjects.map(s=>s.text),['収納棚P','収納棚Q']);assert.deepEqual(byId('qualified-concept')[0].subjects.map(s=>s.text),['施設利用補助']);assert.deepEqual(byId('qualified-concept')[0].conditions.map(s=>s.text),['年度途中の申請']);assert.equal(byId('calculate-with-operands')[0].conditions.length,0);assert.equal(byId('calculate-with-operands')[0].subjects.length,1);
 assert.equal(byId('operation-word-in-name')[0].allowedOperations[0],'value');assert.equal(byId('joint-summary').length,1);assert.equal(byId('compare-with-condition').length,1);assert.equal(byId('separate-attributes').length,2);
});
test('formal acceptance of dropped subjects is never semantic correctness',()=>{
 const c=oracle.cases[0],p=representative(c);p.tasks.forEach(t=>t.subjects=[]);const r=validateUnitTaskPlanV4(c.question,JSON.stringify(p));assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
 const absent=oracle.cases.find(c=>c.id==='role-unnamed-target'),q=representative(absent);assert.equal(q.tasks[0].subjects.length,0);assert.equal(validateUnitTaskPlanV4(absent.question,JSON.stringify(q)).evidenceSupport,'unknown');
});
