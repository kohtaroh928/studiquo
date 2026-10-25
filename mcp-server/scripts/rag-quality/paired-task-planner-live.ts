// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Fixed synthetic paired evaluation; no CLI or key loader. Old evaluators stay frozen.
import fs from 'node:fs';
import {safeTaskPlanDiagnostic} from './task-plan-diagnostic.ts';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {pairedTaskPlannerRequest,pairedTaskPlannerManifest} from './paired-task-planner-request.ts';
import {parsePairedTaskPlannerResponse} from './paired-task-planner-response.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const jsonHash=(x: any)=>hash(JSON.stringify(x));
export const PAIRED_LIMITS=Object.freeze({dispatches:16,stageDispatches:6,reservedMicroUSD:8192,totalReservedMicroUSD:131072,
 requestBytes:24576,responseBytes:262144,timeoutMs:60000,totalMs:360000,pricingDate:'2026-10-15',inputMicroUSDPerToken:0.125,outputMicroUSDPerToken:0.5});
const syncDir=(p: any)=>{const fd=fs.openSync(p,fs.constants.O_RDONLY);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}};
const safe=(p: any,dir: any)=>{const s=fs.lstatSync(p);if(s.isSymbolicLink()||!(dir?s.isDirectory():s.isFile())||s.uid!==process.getuid()||(s.mode&0o777)!==(dir?0o700:0o600)||!dir&&s.nlink!==1)throw Error();return s;};
const keys=(o: any,list: any)=>o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===list.length&&list.every((k: any)=>Object.hasOwn(o,k));
export function pairedLiveManifest(){
 if(arguments.length)throw Error('invalid_paired_manifest');
 const input=pairedTaskPlannerManifest(),jobs=[];
 for(let index=0;index<8;index++)for(const variant of index%2?['candidate','baseline']:['baseline','candidate']){
  const row=input.rows.find(r=>r.index===index&&r.variant===variant);
  const body=JSON.stringify(pairedTaskPlannerRequest(index,variant));
  if(row.requestHash!==hash(body)||Buffer.byteLength(body)>24576)throw Error('paired_input_changed');
  jobs.push({ordinal:jobs.length,index,variant,stage:Math.floor(jobs.length/6),requestHash:row.requestHash});
 }
 const sourceHashes: any={};
 for(const f of ['paired-task-planner-live.ts','paired-task-planner-request.ts','paired-task-planner-response.ts','task-planner-request.ts','task-plan-v2.ts','task-plan-diagnostic.ts'])sourceHashes[f]=hash(fs.readFileSync(new URL(f,import.meta.url) as any));
 return {version:1,suiteId:'task-plan-paired-20261015-v1',input,limits:PAIRED_LIMITS,sourceHashes,jobs};
}
function openLedger(dir: any,freshOnly=false){
 if(typeof dir!=='string'||!path.isAbsolute(dir)||fs.realpathSync(path.dirname(dir))!==path.dirname(dir))throw Error();
 let fresh=false;
 if(freshOnly||!fs.existsSync(dir)){fs.mkdirSync(dir,{mode:0o700});fresh=true;syncDir(path.dirname(dir));}
 safe(dir,true);const lock=path.join(dir,'running.lock');fs.mkdirSync(lock,{mode:0o700});syncDir(dir);
 let fd: any,closed=false;
 try{
  const file=path.join(dir,'journal.ndjson');let expected: any;
  if(fresh){fd=fs.openSync(file,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);fs.fsyncSync(fd);syncDir(dir);}
  else{expected=safe(file,false);fd=fs.openSync(file,fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);}
  const check=()=>{safe(dir,true);safe(lock,true);const s=fs.fstatSync(fd),named=safe(file,false);if(!s.isFile()||s.uid!==process.getuid()||(s.mode&0o777)!==0o600||s.nlink!==1||s.ino!==named.ino||s.dev!==named.dev||s.size>1048576||expected&&(s.ino!==expected.ino||s.dev!==expected.dev))throw Error();return s;};
  check();const raw=fs.readFileSync(fd,'utf8');if(raw&&!raw.endsWith('\n')||!fresh&&!raw)throw Error();
  const records=raw?raw.trimEnd().split('\n').map(JSON.parse):[];let previous: any=null;
  for(const row of records){if(row.previous!==previous)throw Error();previous=jsonHash(row);}
  return {records,append(event: any){const s=check(),row={...event,previous},bytes=Buffer.from(JSON.stringify(row)+'\n');if(s.size+bytes.length>1048576)throw Error();const n=fs.writeSync(fd,bytes,0,bytes.length,s.size);if(n!==bytes.length)throw Error();fs.fsyncSync(fd);previous=jsonHash(row);records.push(row);},
   close(){if(!closed){closed=true;fs.closeSync(fd);}},
   release(){if(!closed)throw Error();safe(lock,true);try{fs.rmdirSync(lock);syncDir(dir);}catch{try{fs.mkdirSync(lock,{mode:0o700});syncDir(dir);}catch{}throw Error();}}};
 }catch{if(fd!==undefined)try{fs.closeSync(fd);}catch{}throw Error();}
}
function validateSaved(row: any,job: any){
 if(!keys(row,['type','ordinal','index','variant','plan','model','usage','requestHash','responseHash','semanticCompleteness','releaseAccepted','elapsedMs','manualReview','previous'])||
  row.ordinal!==job.ordinal||row.index!==job.index||row.variant!==job.variant||row.requestHash!==job.requestHash||!/^([a-f0-9]{64})$/.test(row.responseHash)||
  row.semanticCompleteness!=='pending'||row.releaseAccepted!==false||row.manualReview!=='pending'||!Number.isFinite(row.elapsedMs)||row.elapsedMs<0||row.elapsedMs>60000||
  !keys(row.usage,['input','output','reasoning','total','cached','cacheWrite']))throw Error();
 const u=row.usage,details: any={};if(u.cached!==null)details.cached_tokens=u.cached;if(u.cacheWrite!==null)details.cache_write_tokens=u.cacheWrite;
 const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:row.model,
  output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(row.plan)}]}],
  usage:{input_tokens:u.input,output_tokens:u.output,total_tokens:u.total,output_tokens_details:{reasoning_tokens:u.reasoning},input_tokens_details:details}});
 const checked=parsePairedTaskPlannerResponse(job.index,job.variant,raw);
 if(checked.requestHash!==job.requestHash||Object.keys(u).some(k=>u[k]!==checked.usage[k]))throw Error();
}
function replay(records: any,manifest: any){
 if(!records.length)return {completed:0,stages:0};
 if(!keys(records[0],['type','manifest','previous'])||records[0].type!=='manifest'||jsonHash(records[0].manifest)!==jsonHash(manifest))throw Error();
 let completed=0,stages=0,pending=false;
 for(const row of records.slice(1)){
  const job=manifest.jobs[completed];
  if(row.type==='reserved'){
   if(!job||pending||stages!==job.stage||!keys(row,['type','ordinal','index','variant','requestHash','reservedMicroUSD','previous'])||row.ordinal!==job.ordinal||row.index!==job.index||row.variant!==job.variant||row.requestHash!==job.requestHash||row.reservedMicroUSD!==8192)throw Error();pending=true;
  }else if(row.type==='completed'){
   if(!job||!pending)throw Error();validateSaved(row,job);completed++;pending=false;
  }else if(row.type==='stage_finished'){
   if(pending||!keys(row,['type','stage','completed','previous'])||stages>=3||row.stage!==stages||row.completed!==completed||completed!==Math.min((stages+1)*6,16))throw Error();stages++;
  }else throw Error();
 }
 if(pending||completed!==Math.min(stages*6,16))throw Error();return {completed,stages};
}
async function readJSON(response: any,key: any,signal: any){
 if(!response.ok||!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??'')){void response.body?.cancel().catch(()=>{});throw Error();}
 if(!response.body)throw Error();const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});let size=0,text='';
 const abort=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener('abort',abort,{once:true});
 try{for(;;){const r=await reader.read();if(r.done)break;size+=r.value.byteLength;if(size>262144)throw Error();text+=decoder.decode(r.value,{stream:true});}
  text+=decoder.decode();if(signal.aborted||text.includes(key))throw Error();return text;
 }catch{void reader.cancel().catch(()=>{});throw Error();}finally{signal.removeEventListener('abort',abort);reader.releaseLock();}
}
export async function runPairedPlannerStage(options: any){
 if(arguments.length!==1)throw Error('paired_planner_stopped_audit_required');
 return runStage(options,false);
}
export async function runPairedCandidateDiagnostic(options: any){
 if(arguments.length!==1)throw Error('paired_planner_stopped_audit_required');
 return runStage(options,true);
}
async function runStage(options: any,oneShot: any){
 let ledger;
 try{
  if(!options||typeof options!=='object'||Object.keys(options).some(k=>!['directory','apiKey','fetchImpl','onProgress','timeoutMs','totalMs'].includes(k)))throw Error();
  const {directory,apiKey,fetchImpl=fetch,onProgress=()=>{},timeoutMs=60000,totalMs=360000}=options;
  if(typeof apiKey!=='string'||!/^[A-Za-z0-9_-]{16,512}$/.test(apiKey)||typeof fetchImpl!=='function'||typeof onProgress!=='function'||!Number.isInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000||!Number.isInteger(totalMs)||totalMs<1||totalMs>360000)throw Error();
  const manifest=pairedLiveManifest(),bodies=manifest.jobs.map(job=>{const body=JSON.stringify(pairedTaskPlannerRequest(job.index,job.variant));if(hash(body)!==job.requestHash||body.includes(apiKey)||Buffer.byteLength(body)>24576)throw Error();return body;});
  if(bodies.length!==16||bodies.length*8192>131072)throw Error();
  if(oneShot){manifest.suiteId='task-plan-candidate-diagnostic-20261015-v1';manifest.jobs=[{...manifest.jobs.find(j=>j.index===0&&j.variant==='candidate'),ordinal:0}];manifest.limits={...PAIRED_LIMITS,dispatches:1,stageDispatches:1,totalReservedMicroUSD:8192,totalMs:60000};}
  ledger=openLedger(directory,oneShot);const state=oneShot?{completed:0,stages:0}:replay(ledger.records,manifest);
  if(!ledger.records.length)ledger.append({type:'manifest',manifest});
  if(state.completed===16){ledger.close();ledger.release();return {dispatches:0,completed:16,done:true,reservedMicroUSD:131072};}
  const stage=state.stages,end=oneShot?1:Math.min((stage+1)*6,16),deadline=performance.now()+Math.min(totalMs,oneShot?60000:360000);let completed=state.completed,dispatches=0;
  for(const job of manifest.jobs.slice(completed,end)){
   if(performance.now()>=deadline||dispatches>=6||(completed+1)*8192>131072)throw Error();
   ledger.append({type:'reserved',ordinal:job.ordinal,index:job.index,variant:job.variant,requestHash:job.requestHash,reservedMicroUSD:8192});
   const started=performance.now(),requestDeadline=Math.min(deadline,started+timeoutMs);if(started>=requestDeadline)throw Error();
   const controller=new AbortController();let timer,saving=false,phase='fetch',httpStatus=null;dispatches++;
   try{
    const work=(async()=>{const response=await fetchImpl('https://api.openai.com/v1/responses',{method:'POST',body:oneShot?JSON.stringify(pairedTaskPlannerRequest(0,'candidate')):bodies[job.ordinal],headers:{'content-type':'application/json',authorization:`Bearer ${apiKey}`},redirect:'error',signal:controller.signal});
     if(Number.isInteger(response.status)&&response.status>=100&&response.status<=599)httpStatus=response.status;
     if(controller.signal.aborted){void response.body?.cancel().catch(()=>{});throw Error();}
     phase='body';const raw=await readJSON(response,apiKey,controller.signal);if(controller.signal.aborted)throw Error();
     phase='validation';return parsePairedTaskPlannerResponse(job.index,job.variant,raw);})();
    const result=await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error());},Math.max(1,requestDeadline-performance.now()));})]);
    if(performance.now()>=requestDeadline)throw Error();saving=true;
    ledger.append({type:'completed',ordinal:job.ordinal,...result,elapsedMs:performance.now()-started,manualReview:'pending'});
   }catch(error){
    // Only bounded, fixed categories. Never persist upstream error messages,
    // response bodies, prompts or credentials, including as an exception cause.
    const known=['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','invalid_plan'];
    const code=known.find(c=>error?.message==='task_planner_'+c);
    const reason=controller.signal.aborted?'timeout':httpStatus!==null&&(httpStatus<200||httpStatus>=300)?'upstream_http':phase==='validation'&&code?'task_planner_'+code:phase==='body'?'response_body_failure':'transport_or_unknown';
    const diagnostic=phase==='validation'&&reason==='task_planner_invalid_plan'?safeTaskPlanDiagnostic(error?.taskPlanDiagnostic):null;
    if(!saving)ledger.append({type:'failed',ordinal:job.ordinal,error:'dispatch_failed_or_uncertain',phase,httpStatus,reason,...(diagnostic?{diagnostic}:{})});throw Error();
   }
   finally{clearTimeout(timer);controller.abort();}
   completed++;onProgress({ordinal:job.ordinal,index:job.index,variant:job.variant,completed,stage});
  }
  ledger.append({type:'stage_finished',stage,completed});ledger.close();ledger.release();
  return {stage,dispatches,completed,done:completed===(oneShot?1:16),reservedMicroUSD:completed*8192,semanticReview:'pending',releaseAccepted:false};
 }catch{try{ledger?.close();}catch{}throw Error('paired_planner_stopped_audit_required');}
}
