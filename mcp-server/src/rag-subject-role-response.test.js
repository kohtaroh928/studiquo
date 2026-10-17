import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.mjs';
import {subjectRoleTaskPlannerRequest as request} from '../scripts/rag-quality/subject-role-task-planner-request.mjs';
import {parseSubjectRoleTaskPlannerResponse as parse} from '../scripts/rag-quality/subject-role-task-planner-response.mjs';
const cases=JSON.parse(readFileSync(new URL('../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url))).cases;
const hash=x=>createHash('sha256').update(x).digest('hex');
const requestHash=(i=0,v='baseline')=>hash(JSON.stringify(request(i,v)));
function sample(index=0){const c=cases[index],source=createQuestionUnits(c.question),refs=s=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=s=>({label:s.text,unitIds:refs(s)}),plan={version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:200,output_tokens:300,total_tokens:500,output_tokens_details:{reasoning_tokens:50}}};}
const run=(r,i=0,v='baseline')=>parse(i,v,requestHash(i,v),JSON.stringify(r));
const mutate=(r,fn)=>{const p=JSON.parse(r.output[0].content[0].text);fn(p);r.output[0].content[0].text=JSON.stringify(p);return r;};
const fails=(r,code)=>assert.throws(()=>run(r),e=>e.message==='subject_role_planner_'+code&&!e.message.includes('private'));
test('all 24 mocked outputs bind local variant question and observed request hash without a semantic pass',()=>{
 let scopes=0;for(let i=0;i<12;i++)for(const v of ['baseline','candidate']){const raw=JSON.stringify(sample(i)),r=parse(i,v,requestHash(i,v),raw);assert.equal(r.variant,v);assert.equal(r.index,i);assert.equal(r.requestHash,requestHash(i,v));assert.equal(r.responseHash,hash(raw));assert.equal(r.bindingSource,'caller_dispatch_context');assert.equal(r.structuralProvenance.units.map(u=>u.text).join(''),cases[i].question);assert.equal(r.semanticCompleteness,'pending');assert.equal(r.evidenceSupport,'unknown');assert.equal(r.releaseAccepted,false);scopes+=r.plan.tasks.length;}assert.equal(scopes,28);
});
test('same-question wrong variant hash is rejected before decoding the response',()=>{
 const raw=JSON.stringify(sample());assert.throws(()=>parse(0,'candidate',requestHash(0,'baseline'),raw),e=>e.message==='subject_role_planner_request_mismatch');assert.throws(()=>parse(0,'baseline',requestHash(0,'candidate'),'{private'),e=>e.message==='subject_role_planner_request_mismatch');
 for(const h of [null,{},'x','0'.repeat(64)])assert.throws(()=>parse(0,'baseline',h,raw),e=>e.message==='subject_role_planner_request_mismatch');
});
test('local dispatch binding is not upstream proof and response text does not attest policy identity',()=>{
 const raw=JSON.stringify(sample());const b=parse(0,'baseline',requestHash(0,'baseline'),raw),c=parse(0,'candidate',requestHash(0,'candidate'),raw);assert.equal(b.responseHash,c.responseHash);assert.notEqual(b.requestHash,c.requestHash);assert.equal(b.bindingSource,'caller_dispatch_context');
});
test('different question hash selector overrides and old contracts reject without repair',()=>{
 assert.throws(()=>run(sample(0),1),e=>e.message==='subject_role_planner_question_mismatch');assert.throws(()=>parse(12,'baseline','0'.repeat(64),'{}'),e=>e.message==='subject_role_planner_selector');assert.throws(()=>parse(0,'other','0'.repeat(64),'{}'),e=>e.message==='subject_role_planner_selector');assert.throws(()=>parse(0,'baseline',requestHash(),'{}',{}),e=>e.message==='subject_role_planner_invalid_arguments');fails(mutate(sample(),p=>p.version=3),'shape');fails(mutate(sample(),p=>p.tasks[0].attribute.unitIds=['u99']),'references');fails(mutate(sample(),p=>p.tasks[0].evidenceSupport='supported'),'invalid_task');
});
test('completion refusal model and message checks remain strict',()=>{
 for(const change of [r=>r.status='incomplete',r=>r.error={message:'private'},r=>r.incomplete_details={},r=>r.object='other']){const r=sample();change(r);fails(r,'not_completed');}const r=sample();r.model='other';fails(r,'model_mismatch');const x=sample();x.output.push({type:'function_call'});fails(x,'unexpected_output');const m=sample();m.output.push(structuredClone(m.output[0]));fails(m,'invalid_output');const f=sample();f.output[0].content=[{type:'refusal',refusal:'private'}];fails(f,'refused');
});
test('usage cache limits and reasoning within output are validated with unknown cache preserved',()=>{
 assert.deepEqual(run(sample()).usage,{input:200,output:300,reasoning:50,total:500,cached:null,cacheWrite:null});const valid=sample();valid.usage.input_tokens_details={cached_tokens:10,cache_write_tokens:100};assert.equal(run(valid).usage.cacheWrite,100);
 for(const change of [u=>u.total_tokens++,u=>u.output_tokens=8193,u=>u.input_tokens=32769,u=>u.output_tokens_details.reasoning_tokens=301,u=>u.input_tokens_details={private:1},u=>u.input_tokens_details={cached_tokens:150,cache_write_tokens:150}]){const r=sample();change(r.usage);fails(r,'invalid_usage');}
});
test('response and plan limits malformed JSON and fenced output use fixed errors',()=>{
 for(const raw of [null,{},'','x'.repeat(262145)])assert.throws(()=>parse(0,'baseline',requestHash(),raw),e=>e.message==='subject_role_planner_response_size');assert.throws(()=>parse(0,'baseline',requestHash(),'{private'),e=>e.message==='subject_role_planner_response_json');const r=sample();r.output[0].content[0].text='あ'.repeat(10923);fails(r,'plan_size');r.output[0].content[0].text='```json\n{}\n```';fails(r,'plan_json');
});
test('wrong roles and empty subjects can formally pass while fresh results remain isolated',()=>{
 const input=mutate(sample(),p=>p.tasks.forEach(t=>t.subjects=[])),before=JSON.stringify(input),a=run(input),b=run(input);assert.equal(a.semanticCompleteness,'pending');a.plan.tasks[0].attribute.label='changed';a.structuralProvenance.units[0].text='changed';assert.notEqual(b.plan.tasks[0].attribute.label,'changed');assert.equal(JSON.stringify(input),before);
});
