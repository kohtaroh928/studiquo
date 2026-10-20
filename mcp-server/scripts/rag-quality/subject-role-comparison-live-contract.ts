// Fixed live-suite contracts only. No writes, dispatch, key loading or automatic execution.
import fs from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {subjectRolePairedLedgerManifest} from './subject-role-paired-ledger.ts';
import {subjectRoleTaskPlannerRequest} from './subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse} from './subject-role-task-planner-response.ts';
import {unitPlanReviewBinding,evaluateUnitPlanReview} from './unit-plan-semantic-review.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const jsonHash=(x: any)=>hash(JSON.stringify(x));
const canonical=(x: any): any=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const digest=(x: any)=>jsonHash(canonical(x));
const exact=(x: any,k: any)=>x!==null&&typeof x==='object'&&!Array.isArray(x)&&Object.keys(x).length===k.length&&k.every((n: any)=>Object.hasOwn(x,n));
const hex=(x: any)=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const uuid=(x: any)=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(x);
const fail=()=>{throw Error('subject_role_comparison_audit_required');};
const decode=(raw: any,max: any)=>{if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>max)fail();return JSON.parse(raw);};
export function subjectRoleComparisonLiveManifest(){
 try{
  if(arguments.length)fail();const parent=subjectRolePairedLedgerManifest(),sourceHashes: any={...parent!.sourceHashes};
  for(const f of ['subject-role-comparison-live-contract.ts','subject-role-comparison-live-journal.ts','subject-role-comparison-live.ts','subject-role-review-artifact.ts'])sourceHashes[f]=hash(fs.readFileSync(new URL(f,import.meta.url) as any));
  return {version:2,suiteId:'subject-role-comparison-live-four-stage-v1',contractVersion:4,syntheticOnly:true,
   transportAttached:true,persistenceAttached:true,reviewGateAttached:true,dispatchAuthorized:false,releaseAccepted:false,
   input:parent!.input,limits:parent!.limits,jobs:parent!.jobs,sourceHashes};
 }catch{fail();}
}
export function validateSubjectRoleComparisonLiveCompletion(job: any,result: any,elapsedMs: any){
 try{
  if(arguments.length!==3||!Number.isFinite(elapsedMs)||elapsedMs<0||elapsedMs>60000||
   !exact(result,['index','variant','bindingSource','contractVersion','questionHash','plan','structuralProvenance','model','usage','requestHash','responseHash','semanticCompleteness','evidenceSupport','releaseAccepted'])||!hex(result.responseHash)||
   !exact(result.usage,['input','output','reasoning','total','cached','cacheWrite']))fail();
  const expected=subjectRolePairedLedgerManifest()!.jobs![job?.ordinal as any];if(!expected||!equal(expected,job))fail();
  const u=result.usage,details: any={};if(u.cached!==null)details.cached_tokens=u.cached;if(u.cacheWrite!==null)details.cache_write_tokens=u.cacheWrite;
  const raw=JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:result.model,
   output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(result.plan)}]}],
   usage:{input_tokens:u.input,output_tokens:u.output,total_tokens:u.total,input_tokens_details:details,output_tokens_details:{reasoning_tokens:u.reasoning}}});
  const checked=parseSubjectRoleTaskPlannerResponse(job.index,job.variant,job.requestHash,raw);checked.responseHash=result.responseHash;
  if(!equal(checked,result))fail();return structuredClone(result);
 }catch{fail();}
}
function context(raw: any){
 const c=decode(raw,2097152),m=subjectRoleComparisonLiveManifest(),b=c?.binding;
 if(!exact(c,['binding','completions'])||!exact(b,['stage','completedRequests','checkpointHash','manifestHash','runId'])||!Number.isInteger(b.stage)||b.stage<0||b.stage>3||b.completedRequests!==m!.limits.checkpoints[b.stage]||!hex(b.checkpointHash)||b.manifestHash!==jsonHash(m)||!uuid(b.runId)||!Array.isArray(c.completions))fail();
 const start=b.stage===0?0:m!.limits.checkpoints[b.stage-1],end=m!.limits.checkpoints[b.stage];
 if(c.completions.length!==end-start)fail();
 for(const [i,r] of c.completions.entries()){
  if(!exact(r,['ordinal','result','elapsedMs'])||r.ordinal!==start+i)fail();validateSubjectRoleComparisonLiveCompletion(m!.jobs[r.ordinal],r.result,r.elapsedMs);
 }
 return {c,m};
}
function buildPackets(rawContext: any,ids: any){
 const {c,m}=context(rawContext);if(ids.length!==c.completions.length||ids.some((x: any)=>!uuid(x))||new Set(ids).size!==ids.length)fail();
 const bytes=fs.readFileSync(new URL('role-preservation-oracle-v1.json',import.meta.url) as any);if(hash(bytes)!==m!.sourceHashes['role-preservation-oracle-v1.json'])fail();
 const oracles=JSON.parse(bytes as any).cases,packets=[],mapping=[];
 for(const [i,row] of c.completions.entries()){
  const job=m!.jobs[row.ordinal],r=row.result,question=JSON.parse(subjectRoleTaskPlannerRequest(job.index,job.variant).input[0].content[0].text).question,oracle=oracles[job.index];
  const binding=unitPlanReviewBinding(question,JSON.stringify(r.plan),JSON.stringify(oracle));
  const packet={packetId:ids[i],question,plan:r.plan,structuralProvenance:r.structuralProvenance,oracle};packets.push(packet);
  mapping.push({packetId:packet.packetId,packetHash:digest(packet),ordinal:job.ordinal,pairIndex:job.pairIndex,index:job.index,variant:job.variant,requestHash:job.requestHash,responseHash:r.responseHash,...binding});
 }
 packets.sort((a,b)=>a.packetId.localeCompare(b.packetId));
 const collection={version:1,binding:c.binding,packets,mapping,mappingHash:digest(mapping),transportAttached:true,dispatchAuthorized:false,releaseAccepted:false};
 if(Buffer.byteLength(JSON.stringify(collection))>2097152)fail();return collection;
}
export function createSubjectRoleComparisonLivePackets(rawContext: any){try{if(arguments.length!==1)fail();const {c}=context(rawContext);return buildPackets(rawContext,c.completions.map(()=>randomUUID()));}catch{fail();}}
export function verifySubjectRoleComparisonLivePackets(rawContext: any,rawCollection: any){
 try{
  if(arguments.length!==2)fail();const c=decode(rawCollection,2097152);
  if(!exact(c,['version','binding','packets','mapping','mappingHash','transportAttached','dispatchAuthorized','releaseAccepted'])||!Array.isArray(c.mapping)||c.mapping.length>8)fail();
  const checked=buildPackets(rawContext,c.mapping.map((m: any)=>m?.packetId));if(!equal(c,checked))fail();return checked;
 }catch{fail();}
}
const definite=(r: any)=>r.reviewComplete&&!r.flags.contractUnsupported&&!r.flags.representationUncertain&&r.representationCounts.unsupported===0&&r.representationCounts.uncertain===0&&['reviewed_match','mismatch_detected'].includes(r.semanticStatus);
const matched=(r: any)=>definite(r)&&r.semanticStatus==='reviewed_match'&&Object.values(r.oracleRelativeMissing).every(x=>x===0)&&Object.values(r.oracleRelativeExtra).every(x=>x===0);
export function prepareSubjectRoleComparisonLiveReview(rawContext: any,rawCollection: any,rawBatch: any){
 try{
  if(arguments.length!==3)fail();const c=verifySubjectRoleComparisonLivePackets(rawContext,rawCollection),batch=decode(rawBatch,8388608);
  if(!exact(batch,['version','binding','submissions'])||batch.version!==1||!equal(batch.binding,c!.binding)||!Array.isArray(batch.submissions)||batch.submissions.length!==c!.mapping.length)fail();
  const seen=new Set(),cases: any[]=[];
  for(const s of batch.submissions){
   if(!exact(s,['packetId','packetHash','review'])||typeof s.review!=='string'||!s.review.trim()||Buffer.byteLength(s.review)>262144)fail();
   const job=c!.mapping.find(m=>m.packetId===s.packetId&&m.packetHash===s.packetHash);if(!job||seen.has(job.ordinal))fail();seen.add(job!.ordinal);
   const p=c!.packets.find(p=>p.packetId===job!.packetId),result=evaluateUnitPlanReview(p!.question,JSON.stringify(p!.plan),JSON.stringify(p!.oracle),s.review);
   cases.push({job,reviewHash:digest(JSON.parse(s.review)),result});
  }
  cases.sort((a,b)=>a.job.ordinal-b.job.ordinal);
  const baseline=cases.filter(x=>x.job.variant==='baseline'),candidate=cases.filter(x=>x.job.variant==='candidate');
  const safe=baseline.every(x=>definite(x.result))&&candidate.every(x=>matched(x.result));
  const pairs=baseline.map(b=>cases.filter(x=>x.job.pairIndex===b.job.pairIndex));
  const artifact={version:1,binding:c!.binding,collectionHash:hash(rawCollection),mappingHash:c!.mappingHash,submissions:structuredClone(batch.submissions),cases,
   comparisonDecision:safe?'continue':'stop',stageReviewsComplete:cases.every(x=>x.result.reviewComplete),stageCandidateAllMatched:candidate.every(x=>matched(x.result)),
   stageBaselineMismatchCount:baseline.filter(x=>definite(x.result)&&x.result.semanticStatus==='mismatch_detected').length,
   comparablePairs:pairs.filter(p=>p.length===2&&p.every(x=>definite(x.result))).length,
   dispatchAuthorized:false,transportAttached:true,reviewerAuthenticated:false,humanReviewVerified:false,releaseAccepted:false};
  if(Buffer.byteLength(JSON.stringify(artifact))>8388608)fail();return artifact;
 }catch{fail();}
}
export function verifySubjectRoleComparisonLiveReview(rawContext: any,rawCollection: any,rawArtifact: any){
 try{
  if(arguments.length!==3)fail();const a=decode(rawArtifact,8388608);
  if(!exact(a,['version','binding','collectionHash','mappingHash','submissions','cases','comparisonDecision','stageReviewsComplete','stageCandidateAllMatched','stageBaselineMismatchCount','comparablePairs','dispatchAuthorized','transportAttached','reviewerAuthenticated','humanReviewVerified','releaseAccepted']))fail();
  const checked=prepareSubjectRoleComparisonLiveReview(rawContext,rawCollection,JSON.stringify({version:1,binding:a.binding,submissions:a.submissions}));if(!equal(checked,a))fail();return checked;
 }catch{fail();}
}
