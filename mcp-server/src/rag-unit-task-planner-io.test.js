import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {unitTaskPlannerRequest as request,unitTaskPlannerManifest as manifest} from '../scripts/rag-quality/unit-task-planner-request.mjs';
import {pairedTaskPlannerRequest} from '../scripts/rag-quality/paired-task-planner-request.mjs';
import {parseUnitTaskPlannerResponse as parse} from '../scripts/rag-quality/unit-task-planner-response.mjs';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.mjs';
const oracle=JSON.parse(readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
const hash=x=>createHash('sha256').update(x).digest('hex');
function sample(index=0){
 const c=oracle.cases[index],source=createQuestionUnits(c.question),refs=s=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=s=>({label:s.text,unitIds:refs(s)});
 const plan={version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:20}}};
}
const run=(r,index=0)=>parse(index,JSON.stringify(r));
const mutate=(r,fn)=>{const p=JSON.parse(r.output[0].content[0].text);fn(p);r.output[0].content[0].text=JSON.stringify(p);return r;};
const failure=(r,code)=>assert.throws(()=>run(r),e=>e.message==='unit_task_planner_'+code&&!e.message.includes('private'));
test('v4 requests retain fixed questions and parent scope rules with question-only structural units',()=>{
 const m=manifest();assert.equal(m.contractVersion,4);assert.equal(m.questionCount,8);assert.equal(m.modelEvaluated,false);assert.equal(m.externalCalls,0);
 for(let i=0;i<8;i++){
  const p=pairedTaskPlannerRequest(i,'candidate'),b=request(i),row=m.rows[i],source=createQuestionUnits(oracle.cases[i].question);
  assert.deepEqual(JSON.parse(b.input[0].content[0].text),{question:oracle.cases[i].question,questionHash:source.questionHash,units:source.units.map(({id,text})=>({id,text}))});
  assert.deepEqual({...b,instructions:null,text:null,input:null},{...p,instructions:null,text:null,input:null});
  assert.equal(b.instructions.split('Additional scope annotation rules:')[1],p.instructions.split('Additional scope annotation rules:')[1]);
  assert.match(b.instructions,/Return TaskPlan v4 only/);assert.match(b.instructions,/not atomic answer requirements/);assert.match(b.instructions,/always be unknown/);assert.doesNotMatch(b.instructions,/TaskPlan v[23]|zero-based|prefix|suffix|requestSpans|quoting the referent/);
  assert.equal(row.parentCandidateRequestHash,hash(JSON.stringify(p)));assert.equal(row.requestHash,hash(JSON.stringify(b)));assert.equal(row.schemaHash,hash(JSON.stringify(b.text.format.schema)));assert.equal(row.instructionsHash,hash(b.instructions));assert.equal(row.bytes,Buffer.byteLength(JSON.stringify(b)));assert.ok(row.bytes<=m.requestBytesLimit);
  assert.equal(b.model,'gpt-6-luna');assert.deepEqual(b.reasoning,{effort:'medium'});assert.equal(b.store,false);assert.equal(b.stream,false);assert.equal(b.max_output_tokens,8192);assert.equal(b.text.format.strict,true);
  assert.deepEqual(b.text.format.schema.properties.questionHash.enum,[source.questionHash]);assert.deepEqual(b.text.format.schema.properties.tasks.items.properties.attribute.properties.unitIds.items.enum,source.units.map(u=>u.id));
  function objects(node){if(!node||typeof node!=='object')return;if(node.type==='object'){assert.equal(node.additionalProperties,false);assert.deepEqual([...node.required].sort(),Object.keys(node.properties).sort());}for(const v of Object.values(node))objects(v);}objects(b.text.format.schema);
 }
 assert.ok(!JSON.stringify(m).includes(oracle.cases[0].question));
});
test('selectors and isolated factory results cannot override evaluation or mutate future bodies',()=>{
 for(const i of [-1,8,'0',0.5,null,{},undefined])assert.throws(()=>request(i));assert.throws(()=>request(0,{}));assert.throws(()=>manifest({}));
 const before=JSON.stringify(request(0)),b=request(0);b.instructions='changed';b.text.format.schema.properties.version.enum[0]=3;assert.equal(JSON.stringify(request(0)),before);const m=manifest();m.rows[0].requestHash='bad';assert.notEqual(manifest().rows[0].requestHash,'bad');
});
test('eight mock responses bind thirteen candidate tasks without semantic accuracy claims',()=>{
 let count=0;for(let i=0;i<8;i++){
  const raw=JSON.stringify(sample(i)),r=parse(i,raw),q=oracle.cases[i].question;assert.equal(r.index,i);assert.equal(r.contractVersion,4);assert.equal(r.plan.version,4);assert.equal(r.questionHash,createQuestionUnits(q).questionHash);assert.equal(r.structuralProvenance.units.map(u=>u.text).join(''),q);assert.equal(r.requestHash,hash(JSON.stringify(request(i))));assert.equal(r.responseHash,hash(raw));assert.equal(r.semanticCompleteness,'pending');assert.equal(r.evidenceSupport,'unknown');assert.equal(r.releaseAccepted,false);count+=r.plan.tasks.length;
 }assert.equal(count,13);assert.throws(()=>run(sample(0),1),/unit_task_planner_question_mismatch/);assert.throws(()=>parse(0,JSON.stringify(sample()),{}));
});
test('fresh parsing returns independent plan and single provenance table',()=>{const input=sample(),before=JSON.stringify(input),a=run(input),b=run(input);a.plan.tasks[0].attribute.label='changed';a.structuralProvenance.units[0].text='changed';assert.notEqual(b.plan.tasks[0].attribute.label,'changed');assert.equal(b.structuralProvenance.units.map(u=>u.text).join(''),oracle.cases[0].question);assert.equal(JSON.stringify(input),before);});
test('old version invalid refs oversized labels conflicting status and forged support reject without repair',()=>{
 failure(mutate(sample(),p=>p.version=3),'shape');failure(mutate(sample(),p=>p.tasks[0].attribute.unitIds=['u99']),'references');failure(mutate(sample(),p=>p.tasks[0].attribute.label='x'.repeat(257)),'label');failure(mutate(sample(),p=>p.status='needs_clarification'),'status_conflict');failure(mutate(sample(),p=>p.tasks[0].evidenceSupport='supported'),'invalid_task');failure(mutate(sample(),p=>p.questionHash='private'),'question_mismatch');
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
 for(const raw of ['',null,'x'.repeat(262145)])assert.throws(()=>parse(0,raw),/unit_task_planner_response_size/);
 assert.throws(()=>parse(0,'{synthetic_private_detail'),e=>e.message==='unit_task_planner_response_json');
 const r=sample();r.output[0].content[0].text='あ'.repeat(10923);failure(r,'plan_size');r.output[0].content[0].text='```json\n{}\n```';failure(r,'plan_json');
});
test('valid references with invented labels and wrong roles remain semantic pending',()=>{
 const r=sample();mutate(r,p=>{p.tasks[0].subjects=p.tasks[1].subjects;p.tasks[0].attribute.label='架空属性';});const result=run(r);assert.equal(result.semanticCompleteness,'pending');assert.equal(result.releaseAccepted,false);
});
