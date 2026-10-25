// Synthetic development responses only. Never used by request or production modules.
import {readFileSync} from 'node:fs';
import {subjectRoleComparisonManifest} from '../../scripts/rag-quality/subject-role-comparison.ts';
import {subjectRoleTaskPlannerRequest} from '../../scripts/rag-quality/subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse} from '../../scripts/rag-quality/subject-role-task-planner-response.ts';
import {createQuestionUnits} from '../../scripts/rag-quality/question-units.ts';
import {hash,mockBatch} from './rag-subject-role-review.ts';
export {hash,mockBatch};
const cases=JSON.parse(readFileSync(new URL('../../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url) as any) as any).cases;
export function comparisonResult(job: any,{missingSubjects=false}: any={}){
 const c=cases[job.index],s=createQuestionUnits(c.question),refs=(t: any)=>s.units.filter(u=>u.start<t.end&&u.end>t.start).map(u=>u.id),role=(t: any)=>({label:t.text,unitIds:refs(t)});
 const plan={version:4,questionHash:s.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r: any,i: any)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:missingSubjects?[]:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:subjectRoleTaskPlannerRequest(job.index,job.variant).model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:100,total_tokens:200,output_tokens_details:{reasoning_tokens:10}}});
 return parseSubjectRoleTaskPlannerResponse(job.index,job.variant,job.requestHash,raw);
}
export function comparisonContext(stage: any){
 const m=subjectRoleComparisonManifest(),start=stage===0?0:m!.limits.checkpoints[stage-1],end=m!.limits.checkpoints[stage];
 return {binding:{stage,completedRequests:end,checkpointHash:'a'.repeat(64),manifestHash:hash(JSON.stringify(m)),runId:'dd000000-0000-4000-8000-000000000000'},
  completions:m!.jobs.slice(start,end).map(job=>({ordinal:job.ordinal,result:comparisonResult(job),elapsedMs:1}))};
}
