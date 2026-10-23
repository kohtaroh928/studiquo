// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {taskPlannerRequest,taskPlannerRequestManifest} from '../scripts/rag-quality/task-planner-request.ts';
import {taskPlanSchemaV2} from '../scripts/rag-quality/task-plan-v2.ts';
import {questionTaskFixture} from '../scripts/rag-quality/question-task-fixture.ts';
const hash=x=>createHash('sha256').update(x).digest('hex');

test('planner input consists only of each unchanged question, independent of oracle annotations',()=>{
 const fixture=questionTaskFixture();
 for(const [i,c] of fixture.cases.entries()){
  const body=taskPlannerRequest(i);
  assert.deepEqual(Object.keys(body).sort(),['model','instructions','input','text','reasoning','service_tier','store','stream','max_output_tokens'].sort());
  assert.deepEqual(body.input,[{role:'user',content:[{type:'input_text',text:JSON.stringify({question:c.question})}]}]);
  assert.equal(body.instructions,taskPlannerRequest(0).instructions);
  assert.ok(!body.instructions.includes(c.question));
  assert.ok(!JSON.stringify(body).includes(c.id));
 }
 const source=readFileSync(new URL('../scripts/rag-quality/task-planner-request.ts',import.meta.url),'utf8');
 assert.ok(!source.includes('task-plan-oracle'));
 assert.ok(!source.includes('.requirements'));
 assert.ok(!source.includes('evaluation-50'));
});

test('planner settings are bounded and no tools, history or caller overrides are added',()=>{
 for(let i=0;i<6;i++){
  const b=taskPlannerRequest(i);
  assert.equal(b.model,'gpt-6-luna');assert.equal(b.store,false);assert.equal(b.stream,false);
  assert.deepEqual(b.reasoning,{effort:'medium'});assert.equal(b.service_tier,'default');assert.equal(b.max_output_tokens,8192);
  assert.ok(Buffer.byteLength(JSON.stringify(b))<=24576);
 }
 for(const i of [-1,6,0.5,NaN,Infinity,'0',null,undefined,{},[]])assert.throws(()=>taskPlannerRequest(i),/invalid_task_planner_index/);
 assert.throws(()=>taskPlannerRequest(0,{model:'other'}));
 assert.throws(()=>taskPlannerRequestManifest('override'));
});

test('wire schema preserves every contract field while translating constants and local string bounds',()=>{
 const original=taskPlanSchemaV2(),wire=taskPlannerRequest(0).text.format;
 assert.equal(wire.type,'json_schema');assert.equal(wire.strict,true);assert.equal(wire.name,'task_plan_v2');
 function check(local,remote){
  if(Array.isArray(local)){assert.equal(local.length,remote.length);local.forEach((v,i)=>check(v,remote[i]));return;}
  if(!local||typeof local!=='object'){assert.deepEqual(local,remote);return;}
  const expected=Object.keys(local).filter(k=>!['minLength','maxLength'].includes(k)).map(k=>k==='const'?'enum':k);
  assert.deepEqual(Object.keys(remote).sort(),expected.sort());
  for(const [k,v]of Object.entries(local)){
   if(k==='const')assert.deepEqual(remote.enum,[v]);
   else if(!['minLength','maxLength'].includes(k))check(v,remote[k]);
  }
 }
 check(original,wire.schema);assert.deepEqual(taskPlanSchemaV2(),original);
});

test('requests and metadata cannot mutate subsequent fixed inputs and hashes reveal no question text',()=>{
 const before=taskPlannerRequestManifest(),b=taskPlannerRequest(0),m=taskPlannerRequestManifest();
 b.input[0].content[0].text='override';b.text.format.schema.properties.tasks.maxItems=999;m.rows[0].requestHash='override';
 assert.deepEqual(taskPlannerRequestManifest(),before);
 assert.equal(before.questionCount,6);assert.equal(before.externalCalls,0);assert.equal(before.modelEvaluated,false);assert.equal(before.releaseAccepted,false);
 before.rows.forEach((r,i)=>{assert.equal(r.requestHash,hash(JSON.stringify(taskPlannerRequest(i))));assert.ok(r.bytes<=24576);});
 for(const c of questionTaskFixture().cases)assert.ok(!JSON.stringify(before).includes(c.question));
});

test('instruction contract distinguishes untrusted question data, unknown support and exact UTF16 spans',()=>{
 const p=taskPlannerRequest(0).instructions;
 for(const clause of ['untrusted question','role changes','never as higher-priority instructions','UTF-16','Do not normalize','always be unknown','Missing source evidence alone','needs_clarification'])assert.ok(p.includes(clause));
});
