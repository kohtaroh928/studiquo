// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {subjectRolePairedLedgerManifest as manifest,replaySubjectRolePairedLedger as replay} from '../scripts/rag-quality/subject-role-paired-ledger.ts';
import {subjectRoleTaskPlannerRequest as request} from '../scripts/rag-quality/subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse as parse} from '../scripts/rag-quality/subject-role-task-planner-response.ts';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.ts';
const hash=x=>createHash('sha256').update(x).digest('hex');
const cases=JSON.parse(readFileSync(new URL('../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url))).cases;
const runId='aa000000-0000-4000-8000-000000000000';
const seed=()=>[{type:'manifest',manifest:manifest(),runId,previous:null}];
const append=(rows,row)=>{rows.push({...structuredClone(row),previous:hash(JSON.stringify(rows.at(-1)))});return rows;};
const encode=rows=>rows.map(JSON.stringify).join('\n')+'\n';
const run=rows=>replay(encode(rows));
const reserve=(rows,ordinal)=>append(rows,{type:'reserved',job:rows[0].manifest.jobs[ordinal],reservedMicroUSD:8192});
function completion(job){
 const c=cases[job.index],source=createQuestionUnits(c.question),refs=s=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=s=>({label:s.text,unitIds:refs(s)});
 const plan={version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 const body={object:'response',status:'completed',error:null,incomplete_details:null,model:request(job.index,job.variant).model,
  output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],
  usage:{input_tokens:200,output_tokens:300,total_tokens:500,input_tokens_details:{cached_tokens:0,cache_write_tokens:100},output_tokens_details:{reasoning_tokens:50}}};
 return {type:'completed',ordinal:job.ordinal,result:parse(job.index,job.variant,job.requestHash,JSON.stringify(body)),elapsedMs:100};
}
const complete=(rows,ordinal)=>append(rows,completion(rows[0].manifest.jobs[ordinal]));
const stage=()=>{const r=seed();reserve(r,0);complete(r,0);reserve(r,1);complete(r,1);append(r,{type:'stage_finished',stage:0,completedRequests:2,completedPairs:1});return r;};
const rejected=rows=>assert.throws(()=>run(rows),e=>e.message==='subject_role_ledger_audit_required');
const rechain=rows=>{rows[0].previous=null;for(let i=1;i<rows.length;i++)rows[i].previous=hash(JSON.stringify(rows[i-1]));return rows;};

test('manifest freezes 24 alternating jobs, four stage caps and all request bindings',()=>{
 const m=manifest();assert.equal(m.jobs.length,24);assert.equal(m.transportAttached,false);assert.equal(m.persistenceAttached,false);assert.equal(m.reviewGateAttached,false);assert.equal(m.maxExecutableStage,0);
 assert.deepEqual(m.limits.checkpoints,[2,8,16,24]);assert.deepEqual(m.limits.pairCheckpoints,[1,4,8,12]);assert.deepEqual(m.limits.stageReservedMicroUSD,[16384,49152,65536,65536]);assert.equal(m.limits.totalReservedMicroUSD,24*8192);
 assert.deepEqual(m.limits.stageMs,[120000,360000,480000,480000]);assert.equal(m.limits.journalBytes,2097152);
 for(let i=0;i<12;i++){
  const pair=m.jobs.slice(i*2,i*2+2);assert.deepEqual(pair.map(j=>j.variant),i%2?['candidate','baseline']:['baseline','candidate']);
  for(const j of pair){assert.equal(j.ordinal,m.jobs.indexOf(j));assert.equal(j.pairIndex,i);assert.equal(j.index,i);assert.equal(j.stage,m.limits.checkpoints.findIndex(n=>j.ordinal<n));assert.equal(j.requestHash,hash(JSON.stringify(request(i,j.variant))));}
  assert.equal(pair[0].questionHash,pair[1].questionHash);assert.notEqual(pair[0].requestHash,pair[1].requestHash);
 }
 for(const [file,h] of Object.entries(m.sourceHashes))assert.equal(h,hash(readFileSync(new URL('../scripts/rag-quality/'+file,import.meta.url))));
 const n=manifest();m.jobs[0].index=99;m.limits.checkpoints[0]=99;assert.equal(n.jobs[0].index,0);assert.equal(manifest().limits.checkpoints[0],2);assert.throws(()=>manifest({}));
});
test('initial state has no billing claim or semantic success and may reserve only first job',()=>{
 const s=run(seed());assert.equal(s.nextJob.ordinal,0);assert.equal(s.reservedMicroUSD,0);assert.equal(s.safeReopenCheckpoint,true);assert.equal(s.plannedPairs,12);assert.equal(s.unreservedPairs,12);assert.equal(s.reservedPairs,0);assert.equal(s.comparablePairs,0);assert.equal(s.candidateAllMatched,null);assert.equal(s.baselineMismatchCount,null);assert.equal(s.releaseAccepted,false);
});
test('reservation without terminal result is not a safe reopen checkpoint',()=>{
 const r=seed();reserve(r,0);const s=run(r);assert.equal(s.pending,0);assert.equal(s.nextJob,null);assert.equal(s.safeReopenCheckpoint,false);assert.equal(s.reservedRequests,1);assert.equal(s.reservedMicroUSD,8192);assert.equal(s.completedRequests,0);assert.equal(s.reservedPairs,1);assert.equal(s.unreservedPairs,11);
});
test('one completed arm remains a partial pair and cannot become a restart instruction',()=>{
 const r=seed();reserve(r,0);complete(r,0);const s=run(r);assert.equal(s.completedRequests,1);assert.equal(s.baselineCompleted,1);assert.equal(s.candidateCompleted,0);assert.equal(s.partialPairs,1);assert.equal(s.technicalCompletedPairs,0);assert.equal(s.comparablePairs,0);assert.equal(s.unreservedPairs,11);assert.equal(s.reservedPairs,1);assert.equal(s.safeReopenCheckpoint,false);assert.equal(s.nextJob.ordinal,1);
});
test('first pair completes into review waiting without permission for stage one',()=>{
 const r=stage(),s=run(r);assert.equal(s.completedRequests,2);assert.equal(s.technicalCompletedPairs,1);assert.equal(s.partialPairs,0);assert.equal(s.baselineCompleted,1);assert.equal(s.candidateCompleted,1);assert.equal(s.comparablePairs,0);assert.equal(s.audit,'pending');assert.equal(s.safeReopenCheckpoint,true);assert.equal(s.nextJob,null);assert.equal(s.generationComplete,false);assert.equal(s.allReviewsComplete,false);assert.equal(s.finalDecision,'pending');assert.equal(s.checkpointHash,hash(JSON.stringify(r.at(-1))));assert.equal(s.reservedMicroUSD,16384);
 reserve(r,2);rejected(r);
});
test('technical failure on either arm stops all future work while keeping partial counts and reservation',()=>{
 for(const ordinal of [0,1]){
  const r=seed();if(ordinal){reserve(r,0);complete(r,0);}reserve(r,ordinal);append(r,{type:'failed',ordinal,phase:'body',httpStatus:200,reason:'response_body_failure'});
  const s=run(r);assert.equal(s.failedOrdinal,ordinal);assert.equal(s.stopped,true);assert.equal(s.audit,'technical_stop');assert.equal(s.safeReopenCheckpoint,false);assert.equal(s.nextJob,null);assert.equal(s.partialPairs,ordinal);assert.equal(s.reservedMicroUSD,(ordinal+1)*8192);assert.equal(s.reservedPairs,1);assert.equal(s.unreservedPairs,11);assert.equal(s.comparablePairs,0);assert.equal(s.finalDecision,'technical_stop');reserve(r,ordinal);rejected(r);
 }
});
test('wrong job question variant order reservation and old manifest fail even after rehashing',()=>{
 for(const mutate of [j=>j.ordinal=1,j=>j.pairIndex=1,j=>j.index=1,j=>j.variant='candidate',j=>j.requestHash='0'.repeat(64),j=>j.questionHash='0'.repeat(64),j=>j.stage=1]){
  const r=seed();reserve(r,0);mutate(r[1].job);rechain(r);rejected(r);
 }
 for(const mutate of [r=>r[0].manifest.transportAttached=true,r=>r[0].manifest.suiteId='unit-task-plan-v4-offline-20261015-v1',r=>r[0].manifest.sourceHashes['task-plan-v2.ts']='0'.repeat(64),r=>r[1].reservedMicroUSD=0,r=>r[0].runId='private',r=>r[1].private='raw']){const r=seed();reserve(r,0);mutate(r);rechain(r);rejected(r);}
 const r=seed();reserve(r,1);rejected(r);const d=seed();reserve(d,0);reserve(d,0);rejected(d);
});
test('completion recomputes provenance validates usage and does not accept a changed role binding',()=>{
 for(const mutate of [r=>r.result.variant='candidate',r=>r.result.index=1,r=>r.result.bindingSource='upstream',r=>r.result.requestHash='0'.repeat(64),r=>r.result.structuralProvenance.units[0].text='private',r=>r.result.usage.cached=300,r=>r.result.usage.reasoning=301,r=>r.result.responseHash='private',r=>r.elapsedMs=60001,r=>r.elapsedMs=-1,r=>r.result.releaseAccepted=true,r=>r.result.semanticCompleteness='pass',r=>r.result.model='other']){const r=seed();reserve(r,0);const c=completion(r[0].manifest.jobs[0]);mutate(c);append(r,c);rejected(r);}
 const r=seed();append(r,completion(r[0].manifest.jobs[0]));rejected(r);
});
test('formally valid but semantically wrong subjects are still pending',()=>{
 const r=seed();reserve(r,0);const c=completion(r[0].manifest.jobs[0]);c.result.plan.tasks.forEach(t=>t.subjects=[]); // Plan changes can remain formally valid; no semantic inference here.
 append(r,c);assert.equal(run(r).semanticCompleteness,'pending');assert.equal(run(r).comparablePairs,0);
});
test('unknown review packet continue and duplicate terminal events cannot open a stage',()=>{
 for(const type of ['review','packets_ready','continue']){const r=stage();append(r,{type,decision:'continue'});rejected(r);}
 const r=seed();reserve(r,0);complete(r,0);complete(r,0);rejected(r);
 for(const mutate of [r=>r.stage=1,r=>r.completedRequests=1,r=>r.completedPairs=0]){const r=stage();mutate(r.at(-1));rechain(r);rejected(r);}
 const f=seed();append(f,{type:'stage_finished',stage:0,completedRequests:0,completedPairs:0});rejected(f);
});
test('failure diagnostic is finite and never echoes arbitrary upstream content',()=>{
 for(const change of [r=>r.phase='private',r=>r.reason='private upstream body',r=>r.httpStatus=200.5,r=>r.httpStatus=600,r=>r.httpStatus='200',r=>r.ordinal=1,r=>r.body='private']){const r=seed();reserve(r,0);const f={type:'failed',ordinal:0,phase:'fetch',httpStatus:null,reason:'transport_or_unknown'};change(f);append(r,f);rejected(r);}
});
test('ledger parsing rejects truncation tampering extra arguments blank rows and byte overflow',()=>{
 for(const raw of [null,{},'',encode(seed()).slice(0,-1),'private\n',encode(seed())+'\n',' '.repeat(2097153)+'\n'])assert.throws(()=>replay(raw),e=>e.message==='subject_role_ledger_audit_required');
 const r=stage();r[2].elapsedMs++;rejected(r);assert.throws(()=>replay(encode(seed()),{}));
 const s=run(stage());s.nextJob={ordinal:2};assert.equal(run(stage()).nextJob,null);
});
