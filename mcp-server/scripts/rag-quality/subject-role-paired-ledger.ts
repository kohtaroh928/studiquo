// Offline state validation only. No writes, transport, key loading or execution entry point.
// This first slice deliberately cannot authorize a second stage or accept review summaries.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';
import {subjectRoleTaskPlannerManifest,subjectRoleTaskPlannerRequest} from './subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse} from './subject-role-task-planner-response.ts';

const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const jsonHash=(x: any)=>hash(JSON.stringify(x));
const exact=(o: any,keys: any)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===keys.length&&keys.every((k: any)=>Object.hasOwn(o,k));
const hex=(x: any)=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const fail=()=>{throw Error('subject_role_ledger_audit_required');};
const SOURCE_FILES=Object.freeze([
 'subject-role-paired-ledger.ts','subject-role-task-planner-request.ts','subject-role-task-planner-response.ts',
 'role-preservation-questions-v1.json','role-preservation-oracle-v1.json','unit-task-planner-secret-guard.ts',
 'question-units.ts','task-plan-units-v4.ts','unit-plan-semantic-review.ts','task-plan-v2.ts',
 'unit-task-planner-request.ts','paired-task-planner-request.ts','task-planner-request.ts',
 'question-task-fixture.ts','task-plan-paired-draft.json',
]);
const LIMITS=Object.freeze({pairs:12,dispatches:24,checkpoints:Object.freeze([2,8,16,24]),
 pairCheckpoints:Object.freeze([1,4,8,12]),reservedMicroUSD:8192,
 stageReservedMicroUSD:Object.freeze([16384,49152,65536,65536]),totalReservedMicroUSD:196608,
 requestBytes:32768,responseBytes:262144,planBytes:32768,requestMs:60000,
 stageMs:Object.freeze([120000,360000,480000,480000]),journalBytes:2097152,
 reviewBytes:262144,artifactBytes:8388608,collectionBytes:2097152,artifactCount:4,collectionCount:4});
const stageFor=(ordinal: any)=>LIMITS.checkpoints.findIndex(end=>ordinal<end);

export function subjectRolePairedLedgerManifest(){
 if(arguments.length)fail();
 try{
  const input=subjectRoleTaskPlannerManifest(),sourceHashes: any={};
  for(const file of SOURCE_FILES)sourceHashes[file]=hash(readFileSync(new URL(file,import.meta.url) as any));
  const jobs=[];
  for(let index=0;index<12;index++)for(const variant of index%2?['candidate','baseline']:['baseline','candidate']){
   const row=input.rows.find(r=>r.index===index&&r.variant===variant),ordinal: number=jobs.length;
   const body=JSON.stringify(subjectRoleTaskPlannerRequest(index,variant));
   if(!row||hash(body)!==row.requestHash||Buffer.byteLength(body)>LIMITS.requestBytes)fail();
   jobs.push({ordinal,pairIndex:index,index,variant,stage:stageFor(ordinal),requestHash:row.requestHash,questionHash:row.questionHash});
  }
  return {version:1,suiteId:'subject-role-paired-ledger-offline-stage0-v1',contractVersion:4,
   transportAttached:false,persistenceAttached:false,reviewGateAttached:false,maxExecutableStage:0,
   syntheticOnly:true,releaseAccepted:false,input,limits:structuredClone(LIMITS),sourceHashes,jobs};
 }catch{fail();}
}

function validateCompletion(row: any,job: any){
 if(!exact(row,['type','ordinal','result','elapsedMs','previous'])||row.ordinal!==job.ordinal||
  !Number.isFinite(row.elapsedMs)||row.elapsedMs<0||row.elapsedMs>LIMITS.requestMs)fail();
 const r=row.result;
 if(!exact(r,['index','variant','bindingSource','contractVersion','questionHash','plan','structuralProvenance','model','usage','requestHash','responseHash','semanticCompleteness','evidenceSupport','releaseAccepted'])||!hex(r.responseHash)||
  !exact(r.usage,['input','output','reasoning','total','cached','cacheWrite']))fail();
 const u=r.usage,details: any={};
 if(u.cached!==null)details.cached_tokens=u.cached;
 if(u.cacheWrite!==null)details.cache_write_tokens=u.cacheWrite;
 // Revalidate the retained plan/usage and regenerate provenance from the fixed question.
 // The original response hash is syntax-checked; a retained plan cannot attest the raw response.
 const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:r.model,
  output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(r.plan)}]}],
  usage:{input_tokens:u.input,output_tokens:u.output,total_tokens:u.total,
   output_tokens_details:{reasoning_tokens:u.reasoning},input_tokens_details:details}});
 const checked=parseSubjectRoleTaskPlannerResponse(job.index,job.variant,job.requestHash,raw);
 checked.responseHash=r.responseHash;
 if(!isDeepStrictEqual(checked,r))fail();
}
const FAILURE_REASONS=Object.freeze(['transport_or_unknown','response_body_failure','upstream_http','timeout',
 ...['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output',
 'refused','plan_size','plan_json','shape','question_mismatch','references','label','duplicate_role','invalid_task',
 'status_conflict','plan_limits','resolved_size','invalid_plan','request_mismatch','selector','invalid_arguments']
 .map(c=>'subject_role_planner_'+c)]);

export function replaySubjectRolePairedLedger(raw: any){
 if(arguments.length!==1)fail();
 try{
  if(typeof raw!=='string'||!raw||Buffer.byteLength(raw)>LIMITS.journalBytes||!raw.endsWith('\n'))fail();
  const lines=raw.slice(0,-1).split('\n');if(lines.length>128)fail();
  const rows=lines.map((line: any)=>JSON.parse(line)),base=subjectRolePairedLedgerManifest(),first=rows[0];
  if(!exact(first,['type','manifest','runId','previous'])||first.type!=='manifest'||first.previous!==null||
   !isDeepStrictEqual(first.manifest,base)||typeof first.runId!=='string'||
   !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(first.runId))fail();
  let previous=jsonHash(first),pending=null,completed=0,reserved=0,failedOrdinal=null,finished=false,checkpointHash=null;
  const counts: any={baseline:0,candidate:0};
  for(const row of rows.slice(1)){
   if(!row||row.previous!==previous||failedOrdinal!==null||finished)fail();
   const job=base!.jobs[completed];
   if(row.type==='reserved'){
    if(!exact(row,['type','job','reservedMicroUSD','previous'])||pending!==null||job?.stage!==0||
     !isDeepStrictEqual(row.job,job)||row.reservedMicroUSD!==LIMITS.reservedMicroUSD||reserved>=2)fail();
    pending=job.ordinal;reserved++;
   }else if(row.type==='completed'){
    if(pending===null||pending!==job?.ordinal)fail();
    validateCompletion(row,job);counts[job.variant]++;completed++;pending=null;
   }else if(row.type==='failed'){
    if(!exact(row,['type','ordinal','phase','httpStatus','reason','previous'])||pending===null||row.ordinal!==pending||
     !['fetch','body','validation'].includes(row.phase)||
     row.httpStatus!==null&&(!Number.isInteger(row.httpStatus)||row.httpStatus<100||row.httpStatus>599)||
     !FAILURE_REASONS.includes(row.reason))fail();
    failedOrdinal=pending;pending=null;
   }else if(row.type==='stage_finished'){
    if(!exact(row,['type','stage','completedRequests','completedPairs','previous'])||pending!==null||completed!==2||
     row.stage!==0||row.completedRequests!==2||row.completedPairs!==1)fail();
    finished=true;checkpointHash=jsonHash(row);
   }else fail(); // packets_ready/review/continue are not authority until artifact gates exist.
   previous=jsonHash(row);
  }
  const stopped=failedOrdinal!==null,completePairs=Math.floor(completed/2),partialPairs=completed%2;
  return {runId:first.runId,manifestHash:jsonHash(base),tailHash:previous,records:rows.length,
   stage:0,pending,failedOrdinal,stopped,audit:finished?'pending':stopped?'technical_stop':'not_due',checkpointHash,
   completedRequests:completed,baselineCompleted:counts.baseline,candidateCompleted:counts.candidate,
   technicalCompletedPairs:completePairs,partialPairs,plannedPairs:12,
   // A durable reservation does not prove dispatch. Avoid calling these "unsent" or deriving them from completions.
   reservedPairs:Math.ceil(reserved/2),unreservedPairs:12-Math.ceil(reserved/2),
   reservedRequests:reserved,reservedMicroUSD:reserved*LIMITS.reservedMicroUSD,
   generationComplete:false,allReviewsComplete:false,comparablePairs:0,candidateAllMatched:null,
   baselineMismatchCount:null,finalDecision:stopped?'technical_stop':'pending',
   semanticCompleteness:'pending',evidenceSupport:'unknown',releaseAccepted:false,
   safeReopenCheckpoint:!stopped&&pending===null&&(completed===0||finished),
   // Only a continuous in-memory operation may consume this. It is not permission to resume a partial disk run.
   nextJob:!stopped&&!finished&&pending===null&&completed<2?structuredClone(base!.jobs[completed]):null};
 }catch{fail();}
}
