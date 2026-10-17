import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parsePairedTaskPlannerResponse} from '../scripts/rag-quality/paired-task-planner-response.mjs';
import {pairedTaskPlannerManifest} from '../scripts/rag-quality/paired-task-planner-request.mjs';
import {parseTaskPlannerResponse} from '../scripts/rag-quality/task-planner-response.mjs';
const oracle=JSON.parse(readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
function sample(index=0){
 const c=oracle.cases[index],plan={version:2,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:20}}};
}
const parse=(r,index=0,variant='baseline')=>parsePairedTaskPlannerResponse(index,variant,JSON.stringify(r));
test('all sixteen mock completions bind to the selected paired question and expected request hash',()=>{
 for(const row of pairedTaskPlannerManifest().rows){
  const r=parse(sample(row.index),row.index,row.variant);
  assert.equal(r.index,row.index);assert.equal(r.variant,row.variant);assert.equal(r.requestHash,row.requestHash);
  assert.equal(r.plan.tasks.length,oracle.cases[row.index].requirements.length);
  assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
 }
 assert.throws(()=>parse(sample(0),2));
 assert.throws(()=>parseTaskPlannerResponse(0,JSON.stringify(sample(0))));
});
test('variant distinguishes expected requests without pretending to attest to the upstream dispatch',()=>{
 const raw=JSON.stringify(sample(0)),a=parsePairedTaskPlannerResponse(0,'baseline',raw),b=parsePairedTaskPlannerResponse(0,'candidate',raw);
 assert.deepEqual(a.plan,b.plan);assert.equal(a.responseHash,b.responseHash);assert.notEqual(a.requestHash,b.requestHash);
});
test('indices variants and argument count cannot select arbitrary questions or settings',()=>{
 for(const i of [-1,8,'0',null,0.5,NaN])assert.throws(()=>parse(sample(),i));
 for(const v of ['other',undefined,{},null])assert.throws(()=>parsePairedTaskPlannerResponse(0,v,JSON.stringify(sample())));
 assert.throws(()=>parsePairedTaskPlannerResponse(0,'baseline',JSON.stringify(sample()),{}));
});
test('old and paired parsers agree on shared envelope usage and refusal failures with fixed errors',()=>{
 const mutations=[r=>r.status='incomplete',r=>r.error={message:'synthetic private detail'},r=>r.incomplete_details={},r=>r.model='other',r=>r.usage.total_tokens++,r=>r.usage.input_tokens=32769,r=>r.usage.output_tokens=8193,r=>r.usage.output_tokens_details.reasoning_tokens=201,r=>r.usage.input_tokens_details={new_cache_field:0},r=>r.output.push({type:'function_call'}),r=>r.output.push(structuredClone(r.output[0])),r=>r.output[0].content=[{type:'refusal',refusal:'synthetic detail'}],r=>r.output[0].status='in_progress'];
 for(const mutation of mutations){
  const r=sample();mutation(r);let old,newError;
  try{parseTaskPlannerResponse(0,JSON.stringify(r));}catch(e){old=e;}
  try{parse(r);}catch(e){newError=e;}
  assert.ok(old&&newError);assert.equal(old.message,newError.message);assert.ok(!newError.message.includes('synthetic'));
 }
});
test('byte limits and JSON parsing errors never include raw details or normalize code fences',()=>{
 for(const raw of ['',null,'{synthetic detail','あ'.repeat(87382)])assert.throws(()=>parsePairedTaskPlannerResponse(0,'baseline',raw),e=>e.message.startsWith('task_planner_')&&!e.message.includes('synthetic'));
 const r=sample();r.output[0].content[0].text='x'.repeat(32769);assert.throws(()=>parse(r),/plan_size/);
 r.output[0].content[0].text='```json\n{}\n```';assert.throws(()=>parse(r),/plan_json/);
});
test('wrong offsets and forged support are rejected without correcting the plan',()=>{
 for(const f of [p=>p.tasks[0].attribute.start++,p=>p.tasks[0].attribute.text='synthetic',p=>p.tasks[0].evidenceSupport='supported',p=>p.tasks[0].comparisonPermission='allowed']){
  const r=sample(),p=JSON.parse(r.output[0].content[0].text);f(p);r.output[0].content[0].text=JSON.stringify(p);assert.throws(()=>parse(r),/invalid_plan/);
 }
});
test('shape validation deliberately leaves semantic role mistakes pending and returns isolated plans',()=>{
 const r=sample(),p=JSON.parse(r.output[0].content[0].text);
 p.tasks[0].subjects=p.tasks[1].subjects;r.output[0].content[0].text=JSON.stringify(p);
 const accepted=parse(r);assert.equal(accepted.semanticCompleteness,'pending');assert.equal(accepted.releaseAccepted,false);
 accepted.plan.tasks[0].attribute.text='synthetic change';assert.notEqual(parse(r).plan.tasks[0].attribute.text,'synthetic change');
});
