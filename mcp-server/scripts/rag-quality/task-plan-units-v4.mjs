// Offline v4 format/provenance only. Labels and role choices remain untrusted.
import {createQuestionUnits} from './question-units.mjs';
import {TASK_OPERATIONS} from './task-plan-v2.mjs';
const fail=code=>{throw Error('unit_task_plan_'+code);};
const exact=(o,keys)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===keys.length&&keys.every(k=>Object.hasOwn(o,k));
function questionUnits(question){let units;try{units=createQuestionUnits(question);}catch{fail('question_input');}if(units.status!=='supported')fail('question_unit_limit');return units;}
export function taskPlanSchemaV4(question){
 if(arguments.length!==1)fail('arguments');const source=questionUnits(question),ids=source.units.map(u=>u.id);
 const refs=()=>({type:'array',minItems:1,maxItems:ids.length,items:{type:'string',enum:[...ids]}});
 const role=()=>({type:'object',additionalProperties:false,required:['label','unitIds'],properties:{label:{type:'string',minLength:1,maxLength:256},unitIds:refs()}});
 const task={id:{type:'string',pattern:'^t(?:[1-9]|1[0-6])$'},operation:{type:'string',enum:[...TASK_OPERATIONS]},attribute:role(),subjects:{type:'array',maxItems:4,items:role()},conditions:{type:'array',maxItems:4,items:role()},requestUnitIds:refs(),resolution:{type:'string',enum:['unknown']},evidenceSupport:{type:'string',enum:['unknown']},comparisonPermission:{type:'string',enum:['unknown']}};
 return {type:'object',additionalProperties:false,required:['version','questionHash','status','tasks','unresolved'],properties:{version:{type:'integer',enum:[4]},questionHash:{type:'string',enum:[source.questionHash]},status:{type:'string',enum:['candidate','needs_clarification','unrecognized'],description:'candidate requires tasks. needs_clarification iff an unresolved reference exists. unrecognized requires no tasks and an unresolved entry.'},tasks:{type:'array',maxItems:16,items:{type:'object',additionalProperties:false,required:Object.keys(task),properties:task}},unresolved:{type:'array',maxItems:8,items:{type:'object',additionalProperties:false,required:['kind','unitIds'],properties:{kind:{type:'string',enum:['reference','operation','syntax']},unitIds:refs()}}}}};
}
export function validateUnitTaskPlanV4(question,raw){
 if(arguments.length!==2)fail('arguments');const source=questionUnits(question);
 if(typeof raw!=='string'||!raw.trim())fail('plan_input');if(Buffer.byteLength(raw)>32768)fail('plan_size');
 let plan;try{plan=JSON.parse(raw);}catch{fail('plan_json');}
 if(!exact(plan,['version','questionHash','status','tasks','unresolved'])||plan.version!==4||!['candidate','needs_clarification','unrecognized'].includes(plan.status)||!Array.isArray(plan.tasks)||!Array.isArray(plan.unresolved))fail('shape');
 if(plan.questionHash!==source.questionHash)fail('question_mismatch');if(plan.tasks.length>16||plan.unresolved.length>8)fail('plan_limits');
 const known=new Set(source.units.map(u=>u.id));
 const references=a=>{if(!Array.isArray(a)||!a.length||a.length>known.size||a.some(id=>typeof id!=='string'||!known.has(id))||new Set(a).size!==a.length)fail('references');};
 const role=r=>{if(!exact(r,['label','unitIds']))fail('shape');if(typeof r.label!=='string'||!r.label.trim()||r.label.length>256||/[\uD800-\uDFFF]/u.test(r.label))fail('label');references(r.unitIds);};
 const roleList=list=>{if(!Array.isArray(list))fail('shape');if(list.length>4)fail('plan_limits');list.forEach(role);const keys=list.map(r=>JSON.stringify([r.label,[...r.unitIds].sort()]));if(new Set(keys).size!==keys.length)fail('duplicate_role');};
 const ids=new Set();
 for(const t of plan.tasks){
  if(!exact(t,['id','operation','attribute','subjects','conditions','requestUnitIds','resolution','evidenceSupport','comparisonPermission']))fail('shape');
  if(typeof t.id!=='string'||!/^t(?:[1-9]|1[0-6])$/.test(t.id)||ids.has(t.id)||!TASK_OPERATIONS.includes(t.operation)||t.resolution!=='unknown'||t.evidenceSupport!=='unknown'||t.comparisonPermission!=='unknown')fail('invalid_task');
  ids.add(t.id);role(t.attribute);roleList(t.subjects);roleList(t.conditions);references(t.requestUnitIds);
 }
 for(const u of plan.unresolved){if(!exact(u,['kind','unitIds'])||!['reference','operation','syntax'].includes(u.kind))fail('shape');references(u.unitIds);}
 const reference=plan.unresolved.some(u=>u.kind==='reference');
 if(reference&&plan.status!=='needs_clarification'||plan.status==='needs_clarification'&&!reference||plan.status==='candidate'&&!plan.tasks.length||plan.status==='unrecognized'&&(plan.tasks.length||!plan.unresolved.length))fail('status_conflict');
 const result={contractVersion:4,plan,structuralProvenance:{questionHash:source.questionHash,units:source.units},semanticCompleteness:'pending',evidenceSupport:'unknown',releaseAccepted:false};
 if(Buffer.byteLength(JSON.stringify(result))>262144)fail('resolved_size');return result;
}
