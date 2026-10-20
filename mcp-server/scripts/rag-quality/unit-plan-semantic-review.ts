// Offline aggregation of external review. Never infer label meaning or call a model.
import {createHash} from 'node:crypto';
import {validateUnitTaskPlanV4} from './task-plan-units-v4.ts';
import {compareTaskPlanV2} from './task-plan-v2.ts';
export const UNIT_REVIEW_DIMENSIONS=Object.freeze(['operation','attribute','subjects','conditions','intent','scope','provenance','noInventedDetails']);
const fail=(code: any)=>{throw Error('unit_review_'+code);};
const exact=(o: any,k: any)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every((x: any)=>Object.hasOwn(o,x));
const canonical=(x: any): any=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const hash=(x: any)=>createHash('sha256').update(JSON.stringify(canonical(x))).digest('hex');
const parse=(raw: any,limit: any,name: any)=>{if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>limit)fail(name+'_input');try{return JSON.parse(raw);}catch{fail(name+'_json');}};
function context(question: any,rawPlan: any,rawOracle: any){
 let plan;try{plan=validateUnitTaskPlanV4(question,rawPlan).plan;}catch{fail('plan_invalid');}
 const oracle=parse(rawOracle,32768,'oracle');
 try{
  if(!exact(oracle,['id','question','requirements'])||typeof oracle.id!=='string'||!oracle.id||oracle.id.length>128||oracle.question!==question||!Array.isArray(oracle.requirements)||!oracle.requirements.length||oracle.requirements.length>16)throw Error();
  const tasks=oracle.requirements.map((r: any,i: any)=>{
   if(!exact(r,['id','allowedOperations','interpretation','attribute','subjects','conditions','requestSpans'])||typeof r.id!=='string'||!/^r(?:[1-9]|1[0-6])$/.test(r.id)||r.interpretation!=='declared')throw Error();
   return {id:'t'+(i+1),operation:r.allowedOperations?.[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'};
  });
  compareTaskPlanV2(question,{version:2,status:'candidate',tasks,unresolved:[]},oracle);
 }catch{fail('oracle_invalid');}
 return {plan,oracle,binding:{version:1,questionHash:plan.questionHash,planHash:hash(plan),oracleHash:hash(oracle)}};
}
export function unitPlanReviewBinding(question: any,rawPlan: any,rawOracle: any){if(arguments.length!==3)fail('arguments');return context(question,rawPlan,rawOracle).binding;}
function maximum(edges: any,tasks: any,requirements: any){
 const owner=new Map();function assign(i: any,seen: any){for(let j=0;j<requirements.length;j++){if(!edges[i][j]||seen.has(j))continue;seen.add(j);if(!owner.has(j)||assign(owner.get(j),seen)){owner.set(j,i);return true;}}return false;}
 tasks.forEach((_: any,i: any)=>assign(i,new Set()));return [...owner.entries()].map(([j,i])=>({taskId:tasks[i].id,requirementId:requirements[j].id})).sort((a,b)=>tasks.findIndex((t: any)=>t.id===a.taskId)-tasks.findIndex((t: any)=>t.id===b.taskId));
}
export function evaluateUnitPlanReview(question: any,rawPlan: any,rawOracle: any,rawReview: any){
 if(arguments.length!==4)fail('arguments');const {plan,oracle,binding}=context(question,rawPlan,rawOracle),tasks=plan.tasks,requirements=oracle.requirements;
 const reviewed=new Map(),representability=new Map<any, any>(requirements.map((r: any)=>[r.id,'uncertain']));
 if(rawReview!==null){
  const review=parse(rawReview,262144,'review');
  if(!exact(review,['version','questionHash','planHash','oracleHash','reviewerRole','artifactHash','representability','pairs'])||review.version!==1||review.questionHash!==binding.questionHash||review.planHash!==binding.planHash||review.oracleHash!==binding.oracleHash||review.reviewerRole!=='independent_scope_reviewer'||typeof review.artifactHash!=='string'||!/^([a-f0-9]{64})$/.test(review.artifactHash)||!Array.isArray(review.representability)||review.representability.length!==requirements.length||!Array.isArray(review.pairs)||review.pairs.length>tasks.length*requirements.length)fail('review_invalid');
  const seen=new Set();for(const r of review.representability){if(!exact(r,['requirementId','status'])||!representability.has(r.requirementId)||seen.has(r.requirementId)||!['representable','unsupported','uncertain'].includes(r.status))fail('review_invalid');seen.add(r.requirementId);representability.set(r.requirementId,r.status);}
  for(const p of review.pairs){
   if(!exact(p,['taskId','requirementId','dimensions'])||!exact(p.dimensions,UNIT_REVIEW_DIMENSIONS)||UNIT_REVIEW_DIMENSIONS.some(k=>!['pass','fail','uncertain'].includes(p.dimensions[k])))fail('review_invalid');
   const task=tasks.find((t: any)=>t.id===p.taskId),requirement=requirements.find((r: any)=>r.id===p.requirementId),key=p.taskId+':'+p.requirementId;
   if(!task||!requirement||reviewed.has(key))fail('review_invalid');if(p.dimensions.operation==='pass'&&!requirement.allowedOperations.includes(task.operation))fail('operation_conflict');reviewed.set(key,p.dimensions);
  }
 }
 const approved=tasks.map(()=>requirements.map(()=>false)),possible=tasks.map(()=>requirements.map(()=>false)),counts={approved:0,rejected:0,uncertain:0,unreviewed:0,automaticOperationMismatch:0};
 for(const [i,t] of tasks.entries())for(const [j,r] of requirements.entries()){
  const d=reviewed.get(t.id+':'+r.id),operation=r.allowedOperations.includes(t.operation);
  if(!operation){counts.rejected++;counts.automaticOperationMismatch++;continue;}
  if(d&&UNIT_REVIEW_DIMENSIONS.some(k=>d[k]==='fail')){counts.rejected++;continue;}
  possible[i][j]=true;
  if(d&&UNIT_REVIEW_DIMENSIONS.every(k=>d[k]==='pass')){approved[i][j]=true;counts.approved++;}
  else if(d)counts.uncertain++;else counts.unreviewed++;
 }
 const assigned=maximum(approved,tasks,requirements),possibleAssigned=maximum(possible,tasks,requirements),A=assigned.length,P=possibleAssigned.length,R=requirements.length,T=tasks.length;
 const representationCounts: any={representable:0,unsupported:0,uncertain:0};for(const status of representability.values())representationCounts[status]++;
 const flags={contractUnsupported:representationCounts.unsupported>0,representationUncertain:representationCounts.uncertain>0,correspondenceImpossible:P<R||P<T};
 const allApproved=A===R&&A===T,semanticStatus=flags.contractUnsupported?'contract_unsupported':allApproved&&!flags.representationUncertain?'reviewed_match':flags.correspondenceImpossible?'mismatch_detected':'pending';
 return {version:1,binding,reviewProvided:rawReview!==null,semanticStatus,flags,representationCounts,pairCounts:counts,oracleRequirements:R,candidateTasks:T,approvedMatches:A,possibleMatches:P,oracleRelativeMissing:{lower:R-P,upper:R-A},oracleRelativeExtra:{lower:T-P,upper:T-A},assignedPairs:assigned,unmatchedInApprovedAssignment:{taskIds:tasks.filter((t: any)=>!assigned.some(p=>p.taskId===t.id)).map((t: any)=>t.id),requirementIds:requirements.filter((r: any)=>!assigned.some(p=>p.requirementId===r.id)).map((r: any)=>r.id)},reviewComplete:!flags.representationUncertain&&(allApproved||counts.uncertain+counts.unreviewed===0),semanticsSource:'external_review',reviewerAuthenticated:false,humanReviewVerified:false,evidenceSupport:'unknown',releaseAccepted:false};
}
