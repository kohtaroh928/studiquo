// Evaluation-only diagnostics. The frozen validator remains the sole authority.
import {validateTaskPlanV2,TASK_OPERATIONS} from './task-plan-v2.mjs';
const codes=['question_shape','plan_size_or_json','root_fields','root_values','task_fields','id_invalid','id_duplicate','operation_invalid','permission_not_unknown','span_fields','span_bounds','span_text','span_quote_mismatch','span_list_bounds','span_duplicate','unresolved_fields','status_reference_conflict','candidate_without_tasks','unrecognized_status_conflict','unclassified_invalid'];
const roles=['root','task','attribute','subjects','conditions','requestSpans','unresolved'];
const exact=(o,k)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every(x=>Object.hasOwn(o,x));
export function safeTaskPlanDiagnostic(value){
 try{
  if(!exact(value,['code','role','taskIndex','spanIndex'])||!codes.includes(value.code)||!roles.includes(value.role)||
   !Number.isInteger(value.taskIndex)||value.taskIndex< -1||value.taskIndex>15||!Number.isInteger(value.spanIndex)||value.spanIndex< -1||value.spanIndex>7)return null;
  return {code:value.code,role:value.role,taskIndex:value.taskIndex,spanIndex:value.spanIndex};
 }catch{return null;}
}
export function diagnoseTaskPlan(question,plan){
 try{validateTaskPlanV2(question,plan);return null;}catch{}
 let role='root',taskIndex=-1,spanIndex=-1;
 const issued=new WeakSet();
 const stop=code=>{const error={code,role,taskIndex,spanIndex};issued.add(error);throw error;};
 try{
  if(typeof question!=='string'||!question.trim()||Buffer.byteLength(question)>16384)stop('question_shape');
  try{if(Buffer.byteLength(JSON.stringify(plan))>32768)stop('plan_size_or_json');}catch{stop('plan_size_or_json');}
  if(!exact(plan,['version','status','tasks','unresolved']))stop('root_fields');
  if(plan.version!==2||!['candidate','needs_clarification','unrecognized'].includes(plan.status)||!Array.isArray(plan.tasks)||plan.tasks.length>16||!Array.isArray(plan.unresolved)||plan.unresolved.length>8)stop('root_values');
  const span=s=>{
   if(!exact(s,['start','end','text']))stop('span_fields');
   if(!Number.isSafeInteger(s.start)||!Number.isSafeInteger(s.end)||s.start<0||s.end<=s.start||s.end>question.length)stop('span_bounds');
   if(typeof s.text!=='string'||!s.text.trim()||s.text.length>4096)stop('span_text');
   if(question.slice(s.start,s.end)!==s.text)stop('span_quote_mismatch');
  };
  const ids=new Set();
  for(const [i,t] of plan.tasks.entries()){
   role='task';taskIndex=i;spanIndex=-1;
   if(!exact(t,['id','operation','attribute','subjects','conditions','requestSpans','resolution','evidenceSupport','comparisonPermission']))stop('task_fields');
   if(typeof t.id!=='string'||!/^t(?:[1-9]|1[0-6])$/.test(t.id))stop('id_invalid');
   if(ids.has(t.id))stop('id_duplicate');ids.add(t.id);
   if(!TASK_OPERATIONS.includes(t.operation))stop('operation_invalid');
   if(t.resolution!=='unknown'||t.evidenceSupport!=='unknown'||t.comparisonPermission!=='unknown')stop('permission_not_unknown');
   role='attribute';span(t.attribute);
   for(const name of ['subjects','conditions','requestSpans']){
    role=name;spanIndex=-1;const a=t[name];
    if(!Array.isArray(a)||a.length>4||a.length<(name==='requestSpans'?1:0))stop('span_list_bounds');
    for(const [j,s] of a.entries()){spanIndex=j;span(s);}
    spanIndex=-1;if(new Set(a.map(s=>`${s.start}:${s.end}`)).size!==a.length)stop('span_duplicate');
   }
  }
  role='unresolved';taskIndex=-1;spanIndex=-1;
  for(const [i,u] of plan.unresolved.entries()){
   spanIndex=i;if(!exact(u,['kind','span'])||!['reference','operation','syntax'].includes(u.kind))stop('unresolved_fields');span(u.span);
  }
  role='root';spanIndex=-1;
  const reference=plan.unresolved.some(u=>u.kind==='reference');
  if(reference&&plan.status!=='needs_clarification'||plan.status==='needs_clarification'&&!reference)stop('status_reference_conflict');
  if(plan.status==='candidate'&&!plan.tasks.length)stop('candidate_without_tasks');
  if(plan.status==='unrecognized'&&(plan.tasks.length||!plan.unresolved.length))stop('unrecognized_status_conflict');
 }catch(error){if(issued.has(error))return error;}
 return {code:'unclassified_invalid',role:'root',taskIndex:-1,spanIndex:-1};
}
