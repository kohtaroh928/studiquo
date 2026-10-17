import test from 'node:test';
import assert from 'node:assert/strict';
import {diagnoseTaskPlan,safeTaskPlanDiagnostic} from '../scripts/rag-quality/task-plan-diagnostic.mjs';
import {validateTaskPlanV2} from '../scripts/rag-quality/task-plan-v2.mjs';
const question='容量は何人ですか';
const span={start:0,end:2,text:'容量'};
const sample=()=>({version:2,status:'candidate',unresolved:[],tasks:[{id:'t1',operation:'value',attribute:{...span},subjects:[],conditions:[],requestSpans:[{...span}],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}]});
test('fixed diagnostic categories preserve authoritative rejection and never repair input',()=>{
 const cases=[['root_fields',p=>p.extra='private'],['root_values',p=>p.status='other'],['task_fields',p=>delete p.tasks[0].id],['id_invalid',p=>p.tasks[0].id='bad'],['id_duplicate',p=>p.tasks.push(structuredClone(p.tasks[0]))],['operation_invalid',p=>p.tasks[0].operation='bad'],['permission_not_unknown',p=>p.tasks[0].resolution='yes'],['span_fields',p=>p.tasks[0].attribute.extra=0],['span_bounds',p=>p.tasks[0].attribute.end=999],['span_text',p=>p.tasks[0].attribute.text=''],['span_quote_mismatch',p=>p.tasks[0].attribute.start=1],['span_list_bounds',p=>p.tasks[0].requestSpans=[]],['span_duplicate',p=>p.tasks[0].subjects=[{...span},{...span}]],['unresolved_fields',p=>p.unresolved=[{}]],['status_reference_conflict',p=>p.status='needs_clarification'],['candidate_without_tasks',p=>p.tasks=[]],['unrecognized_status_conflict',p=>p.status='unrecognized']];
 for(const [code,mutate] of cases){const p=sample();mutate(p);const before=JSON.stringify(p);assert.throws(()=>validateTaskPlanV2(question,p));const d=diagnoseTaskPlan(question,p);assert.equal(d.code,code);assert.deepEqual(safeTaskPlanDiagnostic(d),d);assert.equal(JSON.stringify(p),before);assert.ok(!JSON.stringify(d).includes('容量'));}
 assert.equal(diagnoseTaskPlan(question,sample()),null);
 assert.equal(diagnoseTaskPlan('',sample()).code,'question_shape');
 const cycle={};cycle.self=cycle;assert.equal(diagnoseTaskPlan(question,cycle).code,'plan_size_or_json');
 assert.equal(diagnoseTaskPlan(question,{...sample(),tasks:Array(10000)}).code,'plan_size_or_json');
 assert.equal(diagnoseTaskPlan(question,new Proxy({},{ownKeys(){throw Error('private');}})).code,'plan_size_or_json');
 const p=sample();p.tasks[0].id='bad';p.tasks[0].attribute.end=999;assert.equal(diagnoseTaskPlan(question,p).code,'id_invalid');
});
test('diagnostic metadata cannot carry arbitrary fields values or indices',()=>{
 const d={code:'span_quote_mismatch',role:'attribute',taskIndex:0,spanIndex:-1};
 for(const x of [{...d,text:'private'},{...d,code:'private'},{...d,role:'private'},{...d,taskIndex:16},{...d,spanIndex:8},{...d,taskIndex:0.5},null])assert.equal(safeTaskPlanDiagnostic(x),null);
 const safe=safeTaskPlanDiagnostic(d);safe.code='changed';assert.equal(d.code,'span_quote_mismatch');
});
