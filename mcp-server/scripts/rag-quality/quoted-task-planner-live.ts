// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Fixed synthetic v3 stages. No CLI, key loading, logging or automatic execution.
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {openQuotedPlannerJournal,QUOTED_JOURNAL_LIMITS as limits,quotedJournalManifest} from './quoted-task-planner-journal.ts';
import {quotedTaskPlannerRequest} from './quoted-task-planner-request.ts';
import {parseQuotedTaskPlannerResponse} from './quoted-task-planner-response.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const parserCodes=['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','input','question','shape','quote_shape','quote_ambiguous','quote_not_found','invalid_plan'];
function parserReason(error: any){try{const value=Object.getOwnPropertyDescriptor(error,'message')?.value;const code=parserCodes.find(c=>value==='quoted_task_planner_'+c);return code?'quoted_task_planner_'+code:null;}catch{return null;}}
async function readBody(response: any,key: any,signal: any){
 if(!response.ok||!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??'')){void response.body?.cancel().catch(()=>{});throw Error();}
 if(!response.body)throw Error();const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let bytes=0,text='';
 const abort=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener('abort',abort,{once:true});
 try{
  for(;;){const next=await reader.read();if(next.done)break;bytes+=next.value.byteLength;if(bytes>limits.responseBytes)throw Error();text+=decoder.decode(next.value,{stream:true});}
  text+=decoder.decode();if(signal.aborted||text.includes(key))throw Error();return text;
 }catch{void reader.cancel().catch(()=>{});throw Error();}finally{signal.removeEventListener('abort',abort);reader.releaseLock();}
}
export async function runQuotedPlannerStage(options: any){
 let journal;
 try{
  if(arguments.length!==1||!options||typeof options!=='object'||Array.isArray(options)||Object.keys(options).some(k=>!['directory','apiKey','fetchImpl','onProgress','timeoutMs','totalMs'].includes(k)))throw Error();
  const {directory,apiKey,fetchImpl=fetch,onProgress=()=>{},timeoutMs=60000,totalMs}=options;
  if(typeof apiKey!=='string'||!/^[A-Za-z0-9_-]{16,512}$/.test(apiKey)||typeof fetchImpl!=='function'||typeof onProgress!=='function'||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||totalMs!==undefined&&(!Number.isInteger(totalMs)||totalMs<1||totalMs>240000))throw Error();
  const manifest=quotedJournalManifest(),bodies=manifest.jobs.map(job=>{
   const body=JSON.stringify(quotedTaskPlannerRequest(job.index));if(body.includes(apiKey)||Buffer.byteLength(body)>limits.requestBytes||hash(body)!==job.requestHash)throw Error();return body;
  });
  journal=openQuotedPlannerJournal(directory);const initial=journal!.status();
  if(initial.audit==='pending'||initial.generationComplete){journal!.close();journal=null;return {...initial,dispatches:0,reviewRequired:initial.audit==='pending'};}
  const cap=limits.stageMs[initial.stage];if(totalMs!==undefined&&totalMs>cap)throw Error();
  const deadline=performance.now()+(totalMs??cap),end=limits.checkpoints[initial.stage];let dispatches=0;
  for(let index=initial.completed;index<end;index++){
   if(performance.now()>=deadline)throw Error();const job=journal!.reserveNext();
   const started=performance.now(),requestDeadline=Math.min(deadline,started+timeoutMs);if(started>=requestDeadline)throw Error();
   if(job.index!==index||job.requestHash!==manifest.jobs[index].requestHash)throw Error();
   const controller=new AbortController();let timer,saving=false,phase='fetch',httpStatus=null;dispatches++;
   try{
    const work=(async()=>{
     const response=await fetchImpl('https://api.openai.com/v1/responses',{method:'POST',body:bodies[index],headers:{'content-type':'application/json',authorization:`Bearer ${apiKey}`},redirect:'error',signal:controller.signal});
     if(Number.isInteger(response.status)&&response.status>=100&&response.status<=599)httpStatus=response.status;
     if(controller.signal.aborted){void response.body?.cancel().catch(()=>{});throw Error();}
     phase='body';const raw=await readBody(response,apiKey,controller.signal);if(controller.signal.aborted)throw Error();phase='validation';return parseQuotedTaskPlannerResponse(index,raw);
    })();
    const result=await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error());},Math.max(1,requestDeadline-performance.now()));})]);
    if(performance.now()>=requestDeadline)throw Error();saving=true;
    journal!.complete(result,performance.now()-started,requestDeadline);
   }catch(error){
    const reason=controller.signal.aborted||performance.now()>=requestDeadline?'timeout':httpStatus!==null&&(httpStatus<200||httpStatus>=300)?'upstream_http':phase==='validation'?(parserReason(error)??'transport_or_unknown'):phase==='body'?'response_body_failure':'transport_or_unknown';
    if(!saving)journal!.markFailed({phase,httpStatus,reason});throw Error();
   }finally{clearTimeout(timer);controller.abort();}
   onProgress({index,completed:index+1,stage:initial.stage});
  }
  journal!.finishStage(deadline);const status=journal!.status();journal!.close();journal=null;
  return {...status,dispatches,reviewRequired:true};
 }catch{try{journal?.close();}catch{}throw Error('quoted_planner_stopped_audit_required');}
}
