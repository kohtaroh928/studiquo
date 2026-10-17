// Evaluation only. Quoted v3 inputs never repair or retry rejected v2 plans.
import {taskPlanSchemaV2,validateTaskPlanV2,TASK_OPERATIONS} from './task-plan-v2.mjs';
const issuedErrors=new WeakMap();
const fail=code=>{const error=Error('quoted_task_plan_'+code);issuedErrors.set(error,code);throw error;};
const exact=(o,keys)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===keys.length&&keys.every(k=>Object.hasOwn(o,k));
const wellFormed=s=>!/[\uD800-\uDFFF]/u.test(s);
const quoteSchema={type:'object',additionalProperties:false,required:['text','prefix','suffix'],properties:{
 text:{type:'string',minLength:1,maxLength:4096},prefix:{type:'string',maxLength:128},suffix:{type:'string',maxLength:128},
}};
export function taskPlanSchemaV3(){
 if(arguments.length)fail('arguments');
 const schema=taskPlanSchemaV2(),task=schema.properties.tasks.items.properties;
 schema.properties.version.const=3;task.attribute=quoteSchema;
 for(const name of ['subjects','conditions','requestSpans'])task[name].items=quoteSchema;
 schema.properties.unresolved.items.properties.span=quoteSchema;
 return structuredClone(schema);
}
// Reject non-JSON values rather than silently dropping keys or invoking toJSON.
function copyJSON(value){
 let nodes=0,remaining=32768;const seen=new Set();
 const spend=s=>{remaining-=Buffer.byteLength(s);if(remaining<0)fail('input');};
 function visit(x,depth){
  if(++nodes>4096||depth>16)fail('input');
  if(x===null||typeof x==='boolean'){spend(JSON.stringify(x));return x;}
  if(typeof x==='string'){if(x.length>32768)fail('input');spend(JSON.stringify(x));return x;}
  if(typeof x==='number'){if(!Number.isFinite(x))fail('input');spend(JSON.stringify(x));return x;}
  if(typeof x!=='object'||seen.has(x))fail('input');seen.add(x);
  try{
   const array=Array.isArray(x),proto=Object.getPrototypeOf(x);
   if(!array&&proto!==Object.prototype&&proto!==null)fail('input');
   const keys=Reflect.ownKeys(x);
   if(array){
    if(x.length>64||keys.length!==x.length+1)fail('input');spend('['+','.repeat(Math.max(0,x.length-1))+']');
    return Array.from({length:x.length},(_,i)=>{
     const d=Object.getOwnPropertyDescriptor(x,String(i));if(!d||!d.enumerable||!Object.hasOwn(d,'value'))fail('input');return visit(d.value,depth+1);
    });
   }
   if(keys.length>16)fail('input');spend('{'+','.repeat(Math.max(0,keys.length-1))+'}');const result=Object.create(null);
   for(const key of keys){
    if(typeof key!=='string'||key.length>32768)fail('input');spend(JSON.stringify(key)+':');const d=Object.getOwnPropertyDescriptor(x,key);
    if(!d.enumerable||!Object.hasOwn(d,'value'))fail('input');result[key]=visit(d.value,depth+1);
   }
   return result;
  }finally{seen.delete(x);}
 }
 return visit(value,0);
}
function locate(question,quote){
 if(!exact(quote,['text','prefix','suffix']))fail('quote_shape');
 const {text,prefix,suffix}=quote;
 if(typeof text!=='string'||!text.trim()||text.length>4096||typeof prefix!=='string'||prefix.length>128||typeof suffix!=='string'||suffix.length>128||![text,prefix,suffix].every(wellFormed))fail('quote_shape');
 let match=-1;
 for(let start=question.indexOf(text);start!==-1;start=question.indexOf(text,start+1)){
  const end=start+text.length;
  if(start<prefix.length||question.slice(start-prefix.length,start)!==prefix||question.slice(end,end+suffix.length)!==suffix)continue;
  if(match!==-1)fail('quote_ambiguous');match=start;
 }
 if(match===-1)fail('quote_not_found');
 return {start:match,end:match+text.length,text:question.slice(match,match+text.length)};
}
export function resolveQuotedTaskPlanV3(question,input){
 if(arguments.length!==2)fail('arguments');
 try{
  if(typeof question!=='string'||!question.trim()||Buffer.byteLength(question)>16384||!wellFormed(question))fail('question');
  const plan=copyJSON(input);
  if(Buffer.byteLength(JSON.stringify(plan))>32768)fail('input');
  if(!exact(plan,['version','status','tasks','unresolved'])||plan.version!==3||!['candidate','needs_clarification','unrecognized'].includes(plan.status)||!Array.isArray(plan.tasks)||plan.tasks.length>16||!Array.isArray(plan.unresolved)||plan.unresolved.length>8)fail('shape');
  const ids=new Set();
  for(const t of plan.tasks){
   if(!exact(t,['id','operation','attribute','subjects','conditions','requestSpans','resolution','evidenceSupport','comparisonPermission'])||typeof t.id!=='string'||!/^t(?:[1-9]|1[0-6])$/.test(t.id)||ids.has(t.id)||!TASK_OPERATIONS.includes(t.operation)||t.resolution!=='unknown'||t.evidenceSupport!=='unknown'||t.comparisonPermission!=='unknown')fail('invalid_plan');
   ids.add(t.id);
   for(const name of ['subjects','conditions','requestSpans'])if(!Array.isArray(t[name])||t[name].length>4||t[name].length<(name==='requestSpans'?1:0))fail('shape');
  }
  for(const u of plan.unresolved)if(!exact(u,['kind','span'])||!['reference','operation','syntax'].includes(u.kind))fail('shape');
  const tasks=plan.tasks.map(t=>{
   if(!exact(t,['id','operation','attribute','subjects','conditions','requestSpans','resolution','evidenceSupport','comparisonPermission']))fail('shape');
   const resolved={...t,attribute:locate(question,t.attribute)};
   for(const name of ['subjects','conditions','requestSpans']){
    const list=t[name];if(!Array.isArray(list)||list.length>4||list.length<(name==='requestSpans'?1:0))fail('shape');
    resolved[name]=list.map(q=>locate(question,q));
   }
   return resolved;
  });
  const unresolved=plan.unresolved.map(u=>{if(!exact(u,['kind','span']))fail('shape');return {kind:u.kind,span:locate(question,u.span)};});
  let resolvedPlan;try{resolvedPlan=validateTaskPlanV2(question,{version:2,status:plan.status,tasks,unresolved});}catch{fail('invalid_plan');}
  return {contractVersion:3,resolvedPlan,semanticCompleteness:'pending',evidenceSupport:'unknown',releaseAccepted:false};
 }catch(error){
  if(issuedErrors.has(error))throw Error('quoted_task_plan_'+issuedErrors.get(error));
  fail('input');
 }
}
