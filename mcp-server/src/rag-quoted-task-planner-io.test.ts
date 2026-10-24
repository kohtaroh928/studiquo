// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {quotedTaskPlannerRequest as request,quotedTaskPlannerManifest as manifest} from '../scripts/rag-quality/quoted-task-planner-request.ts';
import {pairedTaskPlannerRequest} from '../scripts/rag-quality/paired-task-planner-request.ts';
import {parseQuotedTaskPlannerResponse as parse} from '../scripts/rag-quality/quoted-task-planner-response.ts';
const oracle=JSON.parse(readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
const hash=x=>createHash('sha256').update(x).digest('hex');
function sample(index=0){
 const c=oracle.cases[index],quote=s=>({text:s.text,prefix:c.question.slice(Math.max(0,s.start-128),s.start),suffix:c.question.slice(s.end,s.end+128)});
 const plan={version:3,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:quote(r.attribute),subjects:r.subjects.map(quote),conditions:r.conditions.map(quote),requestSpans:r.requestSpans.map(quote),resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:20}}};
}
const run=(r,index=0)=>parse(index,JSON.stringify(r));
const mutate=(r,fn)=>{const p=JSON.parse(r.output[0].content[0].text);fn(p);r.output[0].content[0].text=JSON.stringify(p);return r;};
const failure=(r,code)=>assert.throws(()=>run(r),e=>e.message==='quoted_task_planner_'+code&&!e.message.includes('private'));
test('v3 requests preserve candidate questions scope rules and settings without oracle payload',()=>{
 const m=manifest();assert.equal(m.contractVersion,3);assert.equal(m.questionCount,8);assert.equal(m.modelEvaluated,false);
 for(let i=0;i<8;i++){
  const parent=pairedTaskPlannerRequest(i,'candidate'),body=request(i),row=m.rows[i];
  assert.deepEqual(body.input,parent.input);assert.deepEqual(JSON.parse(body.input[0].content[0].text),{question:oracle.cases[i].question});
  assert.deepEqual({...body,instructions:null,text:null},{...parent,instructions:null,text:null});
  assert.equal(body.instructions.split('Additional scope annotation rules:')[1],parent.instructions.split('Additional scope annotation rules:')[1]);
  assert.match(body.instructions,/Return TaskPlan v3 only/);assert.match(body.instructions,/never choose the first occurrence/);assert.doesNotMatch(body.instructions,/TaskPlan v2|zero-based|start inclusive|end exclusive/);
  assert.equal(row.parentCandidateRequestHash,hash(JSON.stringify(parent)));assert.equal(row.requestHash,hash(JSON.stringify(body)));assert.ok(row.bytes<=24576);
  assert.equal(body.model,'gpt-6-luna');assert.deepEqual(body.reasoning,{effort:'medium'});assert.equal(body.store,false);assert.equal(body.max_output_tokens,8192);
  assert.equal(body.text.format.name,'task_plan_quoted_v3');assert.deepEqual(body.text.format.schema.properties.version.enum,[3]);assert.equal(body.text.format.strict,true);
  function objects(node){if(!node||typeof node!=='object')return;if(node.type==='object'){assert.equal(node.additionalProperties,false);assert.deepEqual([...node.required].sort(),Object.keys(node.properties).sort());}for(const value of Object.values(node))objects(value);}objects(body.text.format.schema);
 }
 assert.ok(!JSON.stringify(m).includes(oracle.cases[0].question));assert.equal(m.externalCalls,0);
});
test('selectors and isolated factory results cannot override evaluation or mutate future bodies',()=>{
 for(const i of [-1,8,'0',0.5,null,{},undefined])assert.throws(()=>request(i));assert.throws(()=>request(0,{}));assert.throws(()=>manifest({}));
 const before=JSON.stringify(request(0)),b=request(0);b.instructions='changed';b.text.format.schema.properties.version.enum[0]=4;assert.equal(JSON.stringify(request(0)),before);
});
test('eight mock responses bind original quotes and thirteen resolved oracle scopes to selected questions',()=>{
 let count=0;for(let i=0;i<8;i++){
  const raw=JSON.stringify(sample(i)),r=parse(i,raw);assert.equal(r.index,i);assert.equal(r.contractVersion,3);assert.equal(r.quotedPlan.version,3);assert.equal(r.plan.version,2);
  assert.equal(r.requestHash,hash(JSON.stringify(request(i))));assert.equal(r.responseHash,hash(raw));assert.equal(r.semanticCompleteness,'pending');assert.equal(r.releaseAccepted,false);
  for(const [j,t] of r.plan.tasks.entries())for(const k of ['attribute','subjects','conditions','requestSpans'])assert.deepEqual(t[k],oracle.cases[i].requirements[j][k]);count+=r.plan.tasks.length;
 }
 assert.equal(count,13);assert.throws(()=>run(sample(0),1));assert.throws(()=>parse(0,JSON.stringify(sample()),{}));
});
test('returned quotes resolved positions and fresh parsing are independent',()=>{
 const input=sample(),before=JSON.stringify(input),a=run(input),b=run(input);a.quotedPlan.tasks[0].attribute.text='changed';assert.notEqual(a.plan.tasks[0].attribute.text,'changed');a.plan.tasks[0].attribute.text='changed2';assert.notEqual(b.plan.tasks[0].attribute.text,'changed2');assert.equal(JSON.stringify(input),before);
});
test('old v2 ambiguous quotes absent context and forged support reject distinctly without raw text',()=>{
 failure(mutate(sample(),p=>p.version=2),'shape');
 failure(mutate(sample(),p=>{p.tasks[0].attribute.prefix='';p.tasks[0].attribute.suffix='';}),'quote_ambiguous');
 failure(mutate(sample(),p=>p.tasks[0].attribute.prefix='synthetic_private_detail'),'quote_not_found');
 failure(mutate(sample(),p=>p.tasks[0].attribute.start=0),'quote_shape');
 failure(mutate(sample(),p=>p.tasks[0].evidenceSupport='supported'),'invalid_plan');
 failure(mutate(sample(),p=>p.tasks[0].subjects[0].text='synthetic_private_detail'),'quote_not_found');
});
test('incomplete envelope refusals multiple messages and unknown items fail closed',()=>{
 for(const fn of [r=>r.status='incomplete',r=>r.error={message:'synthetic_private_detail'},r=>r.incomplete_details={},r=>r.object='other']){const r=sample();fn(r);failure(r,'not_completed');}
 const wrong=sample();wrong.model='other';failure(wrong,'model_mismatch');
 const multi=sample();multi.output.push(structuredClone(multi.output[0]));failure(multi,'invalid_output');
 const tool=sample();tool.output.push({type:'function_call'});failure(tool,'unexpected_output');
 const refusal=sample();refusal.output[0].content=[{type:'refusal',refusal:'synthetic_private_detail'}];failure(refusal,'refused');
 const extra=sample();extra.output[0].content.push({type:'output_text',text:'synthetic_private_detail'});failure(extra,'invalid_output');
 const reasoning=sample();reasoning.output.unshift({type:'reasoning'});assert.equal(run(reasoning).usage.reasoning,20);reasoning.output[0].status=null;failure(reasoning,'invalid_output');
});
test('usage bounds and cache fields are validated without treating missing details as zero',()=>{
 assert.deepEqual(run(sample()).usage,{input:100,output:200,total:300,reasoning:20,cached:null,cacheWrite:null});
 const valid=sample();valid.usage.input_tokens_details={cached_tokens:10,cache_write_tokens:20};assert.equal(run(valid).usage.cached,10);assert.equal(run(valid).usage.cacheWrite,20);
 for(const change of [u=>u.total_tokens++,u=>u.input_tokens=32769,u=>u.output_tokens=8193,u=>u.output_tokens_details.reasoning_tokens=201,u=>u.input_tokens=-1,u=>u.input_tokens_details={private:0},u=>u.input_tokens_details={cached_tokens:80,cache_write_tokens:80}]){const r=sample();change(r.usage);failure(r,'invalid_usage');}
});
test('raw and plan byte limits JSON failures and fences reject without echo or repair',()=>{
 for(const raw of ['',null,'x'.repeat(262145)])assert.throws(()=>parse(0,raw),/quoted_task_planner_response_size/);
 assert.throws(()=>parse(0,'{synthetic_private_detail'),e=>e.message==='quoted_task_planner_response_json');
 const r=sample();r.output[0].content[0].text='あ'.repeat(10923);failure(r,'plan_size');r.output[0].content[0].text='```json\n{}\n```';failure(r,'plan_json');
});
test('exact provenance leaves semantically wrong role selections pending',()=>{
 const r=sample();mutate(r,p=>p.tasks[0].subjects=p.tasks[1].subjects);const result=run(r);assert.equal(result.semanticCompleteness,'pending');assert.equal(result.releaseAccepted,false);
});
