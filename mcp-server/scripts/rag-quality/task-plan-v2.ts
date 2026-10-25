// Evaluation-only contract. Successful validation proves shape/provenance,
// never semantic completeness, retrieval support or permission to execute.
export const TASK_OPERATIONS=Object.freeze(['value','explain','calculate','compare','recommend','conditions','summarize']);
const statuses=['candidate','needs_clarification','unrecognized'];
const spanSchema={type:'object',additionalProperties:false,required:['start','end','text'],properties:{
 start:{type:'integer',minimum:0},end:{type:'integer',minimum:1},text:{type:'string',minLength:1,maxLength:4096},
}};
const spans=(max: any)=>({type:'array',maxItems:max,items:spanSchema});
const taskProperties={id:{type:'string',pattern:'^t(?:[1-9]|1[0-6])$'},operation:{type:'string',enum:TASK_OPERATIONS},
 attribute:spanSchema,subjects:spans(4),conditions:spans(4),requestSpans:{...spans(4),minItems:1},
 resolution:{type:'string',const:'unknown'},evidenceSupport:{type:'string',const:'unknown'},comparisonPermission:{type:'string',const:'unknown'}};
export function taskPlanSchemaV2() {
 return structuredClone({type:'object',additionalProperties:false,required:['version','status','tasks','unresolved'],properties:{
  version:{type:'integer',const:2},status:{type:'string',enum:statuses},
  tasks:{type:'array',maxItems:16,items:{type:'object',additionalProperties:false,required:Object.keys(taskProperties),properties:taskProperties}},
  unresolved:{type:'array',maxItems:8,items:{type:'object',additionalProperties:false,required:['kind','span'],properties:{kind:{type:'string',enum:['reference','operation','syntax']},span:spanSchema}}},
 }});
}

export function validateTaskPlanV2(question: any,plan: any) {
 const fail=()=>{throw Error('invalid_task_plan_v2');};
 const exact=(o: any,keys: any)=>{
  if(!o||typeof o!=='object'||Array.isArray(o)||Object.keys(o).length!==keys.length||keys.some((k: any)=>!Object.hasOwn(o,k)))fail();
 };
 if(typeof question!=='string'||!question.trim()||Buffer.byteLength(question)>16384)fail();
 try{if(Buffer.byteLength(JSON.stringify(plan))>32768)fail();}catch{fail();}
 exact(plan,['version','status','tasks','unresolved']);
 if(plan.version!==2||!statuses.includes(plan.status)||!Array.isArray(plan.tasks)||plan.tasks.length>16||!Array.isArray(plan.unresolved)||plan.unresolved.length>8)fail();
 const span=(s: any)=>{
  exact(s,['start','end','text']);
  if(!Number.isSafeInteger(s.start)||!Number.isSafeInteger(s.end)||s.start<0||s.end<=s.start||s.end>question.length||
   typeof s.text!=='string'||!s.text.trim()||s.text.length>4096||question.slice(s.start,s.end)!==s.text)fail();
 };
 const list=(a: any,max: any,min=0)=>{if(!Array.isArray(a)||a.length>max||a.length<min)fail();a.forEach(span);if(new Set(a.map((x: any)=>`${x.start}:${x.end}`)).size!==a.length)fail();};
 const ids=new Set();
 for(const t of plan.tasks){
  exact(t,Object.keys(taskProperties));
  if(typeof t.id!=='string'||!/^t(?:[1-9]|1[0-6])$/.test(t.id)||ids.has(t.id)||!TASK_OPERATIONS.includes(t.operation)||
   t.resolution!=='unknown'||t.evidenceSupport!=='unknown'||t.comparisonPermission!=='unknown')fail();
  ids.add(t.id);span(t.attribute);list(t.subjects,4);list(t.conditions,4);list(t.requestSpans,4,1);
 }
 for(const u of plan.unresolved){exact(u,['kind','span']);if(!['reference','operation','syntax'].includes(u.kind))fail();span(u.span);}
 const hasReference=plan.unresolved.some((u: any)=>u.kind==='reference');
 if((hasReference&&plan.status!=='needs_clarification')||(plan.status==='needs_clarification'&&!hasReference)||
  (plan.status==='candidate'&&!plan.tasks.length)||(plan.status==='unrecognized'&&(plan.tasks.length||!plan.unresolved.length)))fail();
 return structuredClone(plan);
}

// Exact annotation agreement only. A wide span covering two requirements
// cannot satisfy both; each candidate can match at most one oracle atom.
export function compareTaskPlanV2(question: any,plan: any,oracle: any) {
 const candidate=validateTaskPlanV2(question,plan);
 if(oracle?.question!==question||!Array.isArray(oracle.requirements)||!oracle.requirements.length||oracle.requirements.length>16||
  new Set(oracle.requirements.map((r: any)=>r.id)).size!==oracle.requirements.length)throw Error('invalid_task_oracle_v2');
 const representatives=oracle.requirements.map((r: any,i: any)=>{
  if(typeof r.id!=='string'||!r.id||!Array.isArray(r.allowedOperations)||!r.allowedOperations.length||r.allowedOperations.length>3||
   new Set(r.allowedOperations).size!==r.allowedOperations.length||r.allowedOperations.some((x: any)=>!TASK_OPERATIONS.includes(x)))throw Error('invalid_task_oracle_v2');
  return {id:'t'+(i+1),operation:r.allowedOperations[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,
   requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'};
 });
 validateTaskPlanV2(question,{version:2,status:'candidate',tasks:representatives,unresolved:[]});
 const sameSpan=(a: any,b: any)=>a.start===b.start&&a.end===b.end&&a.text===b.text;
 const sameList=(a: any,b: any)=>a.length===b.length&&a.every((x: any)=>b.some((y: any)=>sameSpan(x,y)));
 const owner=new Map();
 function assign(i: any,seen: any){
  const t=candidate.tasks[i];
  for(const [j,r] of oracle.requirements.entries()) {
   if(seen.has(j)||!r.allowedOperations.includes(t.operation)||!sameSpan(t.attribute,r.attribute)||
     !sameList(t.subjects,r.subjects)||!sameList(t.conditions,r.conditions)||!sameList(t.requestSpans,r.requestSpans))continue;
   seen.add(j);
   if(!owner.has(j)||assign(owner.get(j),seen)){owner.set(j,i);return true;}
  }
  return false;
 }
 candidate.tasks.forEach((_: any,i: any)=>assign(i,new Set()));
 const assigned=new Set(owner.values());
 return {version:2,annotationMatches:owner.size,missingAnnotationIds:oracle.requirements.filter((_: any,i: any)=>!owner.has(i)).map((r: any)=>r.id),
  extraTaskIds:candidate.tasks.filter((_: any,i: any)=>!assigned.has(i)).map((t: any)=>t.id),
  ambiguousMatches:[...owner.keys()].filter(i=>oracle.requirements[i].allowedOperations.length>1).length,
  semanticCompleteness:'pending',evidenceSupport:'unknown',releaseAccepted:false};
}
