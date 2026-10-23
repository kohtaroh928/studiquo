// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Live-suite persistence; no transport or key loading here. Explicit stage invocation is still required.
import fs from 'node:fs';
import path from 'node:path';
import {performance} from 'node:perf_hooks';
import {createHash,randomUUID} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {subjectRoleComparisonLiveManifest,validateSubjectRoleComparisonLiveCompletion,createSubjectRoleComparisonLivePackets,
 verifySubjectRoleComparisonLivePackets,prepareSubjectRoleComparisonLiveReview,verifySubjectRoleComparisonLiveReview} from './subject-role-comparison-live-contract.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const jsonHash=(x: any)=>hash(JSON.stringify(x));
const exact=(o: any,k: any)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===k.length&&k.every((x: any)=>Object.hasOwn(o,x));
const hex=(x: any)=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const uuid=(x: any)=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(x);
const same=(a: any,b: any)=>a.dev===b.dev&&a.ino===b.ino;
const fail=()=>{throw Error('subject_role_comparison_live_journal_audit_required');};
function deadlineCheck(deadline: any,cap=480000){if(deadline!==undefined&&(!Number.isFinite(deadline)||deadline>performance.now()+cap||performance.now()>=deadline))fail();}
const reasons=['unit_secret_guard_input','unit_secret_guard_json','unit_secret_guard_limits','unit_secret_guard_reflection','transport_or_unknown','response_body_failure','upstream_http','timeout',...['response_size','response_json','not_completed','model_mismatch','invalid_usage','invalid_output','unexpected_output','refused','plan_size','plan_json','shape','question_mismatch','references','label','duplicate_role','invalid_task','status_conflict','plan_limits','resolved_size','invalid_plan','request_mismatch','selector','invalid_arguments'].map(c=>'subject_role_planner_'+c)];
function stat(file: any,directory: any){const s=fs.lstatSync(file);if(s.isSymbolicLink()||!(directory?s.isDirectory():s.isFile())||s.uid!==process.getuid()||(s.mode&0o777)!==(directory?0o700:0o600)||!directory&&s.nlink!==1)fail();return s;}
function syncDir(dir: any){const fd=fs.openSync(dir,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
const collectionName=(s: any)=>'packets-stage-'+s+'.json',artifactName=(s: any)=>'review-stage-'+s+'.json';
const serialize=(rows: any)=>rows.map(JSON.stringify).join('\n')+'\n';
export function openSubjectRoleComparisonLiveJournal(directory: any){
 let fd: any,closed=false,poisoned=false,base: any,initialDir: any,initialLock: any,records: any,expectedRaw: any,state: any;
 const pinned=new Map();
 try{
  if(arguments.length!==1||typeof directory!=='string'||!path.isAbsolute(directory)||path.normalize(directory)!==directory||fs.realpathSync(path.dirname(directory))!==path.dirname(directory))fail();
  base=subjectRoleComparisonLiveManifest();
  let fresh=false;try{fs.mkdirSync(directory,{mode:0o700});fresh=true;syncDir(path.dirname(directory));}catch(e){if(e?.code!=='EEXIST')throw e;}
  initialDir=stat(directory,true);if(fs.realpathSync(directory)!==directory)fail();
  const file=(n: any)=>path.join(directory,n),lock=file('running.lock');fs.mkdirSync(lock,{mode:0o700});initialLock=stat(lock,true);syncDir(directory);
  const identity=()=>{if(closed||poisoned||fs.realpathSync(directory)!==directory||!same(initialDir,stat(directory,true))||!same(initialLock,stat(lock,true)))fail();};
  function read(name: any,limit: any){
   identity();const p=file(name),named=stat(p,false),prior=pinned.get(name);if(prior&&!same(prior,named))fail();let current;
   try{
    current=fs.openSync(p,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);const before=fs.fstatSync(current);
    if(!same(named,before)||before.size>limit||!before.isFile()||before.nlink!==1||before.uid!==process.getuid()||(before.mode&0o777)!==0o600)fail();
    const chunks=[];let count=0;for(;;){const b=Buffer.alloc(Math.min(65536,limit-count+1)),n=fs.readSync(current,b,0,b.length,count);if(!n)break;count+=n;if(count>limit)fail();chunks.push(b.subarray(0,n));}
    const after=fs.fstatSync(current);identity();const afterNamed=stat(p,false);
    if(!same(before,after)||!same(after,afterNamed)||before.size!==after.size||count!==before.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs||before.mode!==after.mode||before.uid!==after.uid||after.nlink!==1)fail();
    pinned.set(name,after);return new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks));
   }finally{if(current!==undefined)fs.closeSync(current);}
  }
  function create(name: any,raw: any,limit: any){
   identity();const bytes=Buffer.from(raw);if(bytes.length>limit)fail();let current;
   try{current=fs.openSync(file(name),fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR|fs.constants.O_NOFOLLOW,0o600);if(fs.writeSync(current,bytes,0,bytes.length,0)!==bytes.length)fail();fs.fsyncSync(current);}finally{if(current!==undefined)fs.closeSync(current);}
   syncDir(directory);if(read(name,limit)!==raw)fail();
  }
  function replay(rows: any){
   if(!Array.isArray(rows)||rows.length<1||rows.length>128||!exact(rows[0],['type','manifest','runId','previous'])||rows[0].type!=='manifest'||rows[0].previous!==null||!uuid(rows[0].runId)||!equal(rows[0].manifest,base))fail();
   const allowed=['journal.ndjson','running.lock'];
   for(const row of rows)if(row.type==='packets_ready'||row.type==='review'){if(!Number.isInteger(row.stage)||row.stage<0||row.stage>3)fail();allowed.push(row.type==='packets_ready'?collectionName(row.stage):artifactName(row.stage));}
   if(new Set(allowed).size!==allowed.length||!equal(fs.readdirSync(directory).sort(),allowed.sort()))fail();
   const s={runId:rows[0].runId,manifestHash:jsonHash(base),stage:0,phase:'running',completed:0,pending:null,failedOrdinal:null,stopped:false,reserved:0,completions:[],contexts:[],collections:[],artifacts:[],stageReserved:[0,0,0,0],stageElapsed:[0,0,0,0]};
   let previous=jsonHash(rows[0]);
   for(const row of rows.slice(1)){
    if(!row||row.previous!==previous||s.stopped||s.phase==='done')fail();const job=base.jobs[s.completed];
    if(row.type==='reserved'){
     if(!exact(row,['type','job','reservedMicroUSD','previous'])||s.phase!=='running'||s.pending!==null||!job||job.stage!==s.stage||!equal(row.job,job)||row.reservedMicroUSD!==8192||s.reserved>=24||s.stageReserved[s.stage]*8192>=base.limits.stageReservedMicroUSD[s.stage])fail();
     s.pending=job.ordinal;s.reserved++;s.stageReserved[s.stage]++;
    }else if(row.type==='completed'){
     if(!exact(row,['type','ordinal','result','elapsedMs','previous'])||s.pending===null||s.pending!==job?.ordinal||row.ordinal!==job.ordinal)fail();
     validateSubjectRoleComparisonLiveCompletion(job,row.result,row.elapsedMs);s.stageElapsed[s.stage]+=row.elapsedMs;if(s.stageElapsed[s.stage]>base.limits.stageMs[s.stage])fail();
     s.completions.push({ordinal:row.ordinal,result:row.result,elapsedMs:row.elapsedMs});s.completed++;s.pending=null;
    }else if(row.type==='failed'){
     if(!exact(row,['type','ordinal','phase','httpStatus','reason','previous'])||s.pending===null||row.ordinal!==s.pending||!['fetch','body','validation'].includes(row.phase)||row.httpStatus!==null&&(!Number.isInteger(row.httpStatus)||row.httpStatus<100||row.httpStatus>599)||!reasons.includes(row.reason))fail();
     s.failedOrdinal=s.pending;s.pending=null;s.stopped=true;s.phase='technical_stop';
    }else if(row.type==='stage_finished'){
     if(!exact(row,['type','stage','completedRequests','completedPairs','previous'])||s.phase!=='running'||s.pending!==null||row.stage!==s.stage||row.completedRequests!==s.completed||row.completedPairs!==s.completed/2||s.completed!==base.limits.checkpoints[s.stage])fail();
     s.phase='checkpoint';s.contexts[s.stage]={binding:{stage:s.stage,completedRequests:s.completed,checkpointHash:jsonHash(row),manifestHash:s.manifestHash,runId:s.runId},completions:s.completions.filter(c=>base.jobs[c.ordinal].stage===s.stage)};
    }else if(row.type==='packets_ready'){
     if(!exact(row,['type','stage','collectionHash','mappingHash','previous'])||s.phase!=='checkpoint'||row.stage!==s.stage||!hex(row.collectionHash)||!hex(row.mappingHash))fail();
     const raw=read(collectionName(s.stage),base.limits.collectionBytes);if(hash(raw)!==row.collectionHash)fail();
     const c=verifySubjectRoleComparisonLivePackets(JSON.stringify(s.contexts[s.stage]),raw);if(c!.mappingHash!==row.mappingHash)fail();s.collections[s.stage]=c;s.phase='packets';
    }else if(row.type==='review'){
     if(!exact(row,['type','stage','artifactHash','comparisonDecision','casesHash','previous'])||s.phase!=='packets'||row.stage!==s.stage||!hex(row.artifactHash)||!hex(row.casesHash)||!['continue','stop'].includes(row.comparisonDecision))fail();
     const raw=read(artifactName(s.stage),base.limits.artifactBytes);if(hash(raw)!==row.artifactHash)fail();
     const a=verifySubjectRoleComparisonLiveReview(JSON.stringify(s.contexts[s.stage]),read(collectionName(s.stage),base.limits.collectionBytes),raw);
     if(a!.comparisonDecision!==row.comparisonDecision||jsonHash(a!.cases)!==row.casesHash)fail();s.artifacts[s.stage]=a;
     if(a!.comparisonDecision==='stop'){s.phase='semantic_stop';s.stopped=true;}else{s.stage++;s.phase=s.stage===4?'done':'running';}
    }else fail();previous=jsonHash(row);
   }
   s.tailHash=previous;return s;
  }
  function checkJournal(){identity();if(!equal(subjectRoleComparisonLiveManifest(),base)||read('journal.ndjson',base.limits.journalBytes)!==expectedRaw)fail();}
  function audit(){checkJournal();state=replay(records);return state;}
  function append(event: any,deadline: any){
   deadlineCheck(deadline);checkJournal();const copy=structuredClone(event);if(!equal(JSON.parse(JSON.stringify(copy)),copy))fail();
   const row={...copy,previous:jsonHash(records.at(-1))},next=[...records,row],checked=replay(next),raw=serialize(next),bytes=Buffer.from(JSON.stringify(row)+'\n');if(Buffer.byteLength(raw)>base.limits.journalBytes)fail();
   deadlineCheck(deadline);const held=fs.fstatSync(fd);if(!same(held,stat(file('journal.ndjson'),false))||!same(held,pinned.get('journal.ndjson'))||held.size!==Buffer.byteLength(expectedRaw))fail();
   if(fs.writeSync(fd,bytes,0,bytes.length,held.size)!==bytes.length)fail();fs.fsyncSync(fd);deadlineCheck(deadline);if(read('journal.ndjson',base.limits.journalBytes)!==raw)fail();deadlineCheck(deadline);
   records=next;state=checked;expectedRaw=raw;
  }
  const safe=(s: any)=>!s.stopped&&s.pending===null&&(['checkpoint','packets','done'].includes(s.phase)||s.phase==='running'&&s.completed===(s.stage===0?0:base.limits.checkpoints[s.stage-1]));
  if(fresh){records=[{type:'manifest',manifest:base,runId:randomUUID(),previous:null}];expectedRaw=serialize(records);create('journal.ndjson',expectedRaw,base!.limits.journalBytes);}
  else{expectedRaw=read('journal.ndjson',base!.limits.journalBytes);if(!expectedRaw.endsWith('\n'))fail();records=expectedRaw.slice(0,-1).split('\n').map(JSON.parse);if(serialize(records)!==expectedRaw)fail();}
  state=replay(records);if(!fresh&&!safe(state))fail();fd=fs.openSync(file('journal.ndjson'),fs.constants.O_RDWR|fs.constants.O_NOFOLLOW);if(!same(fs.fstatSync(fd),pinned.get('journal.ndjson')))fail();
  function view(){
   const arts=state.artifacts.filter(Boolean),cases=arts.flatMap((a: any)=>a.cases),allReviewsComplete=state.completed===24&&cases.length===24&&cases.every((c: any)=>c.result.reviewComplete);
   const mismatch=arts.reduce((n: any,a: any)=>n+a.stageBaselineMismatchCount,0),current=state.contexts[state.stage]?.binding??null;
   return structuredClone({runId:state.runId,manifestHash:state.manifestHash,tailHash:state.tailHash,stage:state.stage,phase:state.phase,pending:state.pending,failedOrdinal:state.failedOrdinal,stopped:state.stopped,binding:current,
    completedRequests:state.completed,baselineCompleted:state.completions.filter((c: any)=>c.result.variant==='baseline').length,candidateCompleted:state.completions.filter((c: any)=>c.result.variant==='candidate').length,
    technicalCompletedPairs:Math.floor(state.completed/2),partialPairs:state.completed%2,plannedPairs:12,reservedRequests:state.reserved,reservedPairs:Math.ceil(state.reserved/2),unreservedPairs:12-Math.ceil(state.reserved/2),reservedMicroUSD:state.reserved*8192,
    generationComplete:state.completed===24,allReviewsComplete,reviewArtifactsRecorded:arts.length,reviewedRequests:cases.filter((c: any)=>c.result.reviewComplete).length,
    comparablePairs:arts.reduce((n: any,a: any)=>n+a.comparablePairs,0),observedBaselineMismatchCount:mismatch,baselineMismatchCount:allReviewsComplete?mismatch:null,
    observedCandidateAllMatched:arts.length?arts.every((a: any)=>a.stageCandidateAllMatched):null,candidateAllMatched:allReviewsComplete?arts.every((a: any)=>a.stageCandidateAllMatched):null,
    finalDecision:state.phase==='done'?'continue':state.phase==='technical_stop'?'technical_stop':state.phase==='semantic_stop'?'stop':'pending',
    safeReopenCheckpoint:safe(state),transportAttached:true,dispatchAuthorized:false,reviewerAuthenticated:false,humanReviewVerified:false,releaseAccepted:false});
  }
  const guard=(fn: any)=>function(...args: any[]){try{audit();return fn(...args);}catch{poisoned=true;fail();}};
  return {
   status:guard(function(){if(arguments.length)fail();return view();}),
   reserveNext:guard(function(deadline: any){if(arguments.length!==1||!Number.isFinite(deadline)||state.phase!=='running'||state.pending!==null||state.stopped||state.stage>=4)fail();deadlineCheck(deadline,base.limits.stageMs[state.stage]);const job=base.jobs[state.completed];append({type:'reserved',job,reservedMicroUSD:8192},deadline);return structuredClone(job);}),
   complete:guard(function(result: any,elapsedMs: any,deadline: any){if(arguments.length!==3||!Number.isFinite(deadline)||state.pending===null)fail();deadlineCheck(deadline,60000);append({type:'completed',ordinal:state.pending,result,elapsedMs},deadline);return view();}),
   markFailed:guard(function(failure: any){if(arguments.length!==1||!exact(failure,['phase','httpStatus','reason']))fail();append({type:'failed',ordinal:state.pending,...failure});return view();}),
   finishStage:guard(function(deadline: any){if(arguments.length!==1||!Number.isFinite(deadline))fail();deadlineCheck(deadline,base.limits.stageMs[state.stage]);append({type:'stage_finished',stage:state.stage,completedRequests:state.completed,completedPairs:state.completed/2},deadline);return view();}),
   preparePackets:guard(function(){if(arguments.length||state.phase!=='checkpoint')fail();const c=createSubjectRoleComparisonLivePackets(JSON.stringify(state.contexts[state.stage])),raw=JSON.stringify(c);create(collectionName(state.stage),raw,base.limits.collectionBytes);append({type:'packets_ready',stage:state.stage,collectionHash:hash(raw),mappingHash:c!.mappingHash});return view();}),
   exportPackets:guard(function(stage: any){if(arguments.length!==1||!Number.isInteger(stage)||!state.collections[stage])fail();const c=state.collections[stage];return c.packets.map((packet: any)=>({packet:structuredClone(packet),packetHash:c.mapping.find((m: any)=>m.packetId===packet.packetId).packetHash}));}),
   recordReview:guard(function(rawBatch: any){if(arguments.length!==1||state.phase!=='packets')fail();const stage=state.stage,rawCollection=read(collectionName(stage),base.limits.collectionBytes),a=prepareSubjectRoleComparisonLiveReview(JSON.stringify(state.contexts[stage]),rawCollection,rawBatch),raw=JSON.stringify(a);create(artifactName(stage),raw,base.limits.artifactBytes);append({type:'review',stage,artifactHash:hash(raw),comparisonDecision:a!.comparisonDecision,casesHash:jsonHash(a!.cases)});return view();}),
   close(deadline: any){
    let release=false;
    try{if(arguments.length>1)fail();deadlineCheck(deadline);audit();deadlineCheck(deadline);release=safe(state);const current=fd;fd=undefined;closed=true;fs.closeSync(current);if(release){if(!same(initialDir,stat(directory,true))||!same(initialLock,stat(lock,true)))fail();fs.rmdirSync(lock);syncDir(directory);}deadlineCheck(deadline);}
    catch{poisoned=true;if(fd!==undefined){const current=fd;fd=undefined;closed=true;try{fs.closeSync(current);}catch{}}if(release)try{if(same(initialDir,stat(directory,true))&&!fs.existsSync(lock)){fs.mkdirSync(lock,{mode:0o700});syncDir(directory);}}catch{}fail();}
   },
  };
 }catch{if(fd!==undefined)try{fs.closeSync(fd);}catch{}fail();}
}
