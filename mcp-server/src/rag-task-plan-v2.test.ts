import test from 'node:test';
import assert from 'node:assert/strict';
import {taskPlanSchemaV2,validateTaskPlanV2,compareTaskPlanV2} from '../scripts/rag-quality/task-plan-v2.ts';
import {taskPlanOracleV2} from '../scripts/rag-quality/task-plan-oracle-v2.ts';
import {questionTaskFixture} from '../scripts/rag-quality/question-task-fixture.ts';
const clone=structuredClone;
const planFor=c=>({version:2,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],
 attribute:clone(r.attribute),subjects:clone(r.subjects),conditions:clone(r.conditions),requestSpans:clone(r.requestSpans),
 resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))});

test('v2 oracle keeps v1 questions and separates operations, subjects, attributes and conditions',()=>{
 const f=taskPlanOracleV2();assert.equal(f.cases.length,6);assert.equal(f.humanReview,'pending');
 const v1=questionTaskFixture();
 for(const c of f.cases){
  assert.equal(c.question,v1.cases.find(x=>x.id===c.id).question);
  const plan=planFor(c);assert.deepEqual(validateTaskPlanV2(c.question,plan),plan);
  const r=compareTaskPlanV2(c.question,plan,c);assert.equal(r.annotationMatches,c.requirements.length);
  assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
 }
 assert.ok(f.cases.find(c=>c.id==='task-learning').requirements.every(r=>r.allowedOperations[0]==='explain'));
});

test('ambiguous value versus calculation labels are allowed without asserting evidence support',()=>{
 const c=taskPlanOracleV2().cases.find(c=>c.id==='task-calculation'),p=planFor(c);
 p.tasks[1].operation='calculate';const r=compareTaskPlanV2(c.question,p,c);
 assert.equal(r.annotationMatches,2);assert.equal(r.ambiguousMatches,1);assert.equal(r.evidenceSupport,'unknown');
});

test('missing, duplicate and broadly merged attributes cannot masquerade as complete atomic annotation',()=>{
 const c=taskPlanOracleV2().cases[0],p=planFor(c);p.tasks.pop();
 assert.equal(compareTaskPlanV2(c.question,p,c).missingAnnotationIds.length,1);
 const d=planFor(c);d.tasks[1]={...clone(d.tasks[0]),id:'t2'};
 const r=compareTaskPlanV2(c.question,d,c);assert.equal(r.annotationMatches,2);assert.equal(r.extraTaskIds.length,1);
 const b=planFor(c);b.tasks[0].attribute={start:0,end:9,text:c.question.slice(0,9)};
 assert.equal(compareTaskPlanV2(c.question,b,c).annotationMatches,2);
});

test('subject and condition mismatches are not hidden by identical operation sets',()=>{
 const c=taskPlanOracleV2().cases[1],p=planFor(c);p.tasks[1].conditions=[];
 assert.equal(compareTaskPlanV2(c.question,p,c).annotationMatches,1);
 p.tasks[0].subjects.pop();assert.equal(compareTaskPlanV2(c.question,p,c).annotationMatches,0);
 assert.throws(()=>compareTaskPlanV2(c.question,p,{...c,question:'different'}));
});

test('unrelated request spans and dropped student eligibility subject cannot receive annotation credit',()=>{
 const c=taskPlanOracleV2().cases[0],p=planFor(c);
 p.tasks.forEach(t=>t.requestSpans=[clone(c.requirements[0].attribute)]);
 assert.equal(compareTaskPlanV2(c.question,p,c).annotationMatches,0);
 const missing=planFor(c);missing.tasks[2].subjects=[];
 assert.equal(compareTaskPlanV2(c.question,missing,c).annotationMatches,2);
 const actual=c.requirements[2].subjects[0];
 assert.equal(actual.start,c.question.lastIndexOf('学生料金'));
});

test('shape validation rejects forged provenance, permissions, extra fields and malformed bounds',()=>{
 const c=taskPlanOracleV2().cases[0],base=planFor(c);
 for(const change of [
  p=>p.tasks[0].attribute.text='invented',p=>p.tasks[0].attribute.start=-1,
  p=>p.tasks[0].evidenceSupport='supported',p=>p.tasks[0].resolution='retrieved',p=>p.tasks[0].comparisonPermission='allowed',
  p=>p.tasks[0].system='override',p=>p.tasks[0].operation='delete',p=>p.tasks[1].id=p.tasks[0].id,
  p=>p.tasks[0].requestSpans=[],p=>p.tasks[0].subjects=[p.tasks[0].attribute,p.tasks[0].attribute],
  p=>p.tasks=Array.from({length:17},()=>clone(p.tasks[0])),p=>p.secret='key',
 ]){const p=clone(base);change(p);assert.throws(()=>validateTaskPlanV2(c.question,p),/invalid_task_plan_v2/);}
 assert.throws(()=>validateTaskPlanV2('x'.repeat(16385),base));
 const a=taskPlanSchemaV2();a.properties.tasks.maxItems=999;assert.equal(taskPlanSchemaV2().properties.tasks.maxItems,16);
});

test('unrecognized syntax and referent ambiguity stay distinct from unknown retrieval support',()=>{
 const q='それを説明して。',s={start:0,end:2,text:'それ'};
 const p={version:2,status:'needs_clarification',tasks:[],unresolved:[{kind:'reference',span:s}]};
 assert.deepEqual(validateTaskPlanV2(q,p),p);
 assert.throws(()=>validateTaskPlanV2(q,{...p,status:'candidate'}));
 const unknown={version:2,status:'unrecognized',tasks:[],unresolved:[{kind:'syntax',span:s}]};
 assert.deepEqual(validateTaskPlanV2(q,unknown),unknown);
 assert.throws(()=>validateTaskPlanV2(q,{...unknown,unresolved:[]}));
});
