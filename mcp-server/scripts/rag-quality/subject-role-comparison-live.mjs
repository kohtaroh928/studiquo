// Explicit finite stage invocation only. No CLI, key loading, logs, retries or automatic execution.
import {createHash} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {performance} from 'node:perf_hooks';
import {assertUnitPlannerSecretFree} from './unit-task-planner-secret-guard.mjs';
import {subjectRoleTaskPlannerRequest} from './subject-role-task-planner-request.mjs';
import {parseSubjectRoleTaskPlannerResponse} from './subject-role-task-planner-response.mjs';
import {subjectRoleComparisonLiveManifest} from './subject-role-comparison-live-contract.mjs';
import {openSubjectRoleComparisonLiveJournal} from './subject-role-comparison-live-journal.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const endpoint='https://api.openai.com/v1/responses';
const codes=['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','shape','question_mismatch','references','label','duplicate_role','invalid_task','status_conflict','plan_limits','resolved_size','invalid_plan','request_mismatch','selector','invalid_arguments'].map(c=>'subject_role_planner_'+c);
function validationReason(error){try{const value=Object.getOwnPropertyDescriptor(error,'message')?.value;return [...codes,...['input','json','limits','reflection'].map(c=>'unit_secret_guard_'+c)].find(c=>value===c)??'transport_or_unknown';}catch{return 'transport_or_unknown';}}
function cancel(body){try{Promise.resolve(body?.cancel()).catch(()=>{});}catch{}}
async function readBody(response,signal,limit){
 if(!response.ok||response.redirected===true||!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??'')){cancel(response.body);throw Error();}
 const length=response.headers.get('content-length');if(length!==null&&(!/^\d+$/.test(length)||Number(length)>limit)){cancel(response.body);throw Error();}
 if(!response.body)throw Error();const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let bytes=0,text='';
 const abort=()=>{try{Promise.resolve(reader.cancel()).catch(()=>{});}catch{}};signal.addEventListener('abort',abort,{once:true});
 try{for(;;){const next=await reader.read();if(next.done)break;bytes+=next.value.byteLength;if(bytes>limit)throw Error();text+=decoder.decode(next.value,{stream:true});}text+=decoder.decode();if(signal.aborted)throw Error();return text;}
 catch{abort();throw Error();}finally{signal.removeEventListener('abort',abort);reader.releaseLock();}
}
export async function runSubjectRoleComparisonStage(options){
 let journal;
 try{
  if(arguments.length!==1||!options||typeof options!=='object'||Array.isArray(options)||Object.keys(options).some(k=>!['directory','apiKey','fetchImpl','onProgress','timeoutMs','totalMs'].includes(k)))throw Error();
  const {directory,apiKey,fetchImpl=fetch,onProgress=()=>{},timeoutMs=60000,totalMs}=options;
  if(typeof apiKey!=='string'||!/^[A-Za-z0-9_-]{16,512}$/.test(apiKey)||typeof fetchImpl!=='function'||typeof onProgress!=='function'||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||totalMs!==undefined&&(!Number.isInteger(totalMs)||totalMs<1||totalMs>480000))throw Error();
  const manifest=subjectRoleComparisonLiveManifest(),bodies=manifest.jobs.map(job=>{
   const body=JSON.stringify(subjectRoleTaskPlannerRequest(job.index,job.variant));assertUnitPlannerSecretFree(body,apiKey);
   if(Buffer.byteLength(body)>manifest.limits.requestBytes||hash(body)!==job.requestHash)throw Error();return body;
  });
  journal=openSubjectRoleComparisonLiveJournal(directory);const initial=journal.status();
  if(initial.phase!=='running'){journal.close();journal=null;return {...initial,dispatches:0,reviewRequired:initial.phase==='checkpoint'||initial.phase==='packets'};}
  const cap=manifest.limits.stageMs[initial.stage];if(totalMs!==undefined&&totalMs>cap)throw Error();
  const deadline=performance.now()+(totalMs??cap),end=manifest.limits.checkpoints[initial.stage];let dispatches=0;
  for(let ordinal=initial.completedRequests;ordinal<end;ordinal++){
   if(performance.now()>=deadline)throw Error();const job=journal.reserveNext(deadline),started=performance.now(),requestDeadline=Math.min(deadline,started+timeoutMs);
   if(started>=requestDeadline||!equal(job,manifest.jobs[ordinal]))throw Error();
   const context=Object.freeze({...job,body:bodies[ordinal],observedRequestHash:hash(bodies[ordinal])});
   if(context.observedRequestHash!==context.requestHash)throw Error();assertUnitPlannerSecretFree(context.body,apiKey);
   const controller=new AbortController();let timer,saving=false,phase='fetch',httpStatus=null;
   try{
    const timedOut=new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error());},Math.max(1,requestDeadline-performance.now()));});
    const work=(async()=>{
     // Hashing/secret validation above is synchronous and can exhaust the budget before the timer runs.
     if(controller.signal.aborted||performance.now()>=requestDeadline){controller.abort();throw Error();}
     dispatches++;
     const response=await fetchImpl(endpoint,{method:'POST',body:context.body,headers:{'content-type':'application/json',authorization:`Bearer ${apiKey}`},redirect:'error',signal:controller.signal});
     if(Number.isInteger(response.status)&&response.status>=100&&response.status<=599)httpStatus=response.status;
     if(controller.signal.aborted){cancel(response.body);throw Error();}
     phase='body';const raw=await readBody(response,controller.signal,manifest.limits.responseBytes);if(controller.signal.aborted)throw Error();
     phase='validation';assertUnitPlannerSecretFree(raw,apiKey);
     const result=parseSubjectRoleTaskPlannerResponse(context.index,context.variant,context.observedRequestHash,raw);
     assertUnitPlannerSecretFree(JSON.stringify(result),apiKey);return result;
    })();
    const result=await Promise.race([work,timedOut]);
    if(performance.now()>=requestDeadline)throw Error();saving=true;journal.complete(result,performance.now()-started,requestDeadline);
   }catch(error){
    const reason=controller.signal.aborted||performance.now()>=requestDeadline?'timeout':httpStatus!==null&&(httpStatus<200||httpStatus>=300)?'upstream_http':phase==='validation'?validationReason(error):phase==='body'?'response_body_failure':'transport_or_unknown';
    if(!saving)journal.markFailed({phase,httpStatus,reason});throw Error();
   }finally{clearTimeout(timer);controller.abort();}
   const notification=onProgress({ordinal,index:job.index,variant:job.variant,completedRequests:ordinal+1,stage:initial.stage});
   if(notification!==null&&(typeof notification==='object'||typeof notification==='function')&&typeof notification.then==='function'){Promise.resolve(notification).catch(()=>{});throw Error();}
  }
  journal.finishStage(deadline);const status=journal.status();journal.close(deadline);journal=null;
  return {...status,dispatches,reviewRequired:true};
 }catch{try{journal?.close();}catch{}throw Error('subject_role_comparison_stopped_audit_required');}
}
