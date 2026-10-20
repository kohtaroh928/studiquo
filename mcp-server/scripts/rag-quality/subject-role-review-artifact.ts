// Offline semantic comparison only. Computed continue is not authorization to send another stage.
import {createHash} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {verifySubjectRoleReviewPackets,resolveSubjectRoleReviewSubmission} from './subject-role-review-packets.ts';
import {evaluateUnitPlanReview} from './unit-plan-semantic-review.ts';
const hash=(x: any)=>createHash('sha256').update(x).digest('hex');
const canonical=(x: any)=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const digest=(x: any)=>hash(JSON.stringify(canonical(x)));
const exact=(x: any,k: any)=>x!==null&&typeof x==='object'&&!Array.isArray(x)&&Object.keys(x).length===k.length&&k.every((n: any)=>Object.hasOwn(x,n));
const fail=()=>{throw Error('subject_role_artifact_audit_required');};
const decode=(raw: any,max: any)=>{if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>max)fail();return JSON.parse(raw);};
const definite=(r: any)=>r.reviewComplete&&!r.flags.contractUnsupported&&!r.flags.representationUncertain&&
 r.representationCounts.unsupported===0&&r.representationCounts.uncertain===0&&['reviewed_match','mismatch_detected'].includes(r.semanticStatus);
const matched=(r: any)=>definite(r)&&r.semanticStatus==='reviewed_match'&&Object.values(r.oracleRelativeMissing).every(x=>x===0)&&Object.values(r.oracleRelativeExtra).every(x=>x===0);
export function prepareSubjectRoleReviewArtifact(rawLedger: any,rawCollection: any,rawSubmissionBatch: any){
 try{
  if(arguments.length!==3)fail();const c=verifySubjectRoleReviewPackets(rawLedger,rawCollection),batch=decode(rawSubmissionBatch,8388608);
  if(!exact(batch,['version','binding','submissions'])||batch.version!==1||!equal(batch.binding,c!.binding)||!Array.isArray(batch.submissions)||batch.submissions.length!==c!.mapping.length)fail();
  const seen=new Set(),cases: any[]=[];
  for(const submission of batch.submissions){
   const resolved=resolveSubjectRoleReviewSubmission(rawLedger,rawCollection,JSON.stringify(submission)),job=resolved!.job;
   if(seen.has(job!.ordinal))fail();seen.add(job!.ordinal);
   const packet=c!.packets.find(p=>p.packetId===job!.packetId);
   const result=evaluateUnitPlanReview(packet!.question,JSON.stringify(packet!.plan),JSON.stringify(packet!.oracle),resolved!.rawReview);
   cases.push({job,reviewHash:digest(JSON.parse(resolved!.rawReview)),result});
  }
  cases.sort((a,b)=>a.job.ordinal-b.job.ordinal);
  const baseline=cases.filter(x=>x.job.variant==='baseline'),candidate=cases.filter(x=>x.job.variant==='candidate');
  const safe=baseline.every(x=>definite(x.result))&&candidate.every(x=>matched(x.result));
  const paired=c!.mapping.filter(x=>x.variant==='baseline').map(b=>cases.filter(x=>x.job.pairIndex===b.pairIndex));
  const artifact={version:1,binding:c!.binding,collectionHash:hash(rawCollection),mappingHash:c!.mappingHash,
   submissions:structuredClone(batch.submissions),cases,comparisonDecision:safe?'continue':'stop',
   stageReviewsComplete:cases.every(x=>x.result.reviewComplete),stageCandidateAllMatched:candidate.every(x=>matched(x.result)),
   stageBaselineMismatchCount:baseline.filter(x=>definite(x.result)&&x.result.semanticStatus==='mismatch_detected').length,
   comparablePairs:paired.filter(pair=>pair.length===2&&pair.every(x=>definite(x.result))).length,
   stage1Authorized:false,transportAttached:false,reviewerAuthenticated:false,humanReviewVerified:false,releaseAccepted:false};
  if(Buffer.byteLength(JSON.stringify(artifact))>8388608)fail();return artifact;
 }catch{fail();}
}
export function verifySubjectRoleReviewArtifact(rawLedger: any,rawCollection: any,rawArtifact: any){
 try{
  if(arguments.length!==3)fail();const a=decode(rawArtifact,8388608);
  if(!exact(a,['version','binding','collectionHash','mappingHash','submissions','cases','comparisonDecision','stageReviewsComplete','stageCandidateAllMatched','stageBaselineMismatchCount','comparablePairs','stage1Authorized','transportAttached','reviewerAuthenticated','humanReviewVerified','releaseAccepted']))fail();
  const checked=prepareSubjectRoleReviewArtifact(rawLedger,rawCollection,JSON.stringify({version:1,binding:a.binding,submissions:a.submissions}));
  if(!equal(a,checked))fail();return checked;
 }catch{fail();}
}
