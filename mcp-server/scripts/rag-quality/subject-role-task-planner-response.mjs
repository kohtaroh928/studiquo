// Offline paired subject-role v4 validation. Existing evaluators remain frozen.
// requestHash identifies the expected request, not proof of upstream dispatch.
import {createHash} from 'node:crypto';
import {subjectRoleTaskPlannerRequest} from './subject-role-task-planner-request.mjs';
import {validateUnitTaskPlanV4} from './task-plan-units-v4.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const integer=(x,max)=>Number.isSafeInteger(x)&&x>=0&&x<=max;
const record=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const fail=code=>{throw Error('subject_role_planner_'+code);};

export function parseSubjectRoleTaskPlannerResponse(index,variant,observedRequestHash,raw) {
 if(arguments.length!==4)fail('invalid_arguments');
 let request;try{request=subjectRoleTaskPlannerRequest(index,variant);}catch{fail('selector');}
 const expectedRequestHash=hash(JSON.stringify(request));
 if(typeof observedRequestHash!=='string'||!/^[a-f0-9]{64}$/.test(observedRequestHash)||observedRequestHash!==expectedRequestHash)fail('request_mismatch');
 if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>262144)fail('response_size');
 let r;try{r=JSON.parse(raw);}catch{fail('response_json');}
 if(!record(r)||r.object!=='response'||r.status!=='completed'||r.error!==null||r.incomplete_details!==null)fail('not_completed');
 if(r.model!==request.model)fail('model_mismatch');
 const u=r.usage;
 if(!record(u)||!integer(u.input_tokens,32768)||!integer(u.output_tokens,request.max_output_tokens)||
  !integer(u.total_tokens,32768+request.max_output_tokens)||u.total_tokens!==u.input_tokens+u.output_tokens||
  !record(u.output_tokens_details)||!integer(u.output_tokens_details.reasoning_tokens,u.output_tokens))fail('invalid_usage');
 let cached=null,cacheWrite=null;
 if(u.input_tokens_details!==undefined&&u.input_tokens_details!==null){
  const d=u.input_tokens_details;
  if(!record(d)||Object.keys(d).some(k=>!['cached_tokens','cache_write_tokens'].includes(k)))fail('invalid_usage');
  if(d.cached_tokens!==undefined){if(!integer(d.cached_tokens,u.input_tokens))fail('invalid_usage');cached=d.cached_tokens;}
  if(d.cache_write_tokens!==undefined){if(!integer(d.cache_write_tokens,u.input_tokens))fail('invalid_usage');cacheWrite=d.cache_write_tokens;}
  if(cached!==null&&cacheWrite!==null&&cached+cacheWrite>u.input_tokens)fail('invalid_usage');
 }
 if(!Array.isArray(r.output)||!r.output.length||r.output.length>17)fail('invalid_output');
 const messages=[];
 for(const item of r.output){
  if(!record(item))fail('invalid_output');
  if(item.type==='reasoning'){
   if(item.status!==undefined&&item.status!=='completed')fail('invalid_output');
  }else if(item.type==='message')messages.push(item);
  else fail('unexpected_output');
 }
 if(messages.length!==1)fail('invalid_output');
 const m=messages[0];
 if(m.role!=='assistant'||m.status!=='completed'||!Array.isArray(m.content)||!m.content.length||m.content.length>8)fail('invalid_output');
 if(m.content.some(c=>record(c)&&c.type==='refusal'))fail('refused');
 if(m.content.length!==1||!record(m.content[0])||m.content[0].type!=='output_text'||typeof m.content[0].text!=='string')fail('invalid_output');
 const text=m.content[0].text;
 if(!text.trim()||Buffer.byteLength(text)>32768)fail('plan_size');
 const question=JSON.parse(request.input[0].content[0].text).question;
 let validated;try{validated=validateUnitTaskPlanV4(question,text);}catch(error){
  const codes=['arguments','question_input','question_unit_limit','plan_input','plan_size','plan_json','shape','question_mismatch','plan_limits','references','label','duplicate_role','invalid_task','status_conflict','resolved_size'];
  const code=codes.find(c=>error.message==='unit_task_plan_'+c);fail(code??'invalid_plan');
 }
 return {index,variant,bindingSource:'caller_dispatch_context',contractVersion:4,questionHash:validated.plan.questionHash,plan:validated.plan,structuralProvenance:validated.structuralProvenance,model:r.model,usage:{input:u.input_tokens,output:u.output_tokens,reasoning:u.output_tokens_details.reasoning_tokens,
  total:u.total_tokens,cached,cacheWrite},requestHash:expectedRequestHash,responseHash:hash(raw),
  semanticCompleteness:'pending',evidenceSupport:'unknown',releaseAccepted:false};
}
