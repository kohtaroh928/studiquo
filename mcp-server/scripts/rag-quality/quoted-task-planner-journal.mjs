// Fixed v3 journal/review gate. No transport, key loading, CLI or automatic execution.
import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {isDeepStrictEqual} from 'node:util';
import {quotedTaskPlannerRequest,quotedTaskPlannerManifest} from './quoted-task-planner-request.mjs';
import {parseQuotedTaskPlannerResponse} from './quoted-task-planner-response.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const jsonHash=x=>hash(JSON.stringify(x));
const exact=(o,k)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every(x=>Object.hasOwn(o,x));
const hex=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const equal=isDeepStrictEqual;
const fail=()=>{throw Error('quoted_journal_audit_required');};
export const QUOTED_JOURNAL_LIMITS=Object.freeze({dispatches:8,checkpoints:Object.freeze([1,4,8]),reservedMicroUSD:8192,totalReservedMicroUSD:65536,requestBytes:24576,responseBytes:262144,requestMs:60000,stageMs:Object.freeze([60000,180000,240000]),journalBytes:1048576});
export function quotedJournalManifest(){
 if(arguments.length)fail();const input=quotedTaskPlannerManifest(),sourceHashes={};
 for(const file of ['quoted-task-planner-journal.mjs','quoted-task-planner-live.mjs','quoted-task-planner-review.mjs','quoted-task-planner-request.mjs','quoted-task-planner-response.mjs','task-plan-quoted-v3.mjs','task-plan-v2.mjs','paired-task-planner-request.mjs','task-planner-request.mjs','question-task-fixture.mjs','task-plan-paired-draft.json'])sourceHashes[file]=hash(fs.readFileSync(new URL(file,import.meta.url)));
 return {version:2,suiteId:'quoted-task-plan-v3-live-20261015-v1',contractVersion:3,transportAttached:true,input,limits:QUOTED_JOURNAL_LIMITS,sourceHashes,
  jobs:input.rows.map((r,index)=>({index,stage:index<1?0:index<4?1:2,requestHash:r.requestHash,questionHash:r.questionHash}))};
}
function validateCompletion(row,job){
 if(!exact(row,['type','index','contractVersion','quotedPlan','plan','model','usage','requestHash','responseHash','semanticCompleteness','releaseAccepted','elapsedMs','previous'])||row.index!==job.index||row.contractVersion!==3||row.requestHash!==job.requestHash||!hex(row.responseHash)||row.semanticCompleteness!=='pending'||row.releaseAccepted!==false||!Number.isFinite(row.elapsedMs)||row.elapsedMs<0||row.elapsedMs>60000||!exact(row.usage,['input','output','reasoning','total','cached','cacheWrite']))fail();
 const u=row.usage,details={};if(u.cached!==null)details.cached_tokens=u.cached;if(u.cacheWrite!==null)details.cache_write_tokens=u.cacheWrite;
 const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:row.model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(row.quotedPlan)}]}],usage:{input_tokens:u.input,output_tokens:u.output,total_tokens:u.total,output_tokens_details:{reasoning_tokens:u.reasoning},input_tokens_details:details}});
 const checked=parseQuotedTaskPlannerResponse(job.index,raw);
 // Recompute solely from original quotedPlan, never from stored resolved offsets.
 if(!equal(checked.plan,row.plan)||!equal(checked.quotedPlan,row.quotedPlan)||!equal(checked.usage,u)||checked.requestHash!==job.requestHash)fail();
}
const failureReasons=['transport_or_unknown','response_body_failure','upstream_http','timeout',...['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','input','question','shape','quote_shape','quote_ambiguous','quote_not_found','invalid_plan'].map(c=>'quoted_task_planner_'+c)];
const reviewKeys=['stage','completed','checkpointHash','manifestHash','runId','reviewerRole','artifactHash','decision'];
function replay(records,base){
 const first=records[0];if(!exact(first,['type','manifest','runId','previous'])||first.type!=='manifest'||first.previous!==null||!equal(first.manifest,base)||typeof first.runId!=='string'||!/^[-a-f0-9]{36}$/.test(first.runId))fail();
 const state={stage:0,completed:0,pending:null,audit:'not_due',stopped:false,checkpointHash:null,runId:first.runId,manifestHash:jsonHash(first.manifest)};
 let previous=jsonHash(first);
 for(const row of records.slice(1)){
  if(row.previous!==previous||state.stopped)fail();const job=base.jobs[state.completed];
  if(row.type==='reserved'){
   if(!exact(row,['type','index','stage','requestHash','reservedMicroUSD','previous'])||!job||state.pending!==null||state.audit!=='not_due'||state.stage!==job.stage||row.index!==job.index||row.stage!==state.stage||row.requestHash!==job.requestHash||row.reservedMicroUSD!==8192)fail();state.pending=job.index;
  }else if(row.type==='completed'){
   if(!job||state.pending!==job.index)fail();validateCompletion(row,job);state.completed++;state.pending=null;
  }else if(row.type==='stage_finished'){
   if(!exact(row,['type','stage','completed','previous'])||state.pending!==null||state.audit!=='not_due'||state.stage>2||row.stage!==state.stage||row.completed!==state.completed||state.completed!==QUOTED_JOURNAL_LIMITS.checkpoints[state.stage])fail();state.audit='pending';state.checkpointHash=jsonHash(row);
  }else if(row.type==='review'){
   if(!exact(row,['type',...reviewKeys,'previous'])||state.audit!=='pending'||row.stage!==state.stage||row.completed!==state.completed||row.checkpointHash!==state.checkpointHash||row.manifestHash!==state.manifestHash||row.runId!==state.runId||row.reviewerRole!=='independent_scope_reviewer'||!hex(row.artifactHash)||!['continue','stop'].includes(row.decision))fail();
   if(row.decision==='stop'){state.audit='stop';state.stopped=true;}else{state.stage++;state.audit='not_due';}
  }else if(row.type==='failed'){
   if(!exact(row,['type','index','phase','httpStatus','reason','previous'])||state.pending===null||row.index!==state.pending||!['fetch','body','validation'].includes(row.phase)||row.httpStatus!==null&&(!Number.isInteger(row.httpStatus)||row.httpStatus<100||row.httpStatus>599)||!failureReasons.includes(row.reason))fail();state.stopped=true;
  }else fail();previous=jsonHash(row);
 }
 return state;
}
const syncDir=p=>{const fd=fs.openSync(p,fs.constants.O_RDONLY);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}};
function statSafe(p,directory){const s=fs.lstatSync(p);if(s.isSymbolicLink()||!(directory?s.isDirectory():s.isFile())||s.uid!==process.getuid()||(s.mode&0o777)!==(directory?0o700:0o600)||!directory&&s.nlink!==1)fail();return s;}
const same=(a,b)=>a.ino===b.ino&&a.dev===b.dev;
function checkpointState(s){return s.pending===null&&!s.stopped&&(s.audit==='pending'||s.audit==='not_due'&&s.completed===(s.stage===0?0:QUOTED_JOURNAL_LIMITS.checkpoints[s.stage-1]));}
export function openQuotedPlannerJournal(directory){
 let fd,lock,closed=false,poisoned=false,records,state,base,initialDir,initialLock;
 try{
  if(arguments.length!==1||typeof directory!=='string'||!path.isAbsolute(directory)||path.normalize(directory)!==directory||fs.realpathSync(path.dirname(directory))!==path.dirname(directory))fail();
  let fresh=false;try{fs.mkdirSync(directory,{mode:0o700});fresh=true;syncDir(path.dirname(directory));}catch(error){if(error?.code!=='EEXIST')throw error;}
  initialDir=statSafe(directory,true);lock=path.join(directory,'running.lock');fs.mkdirSync(lock,{mode:0o700});initialLock=statSafe(lock,true);syncDir(directory);
  const file=path.join(directory,'journal.ndjson');let expected;
  if(fresh){fd=fs.openSync(file,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);fs.fsyncSync(fd);syncDir(directory);}else{expected=statSafe(file,false);fd=fs.openSync(file,fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);}
  const check=()=>{
   if(closed||poisoned||!same(initialDir,statSafe(directory,true))||!same(initialLock,statSafe(lock,true)))fail();
   const s=fs.fstatSync(fd),named=statSafe(file,false);if(!same(s,named)||expected&&!same(s,expected)||!s.isFile()||s.nlink!==1||s.uid!==process.getuid()||(s.mode&0o777)!==0o600||s.size>1048576)fail();return s;
  };
  check();const raw=new TextDecoder('utf-8',{fatal:true}).decode(fs.readFileSync(fd));if(raw&&!raw.endsWith('\n')||!fresh&&!raw)fail();records=raw?raw.trimEnd().split('\n').map(JSON.parse):[];base=quotedJournalManifest();
  function write(event,deadline){
   const s=check(),row=structuredClone({...event,previous:records.length?jsonHash(records.at(-1)):null}),next=[...records,row];const checked=replay(next,base),bytes=Buffer.from(JSON.stringify(row)+'\n');if(s.size+bytes.length>1048576)fail();
   if(deadline!==undefined&&performance.now()>=deadline)fail();
   if(fs.writeSync(fd,bytes,0,bytes.length,s.size)!==bytes.length)fail();fs.fsyncSync(fd);if(deadline!==undefined&&performance.now()>=deadline)fail();records.push(row);state=checked;
  }
  if(fresh)write({type:'manifest',manifest:base,runId:randomUUID()});else{state=replay(records,base);if(!checkpointState(state))fail();}
  const guard=fn=>(...args)=>{try{check();if(!equal(quotedJournalManifest(),base))fail();return fn(...args);}catch{poisoned=true;fail();}};
  const view=()=>({stage:state.stage,completed:state.completed,pending:state.pending,audit:state.audit,stopped:state.stopped,checkpointHash:state.checkpointHash,manifestHash:state.manifestHash,runId:state.runId,reservedMicroUSD:records.filter(r=>r.type==='reserved').length*8192,generationComplete:state.completed===8,finalReviewComplete:state.completed===8&&state.stage===3});
  return {
   status:guard(function(){if(arguments.length)fail();return view();}),
   reserveNext:guard(function(){
    if(arguments.length||state.pending!==null||state.audit!=='not_due'||state.stopped)fail();const job=base.jobs[state.completed];if(!job||job.stage!==state.stage)fail();
    const body=JSON.stringify(quotedTaskPlannerRequest(job.index));if(hash(body)!==job.requestHash||Buffer.byteLength(body)>24576)fail();
    write({type:'reserved',index:job.index,stage:job.stage,requestHash:job.requestHash,reservedMicroUSD:8192});return structuredClone(job);
   }),
   complete:guard(function(result,elapsedMs,deadline){if(![2,3].includes(arguments.length)||deadline!==undefined&&(!Number.isFinite(deadline)||deadline>performance.now()+60000)||!exact(result,['index','contractVersion','quotedPlan','plan','model','usage','requestHash','responseHash','semanticCompleteness','releaseAccepted']))fail();write({type:'completed',...result,elapsedMs},deadline);return view();}),
   finishStage:guard(function(deadline){if(arguments.length>1||deadline!==undefined&&(!Number.isFinite(deadline)||deadline>performance.now()+240000))fail();write({type:'stage_finished',stage:state.stage,completed:state.completed},deadline);return view();}),
   recordReview:guard(function(review){if(arguments.length!==1||!exact(review,reviewKeys))fail();write({type:'review',...review});return view();}),
   markFailed:guard(function(failure){if(arguments.length!==1||!exact(failure,['phase','httpStatus','reason']))fail();write({type:'failed',index:state.pending,...failure});return view();}),
   close(){
    try{
     if(arguments.length||closed)fail();check();const release=checkpointState(state);closed=true;fs.closeSync(fd);fd=undefined;
     if(release){try{if(!same(initialLock,statSafe(lock,true)))fail();fs.rmdirSync(lock);syncDir(directory);}catch{try{fs.mkdirSync(lock,{mode:0o700});syncDir(directory);}catch{}throw Error();}}
    }catch{poisoned=true;if(!closed){closed=true;try{fs.closeSync(fd);}catch{}}fail();}
   },
  };
 }catch{if(fd!==undefined&&!closed)try{fs.closeSync(fd);}catch{}fail();}
}
