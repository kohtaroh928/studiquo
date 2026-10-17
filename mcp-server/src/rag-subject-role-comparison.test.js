import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {comparisonContext,comparisonResult,mockBatch,hash} from './test-support/rag-subject-role-comparison.mjs';
import {mockLedger} from './test-support/rag-subject-role-review.mjs';
import {subjectRoleComparisonManifest as manifest,validateSubjectRoleComparisonCompletion as validate,
 createSubjectRoleComparisonPackets as packets,verifySubjectRoleComparisonPackets as verifyPackets,
 prepareSubjectRoleComparisonReview as prepare,verifySubjectRoleComparisonReview as verify} from '../scripts/rag-quality/subject-role-comparison.mjs';
import {createSubjectRoleReviewPackets} from '../scripts/rag-quality/subject-role-review-packets.mjs';
import {prepareSubjectRoleReviewArtifact} from '../scripts/rag-quality/subject-role-review-artifact.mjs';
const error=e=>e.message==='subject_role_comparison_audit_required';
test('new suite freezes 24 jobs four stage caps and complete source closure without transport',()=>{
 const m=manifest();assert.equal(m.jobs.length,24);assert.equal(m.transportAttached,false);assert.equal(m.reviewGateAttached,true);assert.equal(m.dispatchAuthorized,false);assert.deepEqual(m.limits.checkpoints,[2,8,16,24]);assert.equal(m.limits.totalReservedMicroUSD,196608);assert.deepEqual(m.limits.stageReservedMicroUSD,[16384,49152,65536,65536]);
 for(const [f,h] of Object.entries(m.sourceHashes))assert.equal(hash(readFileSync(new URL('../scripts/rag-quality/'+f,import.meta.url))),h);
 for(let i=0;i<12;i++)assert.deepEqual(m.jobs.slice(i*2,i*2+2).map(j=>j.variant),i%2?['candidate','baseline']:['baseline','candidate']);assert.throws(()=>manifest({}),error);
});
test('all four stages bind neutral packets and original reviews to their full arm set',()=>{
 let arms=0,pairs=0;for(let stage=0;stage<4;stage++){const context=JSON.stringify(comparisonContext(stage)),c=packets(context);assert.equal(c.mapping.length,[2,6,8,8][stage]);assert.deepEqual(verifyPackets(context,JSON.stringify(c)),c);for(const p of c.packets){assert.equal(Object.hasOwn(p,'variant'),false);assert.equal(Object.hasOwn(p,'instructions'),false);}const raw=JSON.stringify(c),a=prepare(context,raw,JSON.stringify(mockBatch(c)));assert.equal(a.comparisonDecision,'continue');assert.equal(a.comparablePairs,[1,3,4,4][stage]);assert.equal(a.dispatchAuthorized,false);assert.deepEqual(verify(context,raw,JSON.stringify(a)),a);arms+=c.mapping.length;pairs+=a.comparablePairs;}assert.equal(arms,24);assert.equal(pairs,12);
});
test('stage0 policy stays in parity with frozen artifact on pass failure uncertainty unsupported and malformed review',()=>{
 const oldLedger=mockLedger(),oldC=createSubjectRoleReviewPackets(oldLedger),ctx=comparisonContext(0);
 const oldRows=oldLedger.trimEnd().split('\n').map(JSON.parse);ctx.completions=oldRows.filter(r=>r.type==='completed').map(r=>({ordinal:r.ordinal,result:r.result,elapsedMs:r.elapsedMs}));
 const context=JSON.stringify(ctx),c=packets(context);
 for(const modes of [{},{baseline:'fail'},{baseline:'uncertain'},{baseline:'unsupported'},{baseline:'representation_uncertain'},{baseline:'incomplete'},{candidate:'fail'},{candidate:'uncertain'},{candidate:'unsupported'}]){
  const old=prepareSubjectRoleReviewArtifact(oldLedger,JSON.stringify(oldC),JSON.stringify(mockBatch(oldC,modes))),now=prepare(context,JSON.stringify(c),JSON.stringify(mockBatch(c,modes)));
  for(const key of ['comparisonDecision','stageReviewsComplete','stageCandidateAllMatched','stageBaselineMismatchCount','comparablePairs'])assert.deepEqual(now[key],old[key]);assert.deepEqual(now.cases.map(x=>x.result),old.cases.map(x=>x.result));
 }
 const oldB=mockBatch(oldC),b=mockBatch(c);oldB.submissions[0].review='private';b.submissions[0].review='private';assert.throws(()=>prepareSubjectRoleReviewArtifact(oldLedger,JSON.stringify(oldC),JSON.stringify(oldB)));assert.throws(()=>prepare(context,JSON.stringify(c),JSON.stringify(b)),error);
});
test('baseline definite failure permits comparison at every stage while candidate failure or unknown stops',()=>{
 for(let stage=0;stage<4;stage++){const context=JSON.stringify(comparisonContext(stage)),c=packets(context),raw=JSON.stringify(c);for(const modes of [{baseline:'fail'},{baseline:'unsupported'},{candidate:'fail'},{candidate:'uncertain'}]){const a=prepare(context,raw,JSON.stringify(mockBatch(c,modes)));assert.equal(a.comparisonDecision,modes.baseline==='fail'?'continue':'stop');}}
});
test('context refuses wrong manifest checkpoint counts stage mixing duplicate jobs and changed provenance',()=>{
 for(const mutate of [c=>c.binding.stage=4,c=>c.binding.manifestHash='0'.repeat(64),c=>c.binding.completedRequests=24,c=>c.completions.pop(),c=>c.completions[1]=c.completions[0],c=>c.completions[0].ordinal=2,c=>c.completions[0].result.variant='candidate',c=>c.completions[0].result.structuralProvenance.units[0].text='private']){const c=comparisonContext(0);mutate(c);assert.throws(()=>packets(JSON.stringify(c)),error);}
 const m=manifest(),job=m.jobs[0],r=comparisonResult(job);r.plan.extra=undefined;assert.throws(()=>validate(job,r,1),error);assert.throws(()=>validate(job,comparisonResult(job),60001),error);
});
test('packet and review identities cannot move across stages or accept arm shortages or overrides',()=>{
 const context=JSON.stringify(comparisonContext(1)),c=packets(context),raw=JSON.stringify(c);assert.throws(()=>verifyPackets(JSON.stringify(comparisonContext(2)),raw),error);
 for(const mutate of [b=>b.submissions.pop(),b=>b.submissions[1]=b.submissions[0],b=>b.submissions[0].packetHash=b.submissions[1].packetHash,b=>b.binding.stage=0,b=>b.comparisonDecision='continue']){const b=mockBatch(c);mutate(b);assert.throws(()=>prepare(context,raw,JSON.stringify(b)),error);}
 const a=prepare(context,raw,JSON.stringify(mockBatch(c)));for(const mutate of [a=>a.comparablePairs=12,a=>a.releaseAccepted=true,a=>a.cases[0].job.variant='other',a=>a.submissions[0].review='{}']){const changed=structuredClone(a);mutate(changed);assert.throws(()=>verify(context,raw,JSON.stringify(changed)),error);}
});
test('strict bounds arguments and snapshots never promote semantic or dispatch authority',()=>{
 const context=JSON.stringify(comparisonContext(3)),c=packets(context),raw=JSON.stringify(c);for(const x of [null,{},'private','x'.repeat(2097153)])assert.throws(()=>verifyPackets(context,x),error);assert.throws(()=>packets(context,{}),error);assert.throws(()=>prepare(context,raw,'{}',{}),error);
 const a=prepare(context,raw,JSON.stringify(mockBatch(c))),saved=JSON.stringify(a),checked=verify(context,raw,saved);checked.cases[0].job.variant='changed';assert.equal(verify(context,raw,saved).cases[0].job.variant,a.cases[0].job.variant);assert.equal(a.releaseAccepted,false);assert.equal(a.reviewerAuthenticated,false);
});
