// Synthetic development fixtures only, never imported by production or request code.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {subjectRolePairedLedgerManifest} from '../../scripts/rag-quality/subject-role-paired-ledger.ts';
import {subjectRoleTaskPlannerRequest} from '../../scripts/rag-quality/subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse} from '../../scripts/rag-quality/subject-role-task-planner-response.ts';
import {createQuestionUnits} from '../../scripts/rag-quality/question-units.ts';
import {unitPlanReviewBinding,UNIT_REVIEW_DIMENSIONS} from '../../scripts/rag-quality/unit-plan-semantic-review.ts';
export const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const oracle=JSON.parse(readFileSync(new URL('../../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url) as any) as any).cases[0];
export function mockLedger({baselineMissingSubjects=false}: any={}){
 const m=subjectRolePairedLedgerManifest(),rows=[{type:'manifest',manifest:m,runId:'cc000000-0000-4000-8000-000000000000',previous:null}];
 const append=(e: any)=>rows.push({...e,previous:hash(JSON.stringify(rows.at(-1)))});
 for(const job of m!.jobs.slice(0,2)){
  append({type:'reserved',job,reservedMicroUSD:8192});
  const source=createQuestionUnits(oracle.question),refs=(s: any)=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=(s: any)=>({label:s.text,unitIds:refs(s)});
  const plan={version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:oracle.requirements.map((r: any,i: any)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:baselineMissingSubjects&&job.variant==='baseline'?[]:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
  const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:subjectRoleTaskPlannerRequest(job.index,job.variant).model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:200,output_tokens:200,total_tokens:400,output_tokens_details:{reasoning_tokens:20}}});
  append({type:'completed',ordinal:job.ordinal,result:parseSubjectRoleTaskPlannerResponse(job.index,job.variant,job.requestHash,raw),elapsedMs:1});
 }
 append({type:'stage_finished',stage:0,completedRequests:2,completedPairs:1});return rows.map((row: any)=>JSON.stringify(row)).join('\n')+'\n';
}
export function mockBatch(collection: any,modes: any={}){
 return {version:1,binding:structuredClone(collection.binding),submissions:collection.mapping.map((job: any)=>{
  const p=collection.packets.find((p: any)=>p.packetId===job.packetId),mode=modes[job.variant]??'pass';
  const review={...unitPlanReviewBinding(p.question,JSON.stringify(p.plan),JSON.stringify(p.oracle)),reviewerRole:'independent_scope_reviewer',artifactHash:'a'.repeat(64),
   representability:p.oracle.requirements.map((r: any,i: any)=>({requirementId:r.id,status:i===0&&mode==='unsupported'?'unsupported':i===0&&mode==='representation_uncertain'?'uncertain':'representable'})),
   pairs:p.plan.tasks.flatMap((t: any,i: any)=>p.oracle.requirements.map((r: any,j: any)=>{
    const dimensions=Object.fromEntries(UNIT_REVIEW_DIMENSIONS.map(k=>[k,'pass']));
    if(!r.allowedOperations.includes(t.operation))dimensions.operation='fail';
    if(i!==j)dimensions.scope='fail';else if(mode==='fail')dimensions.subjects='fail';else if(mode==='uncertain')dimensions.subjects='uncertain';
    return {taskId:t.id,requirementId:r.id,dimensions};
   }))};
  if(mode==='incomplete')review.pairs=[];
  return {packetId:job.packetId,packetHash:job.packetHash,review:JSON.stringify(review)};
 })};
}
