// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {comparisonResult,mockBatch,hash} from './test-support/rag-subject-role-comparison.ts';
import {subjectRoleComparisonManifest} from '../scripts/rag-quality/subject-role-comparison.ts';
import {openSubjectRoleComparisonJournal as open} from '../scripts/rag-quality/subject-role-comparison-journal.ts';
import {openSubjectRolePairedJournal} from '../scripts/rag-quality/subject-role-paired-journal.ts';
const error=e=>e.message==='subject_role_comparison_journal_audit_required';
const journal=d=>path.join(d,'journal.ndjson'),lock=d=>path.join(d,'running.lock'),collection=(d,s=0)=>path.join(d,'packets-stage-'+s+'.json'),artifact=(d,s=0)=>path.join(d,'review-stage-'+s+'.json');
async function sandbox(fn){const p=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-four-stage-')));try{await fn(path.join(p,'run'),p);}finally{fs.rmSync(p,{recursive:true,force:true});}}
function completeStage(j){const s=j.status(),end=[2,8,16,24][s.stage];for(let i=s.completedRequests;i<end;i++){const job=j.reserveNext();assert.equal(job.ordinal,i);j.complete(comparisonResult(job),1);}j.finishStage();}
const rawBatch=(d,s=0,modes={})=>JSON.stringify(mockBatch(JSON.parse(fs.readFileSync(collection(d,s),'utf8')),modes));
function reviewStage(j,d,modes={}){const s=j.status().stage;j.preparePackets();return j.recordReview(rawBatch(d,s,modes));}
function firstStage(j,d){completeStage(j);return reviewStage(j,d);}
function rewrite(d,mutate){const rows=fs.readFileSync(journal(d),'utf8').trimEnd().split('\n').map(JSON.parse);mutate(rows);for(let i=1;i<rows.length;i++)rows[i].previous=hash(JSON.stringify(rows[i-1]));fs.writeFileSync(journal(d),rows.map(JSON.stringify).join('\n')+'\n');}
test('all 24 jobs use 2/6/8/8 checkpoints and separate generation final review and authorization',async()=>sandbox(d=>{
 let j=open(d);const run=j.status().runId;j.close();j=open(d);
 for(let stage=0;stage<4;stage++){
  completeStage(j);let s=j.status();assert.equal(s.completedRequests,[2,8,16,24][stage]);assert.equal(s.stage,stage);assert.equal(s.phase,'checkpoint');assert.equal(s.generationComplete,stage===3);assert.equal(s.allReviewsComplete,false);assert.equal(s.candidateAllMatched,null);assert.equal(s.baselineMismatchCount,null);assert.equal(s.comparablePairs,[0,1,4,8][stage]);j.close();j=open(d);
  j.preparePackets();const packets=j.exportPackets(stage);for(const p of packets)assert.equal(Object.hasOwn(p.packet,'variant'),false);assert.equal(packets.length,[2,6,8,8][stage]);assert.equal(j.status().phase,'packets');j.close();j=open(d);assert.deepEqual(j.exportPackets(stage),packets);
  s=j.recordReview(rawBatch(d,stage));assert.equal(s.stage,stage+1);assert.equal(s.comparablePairs,[1,4,8,12][stage]);assert.equal(s.dispatchAuthorized,false);assert.equal(s.transportAttached,false);assert.equal(s.releaseAccepted,false);j.close();j=open(d);
 }
 const final=j.status();assert.equal(final.runId,run);assert.equal(final.phase,'done');assert.equal(final.generationComplete,true);assert.equal(final.allReviewsComplete,true);assert.equal(final.candidateAllMatched,true);assert.equal(final.baselineMismatchCount,0);assert.equal(final.reviewedRequests,24);assert.equal(final.baselineCompleted,12);assert.equal(final.candidateCompleted,12);assert.equal(final.reservedMicroUSD,196608);assert.equal(final.reservedPairs,12);assert.equal(final.unreservedPairs,0);assert.equal(final.finalDecision,'continue');assert.equal(final.dispatchAuthorized,false);j.close();
 const rows=fs.readFileSync(journal(d),'utf8').trimEnd().split('\n').map(JSON.parse);assert.equal(rows.filter(r=>r.type==='reserved').length,24);assert.equal(rows.filter(r=>r.type==='review').length,4);assert.equal(fs.statSync(d).mode&0o777,0o700);assert.equal(fs.statSync(journal(d)).mode&0o777,0o600);
}));
test('baseline definite mismatch permits next stage but candidate failure stops prefix without extrapolating',async()=>sandbox(d=>{
 const j=open(d);completeStage(j);let s=reviewStage(j,d,{baseline:'fail'});assert.equal(s.stage,1);assert.equal(s.observedBaselineMismatchCount,1);assert.equal(s.baselineMismatchCount,null);assert.equal(s.candidateAllMatched,null);
 completeStage(j);s=reviewStage(j,d,{candidate:'fail'});assert.equal(s.finalDecision,'stop');assert.equal(s.completedRequests,8);assert.equal(s.baselineCompleted,4);assert.equal(s.candidateCompleted,4);assert.equal(s.comparablePairs,4);assert.equal(s.generationComplete,false);assert.equal(s.allReviewsComplete,false);assert.equal(s.observedCandidateAllMatched,false);assert.equal(s.candidateAllMatched,null);assert.equal(s.unreservedPairs,8);j.close();assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);
}));
test('technical failure on either arm retains reservations and partial pair without completing or resending',async()=>{
 for(const ordinal of [0,1])await sandbox(d=>{const j=open(d);if(ordinal){const job=j.reserveNext();j.complete(comparisonResult(job),1);}j.reserveNext();j.markFailed({phase:'fetch',httpStatus:429,reason:'upstream_http'});const s=j.status();assert.equal(s.finalDecision,'technical_stop');assert.equal(s.failedOrdinal,ordinal);assert.equal(s.partialPairs,ordinal);assert.equal(s.comparablePairs,0);assert.equal(s.reservedRequests,ordinal+1);assert.equal(s.reservedPairs,1);assert.equal(s.unreservedPairs,11);j.close();assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);});
});
test('unknown unsupported and candidate uncertainty are semantic stops with original artifacts',async()=>{
 for(const modes of [{baseline:'uncertain'},{baseline:'unsupported'},{candidate:'uncertain'}])await sandbox(d=>{const j=open(d);completeStage(j);const s=reviewStage(j,d,modes);assert.equal(s.finalDecision,'stop');assert.equal(s.stage,0);assert.equal(s.comparablePairs,0);assert.equal(s.reviewArtifactsRecorded,1);assert.ok(fs.existsSync(artifact(d)));j.close();assert.ok(fs.existsSync(lock(d)));});
});
test('checkpoint or packets_ready without a review never permits another reservation',async()=>{
 for(const prepared of [false,true])await sandbox(d=>{const j=open(d);completeStage(j);if(prepared)j.preparePackets();const before=fs.readFileSync(journal(d));assert.throws(()=>j.reserveNext(),error);assert.deepEqual(fs.readFileSync(journal(d)),before);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));});
});
test('reserved partial pair and uncheckpointed completion never reopen automatically',async()=>{
 for(const count of [0,1,2])await sandbox(d=>{const j=open(d);if(count===0)j.reserveNext();for(let i=0;i<count;i++){const job=j.reserveNext();j.complete(comparisonResult(job),1);}assert.equal(j.status().safeReopenCheckpoint,false);j.close();assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);});
});
test('next reservation revalidates all previous collections artifacts original reviews and inodes',async()=>{
 for(const kind of ['missing_collection','missing_artifact','changed_artifact','inode','collection'])await sandbox((d,p)=>{
  const j=open(d);firstStage(j,d);const before=fs.readFileSync(journal(d));if(kind==='missing_collection')fs.unlinkSync(collection(d));if(kind==='missing_artifact')fs.unlinkSync(artifact(d));if(kind==='changed_artifact')fs.appendFileSync(artifact(d),' ');if(kind==='collection')fs.appendFileSync(collection(d),' ');if(kind==='inode'){fs.renameSync(artifact(d),path.join(p,'old'));fs.writeFileSync(artifact(d),fs.readFileSync(path.join(p,'old')),{mode:0o600});}
  assert.throws(()=>j.reserveNext(),error);assert.deepEqual(fs.readFileSync(journal(d)),before);assert.throws(()=>j.close(),error);
 });
});
test('rehashed metadata cannot forge a decision or hide a modified original review',async()=>{
 for(const kind of ['decision','review','binding','job','checkpoint'])await sandbox(d=>{const j=open(d);firstStage(j,d);j.close();rewrite(d,rows=>{if(kind==='decision')rows.at(-1).comparisonDecision='stop';if(kind==='review'){const a=JSON.parse(fs.readFileSync(artifact(d),'utf8'));a.submissions[0].review='{}';const raw=JSON.stringify(a);fs.writeFileSync(artifact(d),raw);rows.at(-1).artifactHash=hash(raw);}if(kind==='binding')rows[0].manifest.sourceHashes['unit-plan-semantic-review.ts']='0'.repeat(64);if(kind==='job')rows[1].job.variant='candidate';if(kind==='checkpoint')rows.find(r=>r.type==='stage_finished').completedPairs=12;});assert.throws(()=>open(d),error);});
});
test('stage arm shortage duplicate or mixed review and malformed review fail before saving artifact',async()=>{
 for(const kind of ['missing','duplicate','mixed','invalid','override'])await sandbox(d=>{const j=open(d);completeStage(j);j.preparePackets();const b=JSON.parse(rawBatch(d));if(kind==='missing')b.submissions.pop();if(kind==='duplicate')b.submissions[1]=b.submissions[0];if(kind==='mixed')b.submissions[0].packetHash=b.submissions[1].packetHash;if(kind==='invalid')b.submissions[0].review='private';if(kind==='override')b.decision='continue';assert.throws(()=>j.recordReview(JSON.stringify(b)),error);assert.equal(fs.existsSync(artifact(d)),false);assert.throws(()=>j.close(),error);});
});
test('orphan and duplicate collections or reviews are never regenerated or overwritten',async()=>{
 for(const kind of ['orphan','packets','review'])await sandbox(d=>{const j=open(d);completeStage(j);if(kind==='orphan')fs.writeFileSync(collection(d),'{}',{mode:0o600});else j.preparePackets();if(kind==='review')j.recordReview(rawBatch(d));const before=fs.readFileSync(kind==='review'?artifact(d):collection(d));assert.throws(()=>kind==='review'?j.recordReview(rawBatch(d)):j.preparePackets(),error);assert.deepEqual(fs.readFileSync(kind==='review'?artifact(d):collection(d)),before);assert.throws(()=>j.close(),error);});
});
test('source change while open prevents reservation before writing any new record',async t=>sandbox(d=>{
 const j=open(d),before=fs.readFileSync(journal(d)),original=fs.readFileSync,stub=t.mock.method(fs,'readFileSync',(f,...args)=>{const raw=original(f,...args);return String(f).endsWith('subject-role-comparison.ts')?Buffer.concat([Buffer.from(raw),Buffer.from('changed')]):raw;});try{assert.throws(()=>j.reserveNext(),error);}finally{stub.mock.restore();}assert.deepEqual(fs.readFileSync(journal(d)),before);assert.throws(()=>j.close(),error);
}));
test('private files reject unsafe modes links oversize invalid UTF8 and existing old suite',async()=>{
 for(const kind of ['mode','hardlink','symlink','bytes','utf8','old','empty'])await sandbox((d,p)=>{
  if(kind==='empty'){fs.mkdirSync(d,{mode:0o700});assert.throws(()=>open(d),error);return;}
  if(kind==='old'){const old=openSubjectRolePairedJournal(d);old.close();const before=fs.readFileSync(journal(d));assert.throws(()=>open(d),error);assert.deepEqual(fs.readFileSync(journal(d)),before);return;}
  const j=open(d);completeStage(j);j.preparePackets();j.close();if(kind==='mode')fs.chmodSync(collection(d),0o644);if(kind==='hardlink')fs.linkSync(collection(d),path.join(p,'extra'));if(kind==='symlink'){fs.renameSync(collection(d),path.join(p,'actual'));fs.symlinkSync(path.join(p,'actual'),collection(d));}if(kind==='bytes')fs.writeFileSync(collection(d),Buffer.alloc(2097153));if(kind==='utf8')fs.appendFileSync(collection(d),Buffer.from([255]));assert.throws(()=>open(d),error);
 });
});
test('common lock excludes concurrent opens without disturbing the owner',async()=>sandbox(d=>{const j=open(d),before=fs.readFileSync(journal(d));assert.throws(()=>open(d),error);assert.deepEqual(fs.readFileSync(journal(d)),before);j.close();const again=open(d);again.close();}));
test('short write or fsync uncertainty in every save phase keeps lock and never reports success',async t=>{
 for(const fault of ['short','sync'])for(const target of ['reserved','completed','stage_finished','collection','packets_ready','artifact','review'])await sandbox(d=>{
  const j=open(d);let job;if(target==='completed')job=j.reserveNext();if(target==='stage_finished'){for(let i=0;i<2;i++){const k=j.reserveNext();j.complete(comparisonResult(k),1);}}if(['collection','packets_ready','artifact','review'].includes(target))completeStage(j);if(['artifact','review'].includes(target))j.preparePackets();const submission=['artifact','review'].includes(target)?rawBatch(d):null;
  const operation=()=>target==='reserved'?j.reserveNext():target==='completed'?j.complete(comparisonResult(job),1):target==='stage_finished'?j.finishStage():['collection','packets_ready'].includes(target)?j.preparePackets():j.recordReview(submission);
  const match=raw=>target==='collection'?raw.includes('"packets"'):target==='artifact'?raw.includes('"submissions"'):raw.includes('"type":"'+target+'"');
  let stub;if(fault==='short'){const original=fs.writeSync;stub=t.mock.method(fs,'writeSync',(...args)=>{const n=original(...args);return Buffer.isBuffer(args[1])&&match(args[1].toString('utf8'))?n-1:n;});}else{const original=fs.fsyncSync;stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&match(fs.readFileSync(fd,'utf8')))throw Error('private fsync');return original(fd);});}
  try{assert.throws(operation,error);}finally{stub.mock.restore();}assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);
 });
});
test('same-fd read interval replacement and lock release sync errors stop safely',async t=>{
 await sandbox((d,p)=>{const j=open(d);completeStage(j);j.preparePackets();const original=fs.readSync;let swapped=false;const stub=t.mock.method(fs,'readSync',(...args)=>{const n=original(...args);if(!swapped&&args[1].subarray(0,n).toString('utf8').includes('"packets"')){swapped=true;fs.renameSync(collection(d),path.join(p,'old'));fs.writeFileSync(collection(d),fs.readFileSync(path.join(p,'old')),{mode:0o600});}return n;});try{assert.throws(()=>j.status(),error);}finally{stub.mock.restore();}assert.equal(swapped,true);assert.throws(()=>j.close(),error);});
 await sandbox(d=>{const j=open(d),original=fs.fsyncSync;let once=false;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(!once&&fs.fstatSync(fd).isDirectory()){once=true;throw Error('private');}return original(fd);});try{assert.throws(()=>j.close(),error);}finally{stub.mock.restore();}assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);});
});
test('caller snapshots and malformed completion cannot mutate retained data',async()=>{
 await sandbox(d=>{const j=open(d),job=j.reserveNext(),r=comparisonResult(job);j.complete(r,1);job.variant='changed';r.plan.tasks[0].attribute.label='changed';const next=j.reserveNext();j.complete(comparisonResult(next),1);j.finishStage();j.preparePackets();const p=j.exportPackets(0);p[0].packet.question='changed';assert.notEqual(j.exportPackets(0)[0].packet.question,'changed');j.close();const again=open(d);assert.equal(again.status().phase,'packets');again.close();});
 await sandbox(d=>{const j=open(d),job=j.reserveNext(),r=comparisonResult(job);r.plan.extra=undefined;assert.throws(()=>j.complete(r,1),error);assert.throws(()=>j.close(),error);});
});
