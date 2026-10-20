// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {performance} from 'node:perf_hooks';
import {subjectRoleComparisonLiveManifest as manifest,createSubjectRoleComparisonLivePackets as packets,prepareSubjectRoleComparisonLiveReview as prepare} from '../scripts/rag-quality/subject-role-comparison-live-contract.ts';
import {createSubjectRoleComparisonPackets as oldPackets,prepareSubjectRoleComparisonReview as oldPrepare} from '../scripts/rag-quality/subject-role-comparison.ts';
import {openSubjectRoleComparisonLiveJournal as open} from '../scripts/rag-quality/subject-role-comparison-live-journal.ts';
import {comparisonContext,comparisonResult,mockBatch,hash} from './test-support/rag-subject-role-comparison.ts';
const error=e=>e.message==='subject_role_comparison_live_journal_audit_required';
const file=d=>path.join(d,'journal.ndjson'),lock=d=>path.join(d,'running.lock');
async function sandbox(fn){const p=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-live-journal-')));try{await fn(path.join(p,'run'));}finally{fs.rmSync(p,{recursive:true,force:true});}}
const deadline=()=>performance.now()+60000;
function finish(j){const s=j.status(),end=[2,8,16,24][s.stage];for(let i=s.completedRequests;i<end;i++){const job=j.reserveNext(deadline());j.complete(comparisonResult(job),1,deadline());}j.finishStage(deadline());}
function review(j,d,modes={}){const stage=j.status().stage;j.preparePackets();const c=JSON.parse(fs.readFileSync(path.join(d,'packets-stage-'+stage+'.json'),'utf8'));return j.recordReview(JSON.stringify(mockBatch(c,modes)));}
test('live manifest closes over transport and guard sources with identical jobs but a distinct suite',()=>{
 const m=manifest();assert.equal(m.version,2);assert.equal(m.transportAttached,true);assert.equal(m.dispatchAuthorized,false);assert.equal(m.jobs.length,24);assert.equal(m.limits.totalReservedMicroUSD,196608);for(const name of ['subject-role-comparison-live-contract.ts','subject-role-comparison-live-journal.ts','subject-role-comparison-live.ts','unit-task-planner-secret-guard.ts'])assert.equal(m.sourceHashes[name],hash(fs.readFileSync(new URL('../scripts/rag-quality/'+name,import.meta.url))));assert.throws(()=>manifest({}));
});
test('live and offline stage policies remain in parity for every stage and major outcome',()=>{
 for(let stage=0;stage<4;stage++){
  const ctx=comparisonContext(stage),oldRaw=JSON.stringify(ctx),oldC=oldPackets(oldRaw);ctx.binding.manifestHash=hash(JSON.stringify(manifest()));const raw=JSON.stringify(ctx),c=packets(raw);
  for(const modes of [{},{baseline:'fail'},{baseline:'uncertain'},{baseline:'unsupported'},{candidate:'fail'}]){const a=prepare(raw,JSON.stringify(c),JSON.stringify(mockBatch(c,modes))),b=oldPrepare(oldRaw,JSON.stringify(oldC),JSON.stringify(mockBatch(oldC,modes)));for(const key of ['comparisonDecision','stageReviewsComplete','stageCandidateAllMatched','stageBaselineMismatchCount','comparablePairs'])assert.deepEqual(a[key],b[key]);assert.deepEqual(a.cases.map(c=>c.result),b.cases.map(c=>c.result));assert.equal(a.dispatchAuthorized,false);}
 }
});
test('mandatory finite deadlines cannot be omitted or extended beyond fixed caps',async()=>{
 for(const kind of ['undefined','nan','infinite','extended'])await sandbox(d=>{const j=open(d),at=kind==='undefined'?undefined:kind==='nan'?NaN:kind==='infinite'?Infinity:performance.now()+200000;assert.throws(()=>j.reserveNext(at),error);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));});
 for(const kind of ['undefined','extended','expired'])await sandbox(d=>{const j=open(d),job=j.reserveNext(deadline()),at=kind==='undefined'?undefined:kind==='extended'?performance.now()+120000:performance.now()-1;assert.throws(()=>j.complete(comparisonResult(job),1,at),error);assert.throws(()=>j.close(),error);});
});
test('deadline expiry before completion and during stage checkpoint save never yields a reopenable success',async t=>{
 for(const kind of ['complete','finish'])await sandbox(d=>{
  const j=open(d);let result;if(kind==='complete'){const job=j.reserveNext(deadline());result=comparisonResult(job);}else{for(let i=0;i<2;i++){const job=j.reserveNext(deadline());j.complete(comparisonResult(job),1,deadline());}}
  const at=deadline(),originalNow=performance.now.bind(performance),originalSync=fs.fsyncSync;let offset=kind==='complete'?600000:0;
  const now=t.mock.method(performance,'now',()=>originalNow()+offset),sync=t.mock.method(fs,'fsyncSync',fd=>{const n=originalSync(fd);if(kind==='finish'&&fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"stage_finished"'))offset=600000;return n;});
  try{assert.throws(()=>kind==='complete'?j.complete(result,1,at):j.finishStage(at),error);}finally{sync.mock.restore();now.mock.restore();}assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);
 });
});
test('final candidate mismatch keeps generation and completed reviews separate from candidate acceptance',async()=>sandbox(d=>{
 let j=open(d);for(let stage=0;stage<4;stage++){finish(j);const before=j.status();assert.equal(before.generationComplete,stage===3);assert.equal(before.allReviewsComplete,false);const after=review(j,d,stage===3?{candidate:'fail'}:{});if(stage<3){j.close(deadline());j=open(d);}else{assert.equal(after.generationComplete,true);assert.equal(after.allReviewsComplete,true);assert.equal(after.candidateAllMatched,false);assert.equal(after.finalDecision,'stop');assert.equal(after.comparablePairs,12);assert.equal(after.baselineMismatchCount,0);assert.equal(after.releaseAccepted,false);j.close();assert.ok(fs.existsSync(lock(d)));}}
}));
test('close faults keep a fixed error and a stop marker instead of leaking low-level errors',async t=>sandbox(d=>{
 const j=open(d),original=fs.closeSync,stub=t.mock.method(fs,'closeSync',fd=>{original(fd);throw Error('private close detail');});try{assert.throws(()=>j.close(deadline()),error);}finally{stub.mock.restore();}assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);
}));
