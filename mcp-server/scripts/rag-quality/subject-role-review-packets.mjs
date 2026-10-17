// Read-only synthetic evaluation packets. No persistence, transport or continuation authority.
import {readFileSync} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {replaySubjectRolePairedLedger} from './subject-role-paired-ledger.mjs';
import {subjectRoleTaskPlannerRequest} from './subject-role-task-planner-request.mjs';
import {unitPlanReviewBinding} from './unit-plan-semantic-review.mjs';
const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])):x;
const digest=x=>createHash('sha256').update(JSON.stringify(canonical(x))).digest('hex');
const hash=x=>createHash('sha256').update(x).digest('hex');
const exact=(x,k)=>x!==null&&typeof x==='object'&&!Array.isArray(x)&&Object.keys(x).length===k.length&&k.every(n=>Object.hasOwn(x,n));
const fail=()=>{throw Error('subject_role_packets_audit_required');};
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(x);
function decode(raw,max){if(typeof raw!=='string'||!raw.trim()||Buffer.byteLength(raw)>max)fail();return JSON.parse(raw);}
function build(rawLedger,ids){
 const state=replaySubjectRolePairedLedger(rawLedger);
 if(state.stage!==0||state.audit!=='pending'||state.completedRequests!==2||!state.safeReopenCheckpoint||ids.length!==2||ids.some(id=>!uuid(id))||new Set(ids).size!==2)fail();
 const rows=rawLedger.slice(0,-1).split('\n').map(JSON.parse),manifest=rows[0].manifest;
 const oracleBytes=readFileSync(new URL('role-preservation-oracle-v1.json',import.meta.url));
 if(hash(oracleBytes)!==manifest.sourceHashes['role-preservation-oracle-v1.json'])fail();
 const oracles=JSON.parse(oracleBytes).cases,packets=[],mapping=[];
 for(const row of rows.filter(r=>r.type==='completed')){
  const job=manifest.jobs[row.ordinal],r=row.result;
  const question=JSON.parse(subjectRoleTaskPlannerRequest(job.index,job.variant).input[0].content[0].text).question;
  const oracle=oracles[job.index],binding=unitPlanReviewBinding(question,JSON.stringify(r.plan),JSON.stringify(oracle));
  const packet={packetId:ids[job.ordinal],question,plan:r.plan,structuralProvenance:r.structuralProvenance,oracle};
  packets.push(packet);mapping.push({packetId:packet.packetId,packetHash:digest(packet),ordinal:job.ordinal,pairIndex:job.pairIndex,
   index:job.index,variant:job.variant,requestHash:job.requestHash,responseHash:r.responseHash,...binding});
 }
 packets.sort((a,b)=>a.packetId.localeCompare(b.packetId));
 return {version:1,binding:{stage:0,completedRequests:2,checkpointHash:state.checkpointHash,manifestHash:state.manifestHash,runId:state.runId},
  packets,mapping,mappingHash:digest(mapping),reviewGateAttached:false,releaseAccepted:false};
}
export function createSubjectRoleReviewPackets(rawLedger){
 try{if(arguments.length!==1)fail();return build(rawLedger,[randomUUID(),randomUUID()]);}catch{fail();}
}
export function verifySubjectRoleReviewPackets(rawLedger,rawCollection){
 try{
  if(arguments.length!==2)fail();const c=decode(rawCollection,2097152);
  if(!exact(c,['version','binding','packets','mapping','mappingHash','reviewGateAttached','releaseAccepted'])||!Array.isArray(c.mapping)||c.mapping.length!==2)fail();
  const checked=build(rawLedger,c.mapping.map(m=>m?.packetId));
  if(!equal(checked,c))fail();return checked;
 }catch{fail();}
}
export function resolveSubjectRoleReviewSubmission(rawLedger,rawCollection,rawSubmission){
 try{
  if(arguments.length!==3)fail();const c=verifySubjectRoleReviewPackets(rawLedger,rawCollection),s=decode(rawSubmission,1048576);
  if(!exact(s,['packetId','packetHash','review'])||typeof s.review!=='string'||!s.review.trim()||Buffer.byteLength(s.review)>262144)fail();
  const job=c.mapping.find(m=>m.packetId===s.packetId&&m.packetHash===s.packetHash);if(!job)fail();
  // This resolves the recipient only. Semantic grading, artifact retention and continue/stop remain unimplemented.
  return {binding:c.binding,job,rawReview:s.review,semanticCompleteness:'pending',evidenceSupport:'unknown',reviewerAuthenticated:false,releaseAccepted:false};
 }catch{fail();}
}
