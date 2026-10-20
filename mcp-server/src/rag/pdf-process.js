import {json} from '../http.js';
import {rawPDFPreflightRejection,readRawPDFBytesLimited} from './pdf-preflight.js';
import {verifyRawPDFIntakeBytes,requireRawPDFIntakeAuthorization} from './pdf-intake.js';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched,requestRawPDFJobStop,
 settleRawPDFJob,requireRawPDFJobExecution,markRawPDFJobDispatchedV2,requireRawPDFRPCV2Schema} from './pdf-jobs.js';
import {rawPDFProcessorAvailable,parseRawPDFV2,cancelRawPDFProcessor} from './pdf-rpc.js';
import {beginRawPDFStopEvidence,confirmRawPDFRemoteStop,settleRawPDFJobFromEvidence} from './pdf-stop-evidence.js';
import {validateRawPDFManifest} from './pdf-manifest.js';
const fail=code=>{throw Error(code);};
// An independent timer bounds a stalled DB/RPC. Its timeout is NOT proof of stop.
async function bounded(work,ms,signal){
 if(signal?.aborted)fail('pdf_processing_cancelled');
 let timer,onAbort;
 try{return await new Promise((resolve,reject)=>{
  onAbort=()=>reject(Error('pdf_processing_cancelled'));signal?.addEventListener('abort',onAbort,{once:true});
  timer=setTimeout(()=>reject(Error('pdf_processing_timeout')),Math.max(1,ms));
  Promise.resolve().then(()=>{if(signal?.aborted)fail('pdf_processing_cancelled');return work();}).then(resolve,reject);
 });}finally{clearTimeout(timer);signal?.removeEventListener('abort',onAbort);}
}
// Policy, timers and binding come from trusted startup wiring. There is no
// retry, formal result adoption or client stop assertion. The HTTP adapter may
// transfer provisional frames while the slot is held, with per-frame guards;
// only this function's successful return authorizes a terminal success frame.
export async function processRawPDF(env,session,input,request,policy,{signal,clock=Date.now,pollMs=250,workMs=180000,cleanupMs=10000,consumeResult,onInputConsumed}={}){
 session=Object.freeze({sub:session?.sub});const proof=Object.freeze({...input});
 const preflight=rawPDFPreflightRejection(request.headers,env);if(preflight)return preflight;
 const processor=env.DOCLING_PROCESSOR,v2=env.RAG_PDF_RPC_V2_ENABLED==='true';
 if(!rawPDFProcessorAvailable(env,v2)||typeof consumeResult!=='function')return json({error:'pdf_processor_unavailable'},503);
 if(!Number.isInteger(pollMs)||pollMs<1||pollMs>250||!Number.isInteger(workMs)||workMs<1||workMs>180000||!Number.isInteger(cleanupMs)||cleanupMs<1||cleanupMs>10000)
  return json({error:'pdf_processing_unavailable'},503);
 const controller=new AbortController(),signals=[...new Set([signal,request.signal].filter(Boolean))];
 const abort=()=>controller.abort();for(const s of signals){s.addEventListener('abort',abort,{once:true});if(s.aborted)abort();}
 let scope,received,verified,parsed,manifest,contract,remoteStopAttempted=false,remoteRecorded=false;
 let job,token,dispatchAttempted=false,parseStopped=false,readerCleanup=Promise.resolve(true),readerTask,monitor,monitorTimer,workTimer,stopping=false;
 const start=clock();let deadline=start+workMs;
 const remaining=()=>Math.max(1,deadline-clock());
 const check=()=>requireRawPDFJobExecution(env,session,proof,job.jobId,token,{clock});
 const running=new Set();
 const work=fn=>bounded(()=>{
  const execute=async()=>{if(controller.signal.aborted)fail('pdf_processing_cancelled');return fn();};
  // The scope tracks the actual task, not its timeout wrapper. Values never
  // leave scope.run's return; its ephemeral wrapper is discarded after await.
  let task;
  if(scope){let value;const tracked=scope.run(async()=>{value=await execute();});task=tracked.then(()=>value);}
  else task=Promise.resolve().then(execute);
  running.add(task);task.then(()=>running.delete(task),()=>running.delete(task));return task;
 },remaining(),controller.signal);
 let cleanupEnd;
 const clean=fn=>{
  cleanupEnd??=Date.now()+cleanupMs;
  const left=cleanupEnd-Date.now();
  if(left<=0)return Promise.reject(Error('pdf_cleanup_unconfirmed'));
  return bounded(fn,left);
 };
 const localStopped=async()=>{
  // Timed-out wrappers do not stop the actual verification/DB/RPC tasks.
  await Promise.allSettled([...running]);await readerTask;return readerCleanup;
 };
 const watch=async()=>{
  if(stopping||controller.signal.aborted)return;
  try{await work(check);}catch{controller.abort();return;}
  if(!stopping&&!controller.signal.aborted)monitorTimer=setTimeout(()=>{monitor=watch();},pollMs);
 };
 try{
  workTimer=setTimeout(abort,workMs);
  if(v2)await work(()=>requireRawPDFRPCV2Schema(env.ADMIN_DB));
  job=await work(()=>reserveRawPDFJob(env,session,proof,policy,{clock}));deadline=Math.min(deadline,job.deadline,proof.expiresAt);
  const claim=await work(()=>env.RAG_PDF_STOP_EVIDENCE_ENABLED==='true'
   ?beginRawPDFStopEvidence(env,session,proof,job.jobId,{clock,timeoutMs:Math.min(10000,remaining())})
   :claimRawPDFJob(env,session,proof,job.jobId,{clock}));
  token=claim.executionToken;if(env.RAG_PDF_STOP_EVIDENCE_ENABLED==='true')scope=claim;
  // Only this token holder has cleanup responsibility; a duplicate loser stops nothing.
  clearTimeout(workTimer);workTimer=setTimeout(abort,remaining());
  monitor=watch();
  received=await work(()=>{readerTask=readRawPDFBytesLimited(request,env,{signal:controller.signal,timeoutMs:Math.min(10000,remaining()),
   onReaderCleanup:p=>{readerCleanup=p;scope?.registerCleanup(p);}});return readerTask;});
  if(received instanceof Response)fail('pdf_input_rejected');
  // The HTTP adapter may return response headers only after the admitted upload
  // is fully consumed; returning earlier can cancel the inbound Workers stream.
  onInputConsumed?.();
  verified=await work(()=>verifyRawPDFIntakeBytes(env,session,proof,received,{clock}));
  await work(check);
  // A lost dispatch CAS response is an unknown start: cancel must still tombstone it.
  dispatchAttempted=true;contract=await work(()=>v2?markRawPDFJobDispatchedV2(env,session,proof,job.jobId,token,{clock}):markRawPDFJobDispatched(env,session,proof,job.jobId,token,{clock}));
  await work(check);if(controller.signal.aborted||clock()>=deadline)fail('pdf_processing_cancelled');
  parsed=await work(async()=>{const v=await (v2?parseRawPDFV2(env,contract,verified.bytes):processor.parse(job.jobId,verified.bytes));parseStopped=true;return v;});
  manifest=await work(()=>validateRawPDFManifest(parsed,proof.pdfSha256));
  await work(check);
  // A trusted bounded consumer must finish/drop references before resolving.
  // Public transfer is provisional and must reauthorize before each frame.
  const consumed=await work(()=>consumeResult(manifest,{signal:controller.signal,jobId:job.jobId,
   assertAuthorized:()=>work(check),
   assertSettledAuthorized:()=>requireRawPDFJobExecution(env,session,proof,job.jobId,token,{clock,settled:true})}));
  if(consumed!==undefined)fail('pdf_result_consumer_invalid');
  manifest=undefined;
  received=undefined;verified=undefined;parsed=undefined;
  stopping=true;clearTimeout(monitorTimer);await clean(()=>monitor);
  if(controller.signal.aborted||clock()>=deadline)fail('pdf_processing_cancelled');
  const localConfirmed=await clean(localStopped);if(localConfirmed!==true)fail('pdf_cleanup_unconfirmed');
  readerTask=undefined;readerCleanup=Promise.resolve(true);request=undefined;
  if(scope){
   await clean(()=>scope.sealAndRecord({clock,timeoutMs:Math.max(1,Math.min(10000,cleanupEnd-Date.now()))}));
   remoteStopAttempted=true;
   await clean(()=>confirmRawPDFRemoteStop(env,job.jobId,{clock,rpcV2:v2,timeoutMs:Math.max(1,Math.min(2000,cleanupEnd-Date.now()))}));remoteRecorded=true;
   await clean(()=>settleRawPDFJobFromEvidence(env,job.jobId,{clock,timeoutMs:Math.max(1,Math.min(10000,cleanupEnd-Date.now()))}));
  }else await clean(()=>settleRawPDFJob(env,job.jobId,token,{stopConfirmed:true,clock}));
  // Job-only cancellation after settlement cannot undo adoption; intake revocation can.
  await bounded(()=>requireRawPDFJobExecution(env,session,proof,job.jobId,token,{clock,settled:true}),remaining(),controller.signal);
  return {jobId:job.jobId,consumed:true};
 }catch{
  controller.abort();stopping=true;clearTimeout(monitorTimer);
  if(token){
   // One shared grace deadline; DB failure cannot postpone the independent cancel.
   const stopRequest=clean(()=>requestRawPDFJobStop(env,session,job.jobId)).catch(()=>{});
   const remote=scope&&dispatchAttempted
    ? remoteStopAttempted?Promise.resolve(remoteRecorded):clean(()=>{remoteStopAttempted=true;return confirmRawPDFRemoteStop(env,job.jobId,{clock,rpcV2:v2,timeoutMs:Math.max(1,Math.min(2000,cleanupEnd-Date.now()))});}).then(()=>true,()=>false)
    : dispatchAttempted&&!parseStopped
     ? clean(()=>cancelRawPDFProcessor(env,job.jobId,{v2})).then(v=>v&&typeof v==='object'&&Object.keys(v).length===1&&v.cancelled===true,()=>false)
     : Promise.resolve(true);
   const local=clean(async()=>{
    // Stop/drain monitor and ALL original tasks before clearing references.
    await monitor;const stopped=await localStopped();
    received=undefined;verified=undefined;parsed=undefined;manifest=undefined;
    readerTask=undefined;readerCleanup=Promise.resolve(true);request=undefined;
    if(stopped!==true||Date.now()>=cleanupEnd)return false;
    if(scope)await scope.sealAndRecord({clock,timeoutMs:Math.max(1,Math.min(10000,cleanupEnd-Date.now()))});
    return true;
   }).catch(()=>false);
   const [,remoteStopped,localConfirmed]=await Promise.all([stopRequest,remote,local]);
   if(remoteStopped&&localConfirmed===true&&Date.now()<cleanupEnd)
    await clean(()=>scope?settleRawPDFJobFromEvidence(env,job.jobId,{clock,timeoutMs:Math.max(1,Math.min(10000,cleanupEnd-Date.now()))})
     :settleRawPDFJob(env,job.jobId,token,{stopConfirmed:true,clock})).catch(()=>{});
  }
  return json({error:'pdf_processing_failed'},503);
 }finally{
  stopping=true;clearTimeout(workTimer);clearTimeout(monitorTimer);controller.abort();
  for(const s of signals)s.removeEventListener('abort',abort);
  // watch() owns its errors; late DB/RPC results are observed and never adopted.
 }
}
