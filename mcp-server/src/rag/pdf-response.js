import {securityHeaders,json} from '../http.js';
import {sha256Hex} from '../auth.js';
import {processRawPDF} from './pdf-process.js';
const encoder=new TextEncoder(),MAX_BYTES=4*1024*1024,PART_CHARS=16384;
const failure=()=>Error('pdf_transfer_failed');
// Every manifest frame is provisional. Only complete, written after the executor
// drops its references, confirms cleanup/settlement and reauthorizes, is success.
export async function streamRawPDFResponse(env,session,proof,request,policy,{processOptions={},transferMs=30000}={}){
 if(!Number.isInteger(transferMs)||transferMs<1||transferMs>30000)throw failure();
 const controller=new AbortController(),pipe=new TransformStream({
  async transform(frame,output){
   // A guard outside write() can become stale while the reader stalls. Run at
   // actual transform demand, immediately before enqueueing this frame.
   try{
    if(frame.guard)await bounded(frame.guard);
    if(stopped)throw failure();
    output.enqueue(frame.bytes);
   }catch{abort();throw failure();}
  },
 },{highWaterMark:1},{highWaterMark:0});
 const writer=pipe.writable.getWriter();let stopped=false,transferEnd,receipt,settledGuard;
 const abort=()=>{stopped=true;controller.abort();};
 const incomingSignal=request.signal;
 incomingSignal?.addEventListener('abort',abort,{once:true});if(incomingSignal?.aborted)abort();
 writer.closed.catch(abort);
 const bounded=async work=>{
  const ms=transferEnd-Date.now();if(stopped||controller.signal.aborted||ms<=0)throw failure();
  let timer,onAbort;
  try{return await Promise.race([Promise.resolve().then(()=>{if(stopped)throw failure();return work();}),new Promise((_,reject)=>{
   timer=setTimeout(()=>{abort();reject(failure());},ms);onAbort=()=>reject(failure());controller.signal.addEventListener('abort',onAbort,{once:true});
  })]);}finally{clearTimeout(timer);controller.signal.removeEventListener('abort',onAbort);}
 };
 const send=async(frame,guard)=>{
  await bounded(()=>writer.ready);
  if(stopped)throw failure();
  await bounded(()=>writer.write({bytes:encoder.encode(JSON.stringify(frame)+'\n'),guard}));
 };
 const consumeResult=async(manifest,context)=>{
  if(typeof context.assertAuthorized!=='function'||typeof context.assertSettledAuthorized!=='function')throw failure();
  settledGuard=context.assertSettledAuthorized;
  transferEnd=Date.now()+transferMs;
  const onAbort=()=>abort();context.signal.addEventListener('abort',onAbort,{once:true});if(context.signal.aborted)abort();
  let serialized;
  try{
   serialized=JSON.stringify(manifest);
   const byteLength=encoder.encode(serialized).byteLength;if(byteLength>MAX_BYTES)throw failure();
   const manifestSha256=await bounded(()=>sha256Hex(serialized));
   receipt={manifestByteLength:byteLength,manifestSha256,pdfSha256:proof.pdfSha256};
   await send({version:1,type:'begin'},context.assertAuthorized);
   let sequence=0;
   for(let at=0;at<serialized.length;at+=PART_CHARS)
    await send({version:1,type:'manifest',sequence:sequence++,text:serialized.slice(at,at+PART_CHARS)},context.assertAuthorized);
  }finally{serialized=undefined;context.signal.removeEventListener('abort',onAbort);}
 };
 // The open response body, not waitUntil's short grace, owns execution lifetime.
 // The executor retains admission until this consumer has finished sending.
 let inputConsumed;
 const inputReady=new Promise(resolve=>{inputConsumed=()=>resolve({ready:true});});
 const task=processRawPDF(env,session,proof,request,policy,{...processOptions,signal:controller.signal,consumeResult,onInputConsumed:inputConsumed});
 task.then(async result=>{
  if(result instanceof Response||!result?.consumed||!receipt||stopped)throw failure();
  // Executor has already performed its final settled authorization check.
  await send({version:1,type:'complete',jobId:result.jobId,consumed:true,...receipt},settledGuard);
  await bounded(()=>writer.close());
 }).catch(()=>{abort();writer.abort(failure()).catch(()=>{});}).finally(()=>{
  incomingSignal?.removeEventListener('abort',abort);receipt=undefined;settledGuard=undefined;request=undefined;
 });
 // workerd may cancel an unread incoming request body when fetch returns its
 // Response. Preserve reserve/claim-before-read, but do not return HTTP headers
 // until the executor has finished the bounded upload reader.
 const admission=await Promise.race([inputReady,task.then(result=>({result}),()=>({result:null}))]);
 if(!admission.ready){
  abort();pipe.readable.cancel().catch(()=>{});
  return admission.result instanceof Response?admission.result:json({error:'pdf_processing_failed'},503);
 }
 return new Response(pipe.readable,{headers:securityHeaders({'content-type':'application/x-ndjson; charset=utf-8','x-studiquo-pdf-protocol':'1'})});
}
