// Live v4 journal with retained semantic artifacts. No transport, key loading, CLI or automatic execution.
import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {isDeepStrictEqual} from 'node:util';
import {prepareUnitReviewArtifact,verifyUnitReviewArtifact} from './unit-task-planner-artifact.mjs';
import {unitTaskPlannerRequest,unitTaskPlannerManifest} from './unit-task-planner-request.mjs';
import {parseUnitTaskPlannerResponse} from './unit-task-planner-response.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const jsonHash=x=>hash(JSON.stringify(x));
const exact=(o,k)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every(x=>Object.hasOwn(o,x));
const hex=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const equal=isDeepStrictEqual;
const fail=()=>{throw Error('unit_journal_audit_required');};
export const UNIT_LIVE_JOURNAL_LIMITS=Object.freeze({dispatches:8,checkpoints:Object.freeze([1,4,8]),reservedMicroUSD:8192,totalReservedMicroUSD:65536,requestBytes:32768,responseBytes:262144,requestMs:60000,stageMs:Object.freeze([60000,180000,240000]),journalBytes:1048576});
export function unitLiveJournalManifest(){
 if(arguments.length)fail();const input=unitTaskPlannerManifest(),sourceHashes={};
 for(const file of ['unit-task-planner-live-journal.mjs','unit-task-planner-live.mjs','unit-task-planner-live-review.mjs','unit-task-planner-secret-guard.mjs','unit-task-planner-artifact.mjs','unit-task-planner-request.mjs','unit-task-planner-response.mjs','question-units.mjs','task-plan-units-v4.mjs','unit-plan-semantic-review.mjs','task-plan-paired-oracle-v1.json','task-plan-v2.mjs','paired-task-planner-request.mjs','task-planner-request.mjs','question-task-fixture.mjs','task-plan-paired-draft.json'])sourceHashes[file]=hash(fs.readFileSync(new URL(file,import.meta.url)));
 return {version:2,suiteId:'unit-task-plan-v4-live-20261015-v1',contractVersion:4,transportAttached:true,input,limits:UNIT_LIVE_JOURNAL_LIMITS,sourceHashes,

  jobs:input.rows.map((r,index)=>({index,stage:index<1?0:index<4?1:2,requestHash:r.requestHash,questionHash:r.questionHash}))};
}
function validateCompletion(row,job){
 if(!exact(row,['type','index','contractVersion','questionHash','plan','structuralProvenance','model','usage','requestHash','responseHash','semanticCompleteness','evidenceSupport','releaseAccepted','elapsedMs','previous'])||row.index!==job.index||row.contractVersion!==4||row.requestHash!==job.requestHash||!hex(row.responseHash)||row.semanticCompleteness!=='pending'||row.evidenceSupport!=='unknown'||row.questionHash!==job.questionHash||row.releaseAccepted!==false||!Number.isFinite(row.elapsedMs)||row.elapsedMs<0||row.elapsedMs>60000||!exact(row.usage,['input','output','reasoning','total','cached','cacheWrite']))fail();
 const u=row.usage,details={};if(u.cached!==null)details.cached_tokens=u.cached;if(u.cacheWrite!==null)details.cache_write_tokens=u.cacheWrite;
 const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:row.model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(row.plan)}]}],usage:{input_tokens:u.input,output_tokens:u.output,total_tokens:u.total,output_tokens_details:{reasoning_tokens:u.reasoning},input_tokens_details:details}});
 const checked=parseUnitTaskPlannerResponse(job.index,raw);
 // Recompute from candidate plan and fixed question, never trust saved provenance.
 if(!equal(checked.plan,row.plan)||!equal(checked.structuralProvenance,row.structuralProvenance)||checked.questionHash!==row.questionHash||!equal(checked.usage,u)||checked.requestHash!==job.requestHash)fail();
}
const failureReasons=['unit_secret_guard_input','unit_secret_guard_json','unit_secret_guard_limits','unit_secret_guard_reflection','transport_or_unknown','response_body_failure','upstream_http','timeout',...['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','shape','question_mismatch','references','label','duplicate_role','invalid_task','status_conflict','plan_limits','resolved_size','invalid_plan'].map(c=>'unit_task_planner_'+c)];
const oracles=JSON.parse(fs.readFileSync(new URL('task-plan-paired-oracle-v1.json',import.meta.url))).cases;
const reviewKeys=['stage','completed','checkpointHash','manifestHash','runId','reviewerRole','artifactHash','decision','caseSummaries'];
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
   if(!exact(row,['type','stage','completed','previous'])||state.pending!==null||state.audit!=='not_due'||state.stage>2||row.stage!==state.stage||row.completed!==state.completed||state.completed!==UNIT_LIVE_JOURNAL_LIMITS.checkpoints[state.stage])fail();state.audit='pending';state.checkpointHash=jsonHash(row);
  }else if(row.type==='review'){
   if(!exact(row,['type',...reviewKeys,'previous'])||state.audit!=='pending'||row.stage!==state.stage||row.completed!==state.completed||row.checkpointHash!==state.checkpointHash||row.manifestHash!==state.manifestHash||row.runId!==state.runId||row.reviewerRole!=='independent_scope_reviewer'||!hex(row.artifactHash)||!['continue','stop'].includes(row.decision)||!Array.isArray(row.caseSummaries))fail();
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
function readPrivate(file,limit){
 const before=statSafe(file,false);let fd;
 try{
  fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);const first=fs.fstatSync(fd);
  if(!same(first,before)||first.size>limit||first.nlink!==1||!first.isFile()||first.uid!==process.getuid()||(first.mode&0o777)!==0o600)fail();
  const chunks=[];let count=0;for(;;){const b=Buffer.alloc(Math.min(65536,limit-count+1)),n=fs.readSync(fd,b,0,b.length,null);if(!n)break;count+=n;if(count>limit)fail();chunks.push(b.subarray(0,n));}
  const after=fs.fstatSync(fd);if(!same(after,first)||after.size!==first.size||count!==first.size||after.mtimeMs!==first.mtimeMs||after.ctimeMs!==first.ctimeMs||after.nlink!==1||after.uid!==first.uid||after.mode!==first.mode||!same(after,statSafe(file,false)))fail();
  return new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks));
 }finally{if(fd!==undefined)fs.closeSync(fd);}
}
const artifactFile=(directory,stage)=>path.join(directory,'review-stage-'+stage+'.json');
const reviewBinding=r=>Object.fromEntries(['stage','completed','checkpointHash','manifestHash','runId'].map(k=>[k,r[k]]));
function validateArtifacts(directory,records,base){
 const reviews=records.filter(r=>r.type==='review');
 for(let stage=0;stage<3;stage++){
  const file=artifactFile(directory,stage),row=reviews.find(r=>r.stage===stage);
  if(!row){if(fs.existsSync(file)||fs.readdirSync(directory).includes(path.basename(file)))fail();continue;}
  const raw=readPrivate(file,2097152);if(hash(raw)!==row.artifactHash)fail();
  const completions=records.filter(r=>r.type==='completed'&&base.jobs[r.index]?.stage===stage),artifact=verifyUnitReviewArtifact(raw,reviewBinding(row),completions,oracles);
  if(artifact.review.decision!==row.decision||!equal(artifact.caseSummaries,row.caseSummaries))fail();
 }
}
function writeArtifact(directory,stage,raw){
 const file=artifactFile(directory,stage),bytes=Buffer.from(raw);if(bytes.length>2097152)fail();let fd;
 try{fd=fs.openSync(file,fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);if(fs.writeSync(fd,bytes,0,bytes.length,0)!==bytes.length)fail();fs.fsyncSync(fd);}finally{if(fd!==undefined)fs.closeSync(fd);}
 syncDir(directory);if(readPrivate(file,2097152)!==raw)fail();
}
function checkpointState(s){return s.pending===null&&!s.stopped&&(s.audit==='pending'||s.audit==='not_due'&&s.completed===(s.stage===0?0:UNIT_LIVE_JOURNAL_LIMITS.checkpoints[s.stage-1]));}
export function openUnitLivePlannerJournal(directory){
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
  check();const raw=new TextDecoder('utf-8',{fatal:true}).decode(fs.readFileSync(fd));if(raw&&!raw.endsWith('\n')||!fresh&&!raw)fail();records=raw?raw.trimEnd().split('\n').map(JSON.parse):[];base=unitLiveJournalManifest();
  function write(event,deadline){
   const s=check(),row=structuredClone({...event,previous:records.length?jsonHash(records.at(-1)):null}),next=[...records,row];const checked=replay(next,base);validateArtifacts(directory,next,base);const bytes=Buffer.from(JSON.stringify(row)+'\n');if(s.size+bytes.length>1048576)fail();
   if(deadline!==undefined&&performance.now()>=deadline)fail();
   if(fs.writeSync(fd,bytes,0,bytes.length,s.size)!==bytes.length)fail();fs.fsyncSync(fd);if(deadline!==undefined&&performance.now()>=deadline)fail();records.push(row);state=checked;
  }
  if(fresh)write({type:'manifest',manifest:base,runId:randomUUID()});else{state=replay(records,base);validateArtifacts(directory,records,base);if(!checkpointState(state))fail();}
  const guard=fn=>(...args)=>{try{check();if(!equal(unitLiveJournalManifest(),base))fail();validateArtifacts(directory,records,base);return fn(...args);}catch{poisoned=true;fail();}};
  const view=()=>({stage:state.stage,completed:state.completed,pending:state.pending,audit:state.audit,stopped:state.stopped,checkpointHash:state.checkpointHash,manifestHash:state.manifestHash,runId:state.runId,reservedMicroUSD:records.filter(r=>r.type==='reserved').length*8192,generationComplete:state.completed===8,finalReviewComplete:state.completed===8&&state.stage===3});
  return {
   status:guard(function(){if(arguments.length)fail();return view();}),
   reserveNext:guard(function(){
    if(arguments.length||state.pending!==null||state.audit!=='not_due'||state.stopped)fail();const job=base.jobs[state.completed];if(!job||job.stage!==state.stage)fail();
    const body=JSON.stringify(unitTaskPlannerRequest(job.index));if(hash(body)!==job.requestHash||Buffer.byteLength(body)>32768)fail();
    write({type:'reserved',index:job.index,stage:job.stage,requestHash:job.requestHash,reservedMicroUSD:8192});return structuredClone(job);
   }),
   complete:guard(function(result,elapsedMs,deadline){if(![2,3].includes(arguments.length)||deadline!==undefined&&(!Number.isFinite(deadline)||deadline>performance.now()+60000)||!exact(result,['index','contractVersion','questionHash','plan','structuralProvenance','model','usage','requestHash','responseHash','semanticCompleteness','evidenceSupport','releaseAccepted']))fail();write({type:'completed',...result,elapsedMs},deadline);return view();}),
   finishStage:guard(function(deadline){if(arguments.length>1||deadline!==undefined&&(!Number.isFinite(deadline)||deadline>performance.now()+240000))fail();write({type:'stage_finished',stage:state.stage,completed:state.completed},deadline);return view();}),
   recordReview:guard(function(review){
    if(arguments.length!==1||state.audit!=='pending'||state.stopped)fail();
    const binding=reviewBinding(view()),completions=records.filter(r=>r.type==='completed'&&base.jobs[r.index]?.stage===state.stage);
    const artifact=prepareUnitReviewArtifact(review,binding,completions,oracles),raw=JSON.stringify(artifact);
    writeArtifact(directory,state.stage,raw);
    write({type:'review',...binding,reviewerRole:'independent_scope_reviewer',artifactHash:hash(raw),decision:artifact.review.decision,caseSummaries:artifact.caseSummaries});return view();
   }),
   markFailed:guard(function(failure){if(arguments.length!==1||!exact(failure,['phase','httpStatus','reason']))fail();write({type:'failed',index:state.pending,...failure});return view();}),
   close(){
    try{
     if(arguments.length||closed)fail();check();validateArtifacts(directory,records,base);const release=checkpointState(state);closed=true;fs.closeSync(fd);fd=undefined;
     if(release){try{if(!same(initialLock,statSafe(lock,true)))fail();fs.rmdirSync(lock);syncDir(directory);}catch{try{fs.mkdirSync(lock,{mode:0o700});syncDir(directory);}catch{}throw Error();}}
    }catch{poisoned=true;if(!closed){closed=true;try{fs.closeSync(fd);}catch{}}fail();}
   },
  };
 }catch{if(fd!==undefined&&!closed)try{fs.closeSync(fd);}catch{}fail();}
}
