// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {mockLedger,mockBatch} from './test-support/rag-subject-role-review.ts';
import {createSubjectRoleReviewPackets as packets} from '../scripts/rag-quality/subject-role-review-packets.ts';
import {prepareSubjectRoleReviewArtifact as prepare,verifySubjectRoleReviewArtifact as verify} from '../scripts/rag-quality/subject-role-review-artifact.ts';
const error=e=>e.message==='subject_role_artifact_audit_required';
const fixture=(modes={},options={})=>{const ledger=mockLedger(options),c=packets(ledger),collection=JSON.stringify(c),batch=mockBatch(c,modes);return {ledger,c,collection,batch,artifact:()=>prepare(ledger,collection,JSON.stringify(batch))};};
test('all reviewed matches compute comparison continue while denying stage1 transport and release',()=>{
 const f=fixture(),a=f.artifact();assert.equal(a.comparisonDecision,'continue');assert.equal(a.stageReviewsComplete,true);assert.equal(a.stageCandidateAllMatched,true);assert.equal(a.stageBaselineMismatchCount,0);assert.equal(a.comparablePairs,1);assert.equal(a.stage1Authorized,false);assert.equal(a.transportAttached,false);assert.equal(a.releaseAccepted,false);assert.equal(a.reviewerAuthenticated,false);assert.deepEqual(verify(f.ledger,f.collection,JSON.stringify(a)),a);
});
test('baseline definite subject-role failure remains a recorded mismatch but allows comparison',()=>{
 const f=fixture({baseline:'fail'},{baselineMissingSubjects:true}),a=f.artifact();assert.equal(a.comparisonDecision,'continue');assert.equal(a.stageReviewsComplete,true);assert.equal(a.stageBaselineMismatchCount,1);assert.equal(a.comparablePairs,1);assert.equal(a.cases[0].result.semanticStatus,'mismatch_detected');assert.equal(a.cases[0].result.reviewComplete,true);assert.equal(a.cases[0].result.flags.representationUncertain,false);assert.equal(a.cases[0].job.variant,'baseline');
});
test('baseline unknown unsupported or incomplete are valid stop outcomes rather than malformed reviews',()=>{
 for(const mode of ['uncertain','unsupported','representation_uncertain','incomplete']){const f=fixture({baseline:mode}),a=f.artifact();assert.equal(a.comparisonDecision,'stop');assert.equal(a.stageCandidateAllMatched,true);assert.equal(a.comparablePairs,0);assert.equal(a.stageBaselineMismatchCount,0);assert.equal(a.stage1Authorized,false);}
});
test('candidate mismatch or uncertainty stops irrespective of the baseline',()=>{
 for(const baseline of ['pass','fail'])for(const candidate of ['fail','uncertain','unsupported','incomplete']){const f=fixture({baseline,candidate}),a=f.artifact();assert.equal(a.comparisonDecision,'stop');assert.equal(a.stageCandidateAllMatched,false);assert.equal(a.comparablePairs,candidate==='fail'?1:0);}
});
test('duplicate missing or mixed packet submissions and caller decision overrides are refused',()=>{
 for(const mutate of [b=>b.submissions=[],b=>b.submissions[1]=b.submissions[0],b=>b.submissions[0].packetHash=b.submissions[1].packetHash,b=>b.binding.stage=1,b=>b.binding.runId='other',b=>b.decision='continue',b=>b.submissions.push(b.submissions[0])]){const f=fixture();mutate(f.batch);assert.throws(()=>f.artifact(),error);}
});
test('malformed review binds question plan oracle role and exact fields before retention',()=>{
 for(const mutate of [r=>r.questionHash='0'.repeat(64),r=>r.planHash='0'.repeat(64),r=>r.oracleHash='0'.repeat(64),r=>r.reviewerRole='other',r=>r.extra='private',r=>r.pairs[0].taskId='t99',r=>r.pairs[0].dimensions.subjects='other']){const f=fixture(),r=JSON.parse(f.batch.submissions[0].review);mutate(r);f.batch.submissions[0].review=JSON.stringify(r);assert.throws(()=>f.artifact(),error);}
 const f=fixture();f.batch.submissions[0].review='private upstream text';assert.throws(()=>f.artifact(),error);
});
test('identical plans and raw review contents retain separate packet-target bindings',()=>{
 const f=fixture();assert.equal(f.batch.submissions[0].review,f.batch.submissions[1].review);const a=f.artifact();assert.equal(a.cases[0].reviewHash,a.cases[1].reviewHash);assert.notEqual(a.cases[0].job.packetId,a.cases[1].job.packetId);assert.deepEqual(a.submissions,f.batch.submissions);
});
test('artifact replay recomputes meaning decisions counts collection and original review',()=>{
 const f=fixture({candidate:'fail'}),a=f.artifact();
 for(const change of [v=>v.comparisonDecision='continue',v=>v.stageCandidateAllMatched=true,v=>v.comparablePairs=12,v=>v.stage1Authorized=true,v=>v.collectionHash='0'.repeat(64),v=>v.cases[0].result.semanticStatus='reviewed_match',v=>v.submissions[0].review='{}',v=>v.releaseAccepted=true,v=>v.extra=1]){const changed=structuredClone(a);change(changed);if(JSON.stringify(changed)===JSON.stringify(a))continue;assert.throws(()=>verify(f.ledger,f.collection,JSON.stringify(changed)),error);}
 assert.throws(()=>verify(f.ledger,JSON.stringify(packets(f.ledger)),JSON.stringify(a)),error);
});
test('bounds fixed errors arguments and caller mutations preserve snapshots',()=>{
 const f=fixture();for(const raw of [null,{},'private','x'.repeat(8388609)])assert.throws(()=>prepare(f.ledger,f.collection,raw),error);assert.throws(()=>prepare(f.ledger,f.collection,JSON.stringify(f.batch),{}),error);assert.throws(()=>verify(f.ledger,f.collection,'{}',{}),error);
 const a=f.artifact(),raw=JSON.stringify(a),b=verify(f.ledger,f.collection,raw);a.submissions[0].review='changed';assert.equal(verify(f.ledger,f.collection,raw).submissions[0].review,b.submissions[0].review);
});
