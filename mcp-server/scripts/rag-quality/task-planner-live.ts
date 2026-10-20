// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Evaluation only. No CLI/key loader: network use requires an explicit caller.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {taskPlannerRequest,taskPlannerRequestManifest} from './task-planner-request.ts';
import {parseTaskPlannerResponse} from './task-planner-response.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const syncDir=(dir: any)=>{const fd=fs.openSync(dir,fs.constants.O_RDONLY);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}};
export const TASK_PLANNER_LIMITS=Object.freeze({dispatches:6,requestBytes:24576,responseBytes:262144,
 inputTokens:32768,outputTokens:8192,reservedMicroUSD:8192,totalReservedMicroUSD:49152,
 timeoutMs:60000,totalMs:360000,pricingDate:'2026-10-15',inputMicroUSDPerToken:0.125,outputMicroUSDPerToken:0.5});

function newJournal(dir: any){
 if(typeof dir!=='string'||!path.isAbsolute(dir)||fs.realpathSync(path.dirname(dir))!==path.dirname(dir))throw Error();
 // Exclusive directory creation is also the run lock. Never reopen a run.
 fs.mkdirSync(dir,{mode:0o700});syncDir(path.dirname(dir));
 const d=fs.lstatSync(dir);
 if(!d.isDirectory()||d.isSymbolicLink()||d.uid!==process.getuid()||(d.mode&0o777)!==0o700)throw Error();
 const file=path.join(dir,'journal.ndjson');
 const fd=fs.openSync(file,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);
 try{
  const s=fs.fstatSync(fd),named=fs.lstatSync(file);
  if(!s.isFile()||s.uid!==process.getuid()||(s.mode&0o777)!==0o600||s.nlink!==1||s.dev!==named.dev||s.ino!==named.ino)throw Error();
  fs.fsyncSync(fd);syncDir(dir);
 }catch{fs.closeSync(fd);throw Error();}
 let previous: any=null;
 return {append(event: any){
  const row={...event,previous},bytes=Buffer.from(JSON.stringify(row)+'\n'),s=fs.fstatSync(fd),named=fs.lstatSync(file);
  if(!s.isFile()||s.uid!==process.getuid()||(s.mode&0o777)!==0o600||s.nlink!==1||s.dev!==named.dev||s.ino!==named.ino||s.size+bytes.length>1048576)throw Error();
  const count=fs.writeSync(fd,bytes,0,bytes.length,s.size);if(count!==bytes.length)throw Error();
  fs.fsyncSync(fd);previous=hash(JSON.stringify(row));
 },close(){fs.closeSync(fd);}};
}
async function readJSON(response: any,apiKey: any,signal: any){
 if(!response.ok||!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??'')){
  void response.body?.cancel().catch(()=>{});throw Error();
 }
 if(!response.body)throw Error();
 const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let bytes=0,text='';
 const abort=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener('abort',abort,{once:true});
 try{
  for(;;){const r=await reader.read();if(r.done)break;
   bytes+=r.value.byteLength;if(bytes>TASK_PLANNER_LIMITS.responseBytes)throw Error();
   text+=decoder.decode(r.value,{stream:true});
  }
  text+=decoder.decode();if(signal.aborted||text.includes(apiKey))throw Error();return text;
 }catch{void reader.cancel().catch(()=>{});throw Error();}
 finally{signal.removeEventListener('abort',abort);reader.releaseLock();}
}

export async function runTaskPlanner({directory,apiKey,fetchImpl=fetch,onProgress=()=>{},timeoutMs=60000,totalMs=360000}: any){
 let journal;
 try{
  if(typeof apiKey!=='string'||!/^[A-Za-z0-9_-]{16,512}$/.test(apiKey)||typeof fetchImpl!=='function'||typeof onProgress!=='function'||
   !Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||!Number.isInteger(totalMs)||totalMs<1||totalMs>360000)throw Error();
  const metadata=taskPlannerRequestManifest(),bodies=metadata.rows.map((row,index)=>{
   const body=JSON.stringify(taskPlannerRequest(index));
   if(index!==row.index||hash(body)!==row.requestHash||Buffer.byteLength(body)>24576||body.includes(apiKey))throw Error();return body;
  });
  if(bodies.length!==6||TASK_PLANNER_LIMITS.reservedMicroUSD*6>TASK_PLANNER_LIMITS.totalReservedMicroUSD)throw Error();
  const sourceHashes: any={};
  for(const file of ['task-planner-request.ts','task-planner-response.ts','task-plan-v2.ts','task-planner-live.ts']){
   sourceHashes[file]=hash(fs.readFileSync(new URL(file,import.meta.url) as any));
  }
  journal=newJournal(directory);
  journal.append({type:'manifest',metadata,limits:TASK_PLANNER_LIMITS,sourceHashes});
  const deadline=performance.now()+totalMs;let completed=0;
  for(let index=0;index<bodies.length;index++){
   if(deadline-performance.now()<=0)throw Error();
   // Durable reservation BEFORE fetch. On any uncertainty leave it in place.
   journal.append({type:'reserved',index,requestHash:metadata.rows[index].requestHash,reservedMicroUSD:8192});
   const remaining=deadline-performance.now();if(remaining<=0)throw Error();
   const controller=new AbortController();let timer,savingResult=false;
   try{
    const work=(async()=>{
     const response=await fetchImpl('https://api.openai.com/v1/responses',{method:'POST',body:bodies[index],
      headers:{'content-type':'application/json',authorization:`Bearer ${apiKey}`},redirect:'error',signal:controller.signal});
     // Also covers noncompliant mock/late fetch completion after timeout.
     if(controller.signal.aborted){void response.body?.cancel().catch(()=>{});throw Error();}
     const raw=await readJSON(response,apiKey,controller.signal);
     if(controller.signal.aborted)throw Error();
     return parseTaskPlannerResponse(index,raw);
    })();
    const started=performance.now();
    const result=await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error());},Math.min(timeoutMs,remaining));})]);
    if(performance.now()>=deadline)throw Error();
    savingResult=true;
    journal.append({type:'completed',index,...result,elapsedMs:Math.max(0,performance.now()-started),manualReview:'pending'});
   }catch{
    // A failed completion write may have written bytes without durable sync.
    // Never append a second terminal or retry that uncertain reservation.
    if(!savingResult)journal.append({type:'failed',index,error:'dispatch_failed_or_uncertain'});throw Error();
   }finally{clearTimeout(timer);controller.abort();}
   completed++;onProgress({index,completed});
  }
  return {completed,dispatches:completed,reservedMicroUSD:completed*8192,modelEvaluated:true,semanticReview:'pending',releaseAccepted:false};
 }catch{throw Error('task_planner_run_stopped');}
 finally{try{journal?.close();}catch{throw Error('task_planner_run_stopped');}}
}
