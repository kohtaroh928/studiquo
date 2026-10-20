import {json} from '../http.ts';
import {rawPDFPreflightRejection,readRawPDFBytesLimited} from './pdf-preflight.ts';
import {verifyRawPDFIntakeBytes,requireRawPDFIntakeAuthorization} from './pdf-intake.ts';
import {reserveRawPDFJob,claimRawPDFJob,markRawPDFJobDispatched,requestRawPDFJobStop,
 settleRawPDFJob,requireRawPDFJobExecution} from './pdf-jobs.ts';
import {validateRawPDFManifest} from './pdf-manifest.ts';
const fail=(code: any)=>{throw Error(code);};
// An independent timer bounds a stalled DB/RPC. Its timeout is NOT proof of stop.
async function bounded(work: any,ms: any,signal?: any): Promise<any>{
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
export async function processRawPDF(env: any,session: any,input: any,request: any,policy: any,{signal,clock=Date.now,pollMs=250,workMs=180000,cleanupMs=10000,consumeResult,onInputConsumed}: any={}){
 session=Object.freeze({sub:session?.sub});const proof=Object.freeze({...input});
 const preflight=rawPDFPreflightRejection(request.headers,env);if(preflight)return preflight;
 const processor=env.DOCLING_PROCESSOR;
 if(typeof processor?.parse!=='function'||typeof processor?.cancel!=='function'||typeof consumeResult!=='function')return json({error:'pdf_processor_unavailable'},503);
 if(!Number.isInteger(pollMs)||pollMs<1||pollMs>250||!Number.isInteger(workMs)||workMs<1||workMs>180000||!Number.isInteger(cleanupMs)||cleanupMs<1||cleanupMs>10000)
  return json({error:'pdf_processing_unavailable'},503);
 const controller=new AbortController(),signals=[...new Set([signal,request.signal].filter(Boolean))];
 const abort=()=>controller.abort();for(const s of signals){s.addEventListener('abort',abort,{once:true});if(s.aborted)abort();}
 let job: any,token: any,dispatchAttempted=false,parseStopped=false,readerCleanup=Promise.resolve(true),readerTask: any,monitor: any,monitorTimer,workTimer,stopping=false;
 const start=clock();let deadline=start+workMs;
 const remaining=()=>Math.max(1,deadline-clock());
 const check=()=>requireRawPDFJobExecution(env,session,proof,job.jobId,token,{clock});
 const running=new Set();
 const work=(fn: any)=>bounded(()=>{
  const task=Promise.resolve().then(()=>{if(controller.signal.aborted)fail('pdf_processing_cancelled');return fn();});
  running.add(task);task.then(()=>running.delete(task),()=>running.delete(task));return task;
 },remaining(),controller.signal);
 let cleanupEnd;
 const clean=(fn: any)=>{
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
  job=await work(()=>reserveRawPDFJob(env,session,proof,policy,{clock}));deadline=Math.min(deadline,job.deadline,proof.expiresAt);
  const claim=await work(()=>claimRawPDFJob(env,session,proof,job.jobId,{clock}));token=claim.executionToken;
  // Only this token holder has cleanup responsibility; a duplicate loser stops nothing.
  clearTimeout(workTimer);workTimer=setTimeout(abort,remaining());
  monitor=watch();
  let received=await work(()=>{readerTask=readRawPDFBytesLimited(request,env,{signal:controller.signal,timeoutMs:Math.min(10000,remaining()),
   onReaderCleanup:(p: any)=>{readerCleanup=p;}});return readerTask;});
  if(received instanceof Response)fail('pdf_input_rejected');
  // The HTTP adapter may return response headers only after the admitted upload
  // is fully consumed; returning earlier can cancel the inbound Workers stream.
  onInputConsumed?.();
  let verified=await work(()=>verifyRawPDFIntakeBytes(env,session,proof,received,{clock}));
  await work(check);
  // A lost dispatch CAS response is an unknown start: cancel must still tombstone it.
  dispatchAttempted=true;await work(()=>markRawPDFJobDispatched(env,session,proof,job.jobId,token,{clock}));
  await work(check);if(controller.signal.aborted||clock()>=deadline)fail('pdf_processing_cancelled');
  let parsed=await work(async()=>{const v=await processor.parse(job.jobId,verified.bytes);parseStopped=true;return v;});
  let manifest=await work(()=>validateRawPDFManifest(parsed,proof.pdfSha256));
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
  await clean(()=>settleRawPDFJob(env,job.jobId,token,{stopConfirmed:true,clock}));
  // Job-only cancellation after settlement cannot undo adoption; intake revocation can.
  await work(()=>requireRawPDFJobExecution(env,session,proof,job.jobId,token,{clock,settled:true}));
  return {jobId:job.jobId,consumed:true};
 }catch{
  controller.abort();stopping=true;clearTimeout(monitorTimer);
  if(token){
   // One shared grace deadline; DB failure cannot postpone the independent cancel.
   const stopRequest=clean(()=>requestRawPDFJobStop(env,session,job.jobId)).catch(()=>{});
   const remote=dispatchAttempted&&!parseStopped
    ? clean(()=>processor.cancel(job.jobId)).then(v=>v&&typeof v==='object'&&Object.keys(v).length===1&&v.cancelled===true,()=>false)
    : Promise.resolve(true);
   const local=clean(localStopped).catch(()=>false);
   const [,remoteStopped,localConfirmed]=await Promise.all([stopRequest,remote,local]);
   if(remoteStopped&&localConfirmed===true&&Date.now()<cleanupEnd!)
    await clean(()=>settleRawPDFJob(env,job.jobId,token,{stopConfirmed:true,clock})).catch(()=>{});
  }
  return json({error:'pdf_processing_failed'},503);
 }finally{
  stopping=true;clearTimeout(workTimer);clearTimeout(monitorTimer);controller.abort();
  for(const s of signals)s.removeEventListener('abort',abort);
  // watch() owns its errors; late DB/RPC results are observed and never adopted.
 }
}
