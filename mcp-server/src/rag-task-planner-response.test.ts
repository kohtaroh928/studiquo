// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {parseTaskPlannerResponse} from '../scripts/rag-quality/task-planner-response.ts';
import {taskPlanOracleV2} from '../scripts/rag-quality/task-plan-oracle-v2.ts';
import {taskPlannerRequestManifest} from '../scripts/rag-quality/task-planner-request.ts';
const clone=structuredClone;
function sample(index=0){
 const c=taskPlanOracleV2().cases[index];
 const plan={version:2,status:'candidate',tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],
  attribute:clone(r.attribute),subjects:clone(r.subjects),conditions:clone(r.conditions),requestSpans:clone(r.requestSpans),
  resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'})),unresolved:[]};
 return {object:'response',model:'gpt-6-luna',status:'completed',error:null,incomplete_details:null,
  output:[{type:'reasoning',summary:[]},{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],
  usage:{input_tokens:100,output_tokens:80,total_tokens:180,output_tokens_details:{reasoning_tokens:20},input_tokens_details:{cached_tokens:10,cache_write_tokens:5}}};
}
const parse=(r,i=0)=>parseTaskPlannerResponse(i,JSON.stringify(r));

test('completed mocked plans bind to each fixed question without claiming semantic correctness',()=>{
 for(let i=0;i<6;i++){
  const r=parse(sample(i),i);assert.equal(r.plan.tasks.length,taskPlanOracleV2().cases[i].requirements.length);
  assert.equal(r.requestHash,taskPlannerRequestManifest().rows[i].requestHash);
  assert.deepEqual(r.usage,{input:100,output:80,total:180,reasoning:20,cached:10,cacheWrite:5});
  assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
 }
 assert.throws(()=>parse(sample(0),1),/invalid_plan/);
});
test('incomplete, failed, wrong model and nonassistant responses cannot be completed',()=>{
 const changes=[r=>r.status='incomplete',r=>r.status='failed',r=>r.error={message:'synthetic secret'},r=>r.incomplete_details={},
  r=>delete r.error,r=>r.model='other',r=>r.object='chat.completion',r=>r.output[1].status='in_progress',
  r=>r.output[0].status='incomplete',r=>r.output[1].role='user'];
 for(const f of changes){const r=sample();f(r);assert.throws(()=>parse(r),e=>e.message.startsWith('task_planner_')&&!e.message.includes('synthetic secret'));}
});
test('refusal, tools, mixed content and duplicate messages fail closed',()=>{
 for(const f of [r=>r.output[1].content=[{type:'refusal',refusal:'synthetic refusal'}],
  r=>r.output[1].content.push({type:'refusal',refusal:'synthetic refusal'}),
  r=>r.output.push({type:'function_call',name:'delete'}),r=>r.output.push(clone(r.output[1])),
  r=>r.output[1].content.push(clone(r.output[1].content[0])),r=>r.output=[],r=>r.output[1].content=[],r=>r.output=[null]]){
  const r=sample();f(r);assert.throws(()=>parse(r),/^Error: task_planner_/);
 }
});
test('missing usage, unsafe integers, totals and reservation overruns fail closed',()=>{
 for(const f of [r=>r.usage=null,r=>r.usage.total_tokens++,r=>r.usage.input_tokens=-1,r=>r.usage.output_tokens=0.5,
  r=>r.usage.input_tokens=Number.MAX_SAFE_INTEGER+1,r=>r.usage.output_tokens_details.reasoning_tokens=81,
  r=>delete r.usage.output_tokens_details,r=>r.usage.input_tokens_details.cached_tokens=101,
  r=>r.usage.input_tokens_details.unknown_cache_count=0,
  r=>r.usage.input_tokens_details.cache_write_tokens=95,
  r=>{r.usage.input_tokens=32769;r.usage.total_tokens=32849;},r=>{r.usage.output_tokens=8193;r.usage.total_tokens=8293;}]){
  const r=sample();f(r);assert.throws(()=>parse(r),/invalid_usage/);
 }
 const r=sample();delete r.usage.input_tokens_details;assert.equal(parse(r).usage.cached,null);
});
test('raw and plan byte limits and malformed JSON return only fixed errors',()=>{
 for(const raw of ['',null,'{bad','x'.repeat(262145),'あ'.repeat(87382)])assert.throws(()=>parseTaskPlannerResponse(0,raw),/^Error: task_planner_/);
 const r=sample();r.output[1].content[0].text='x'.repeat(32769);assert.throws(()=>parse(r),/plan_size/);
 r.output[1].content[0].text='```json\n{}\n```';assert.throws(()=>parse(r),/plan_json/);
 assert.throws(()=>parseTaskPlannerResponse(0,JSON.stringify(sample()),{}),/invalid_arguments/);
});
test('forged offsets, changed quotes and evidence claims are not repaired into valid plans',()=>{
 for(const f of [p=>p.tasks[0].attribute.start++,p=>p.tasks[0].attribute.text='synthetic replacement',
  p=>{p.tasks[1].attribute.start*=3;p.tasks[1].attribute.end*=3;},
  p=>p.tasks[0].evidenceSupport='supported',p=>p.tasks[0].comparisonPermission='allowed',p=>p.tasks[0].resolution='retrieved',
  p=>p.status='needs_clarification',p=>p.tasks[0].extra='synthetic']){
  const r=sample(),p=JSON.parse(r.output[1].content[0].text);f(p);r.output[1].content[0].text=JSON.stringify(p);
  assert.throws(()=>parse(r),/invalid_plan/);
 }
});
test('reasoning status and returned plan ownership remain explicit',()=>{
 const r=sample();r.output[0].status=null;assert.throws(()=>parse(r),/invalid_output/);
 r.output[0].status='completed';assert.equal(parse(r).plan.version,2);
 const result=parse(r);result.plan.tasks[0].attribute.text='synthetic mutation';
 assert.notEqual(parse(r).plan.tasks[0].attribute.text,'synthetic mutation');
});
