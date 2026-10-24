// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {mockLedger,mockBatch,hash} from './test-support/rag-subject-role-review.ts';
import {openSubjectRoleReviewControl as open} from '../scripts/rag-quality/subject-role-review-control.ts';
import {createSubjectRoleReviewPackets,verifySubjectRoleReviewPackets} from '../scripts/rag-quality/subject-role-review-packets.ts';
const error=e=>e.message==='subject_role_control_audit_required';
const file=(d,n)=>path.join(d,n),journal=d=>file(d,'control.ndjson'),collection=d=>file(d,'packets-stage-0.json'),artifact=d=>file(d,'review-stage-0.json'),lock=d=>file(d,'running.lock');
async function sandbox(fn,options={}){const parent=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-review-control-')));try{await fn(path.join(parent,'run'),mockLedger(options),parent);}finally{fs.rmSync(parent,{recursive:true,force:true});}}
const begin=(d,rawLedger)=>open({directory:d,rawLedger});
const batch=(d,modes={})=>JSON.stringify(mockBatch(JSON.parse(fs.readFileSync(collection(d),'utf8')),modes));
test('fresh control persists frozen source and ledger separately with private rights and no send authorization',async()=>sandbox((d,l)=>{
 const j=begin(d,l),s=j.status();assert.equal(s.prepared,false);assert.equal(s.reviewed,false);assert.equal(s.stage1Authorized,false);assert.equal(s.transportAttached,false);assert.equal(s.releaseAccepted,false);assert.equal(fs.statSync(d).mode&0o777,0o700);assert.equal(fs.statSync(journal(d)).mode&0o777,0o600);assert.equal(fs.readFileSync(file(d,'ledger.ndjson'),'utf8'),l);
 const header=JSON.parse(fs.readFileSync(journal(d),'utf8').trim());assert.equal(header.manifest.ledgerHash,hash(l));assert.equal(Object.keys(header.manifest.sourceHashes).length,3);assert.equal(header.manifest.transportAttached,false);j.close();const again=begin(d,l);assert.equal(again.status().manifestHash,s.manifestHash);again.close();
}));
test('packets_ready saves original IDs once and reopens as review waiting with no continuation',async()=>sandbox((d,l)=>{
 let j=begin(d,l);j.preparePackets();const before=fs.readFileSync(collection(d)),exported=j.exportPackets();assert.equal(exported.length,2);for(const e of exported){assert.deepEqual(Object.keys(e),['packet','packetHash']);assert.equal(Object.hasOwn(e.packet,'variant'),false);}assert.equal(j.status().comparisonDecision,'pending');j.close();j=begin(d,l);assert.deepEqual(fs.readFileSync(collection(d)),before);assert.deepEqual(j.exportPackets(),exported);assert.equal(j.status().stage1Authorized,false);j.close();
}));
test('continue is recomputed from retained original reviews and remains unauthorized after reopen',async()=>sandbox((d,l)=>{
 let j=begin(d,l);j.preparePackets();const submission=batch(d),s=j.recordReview(submission);assert.equal(s.comparisonDecision,'continue');assert.equal(s.stageReviewsComplete,true);assert.equal(s.comparablePairs,1);assert.equal(s.stage1Authorized,false);assert.equal(s.transportAttached,false);const a=JSON.parse(fs.readFileSync(artifact(d),'utf8'));assert.deepEqual(a.submissions,JSON.parse(submission).submissions);j.close();j=begin(d,l);assert.equal(j.status().comparisonDecision,'continue');assert.equal(j.status().releaseAccepted,false);j.close();
}));
test('baseline definite role mismatch is retained but permits comparison without allowing another stage',async()=>sandbox((d,l)=>{
 const j=begin(d,l);j.preparePackets();const s=j.recordReview(batch(d,{baseline:'fail'}));assert.equal(s.comparisonDecision,'continue');assert.equal(s.stageBaselineMismatchCount,1);assert.equal(s.stageCandidateAllMatched,true);assert.equal(s.stage1Authorized,false);j.close();
},{baselineMissingSubjects:true}));
test('candidate failure and baseline unknown are semantic stops retaining lock and original artifacts',async()=>{
 for(const modes of [{candidate:'fail'},{baseline:'uncertain'},{baseline:'unsupported'}])await sandbox((d,l)=>{const j=begin(d,l);j.preparePackets();const s=j.recordReview(batch(d,modes));assert.equal(s.comparisonDecision,'stop');assert.equal(s.stage1Authorized,false);assert.ok(fs.existsSync(artifact(d)));j.close();assert.ok(fs.existsSync(lock(d)));assert.throws(()=>begin(d,l),error);});
});
test('duplicate packet preparation or review is refused without overwriting first files',async()=>{
 for(const kind of ['packets','review'])await sandbox((d,l)=>{const j=begin(d,l);j.preparePackets();if(kind==='review')j.recordReview(batch(d));const before=fs.readFileSync(kind==='packets'?collection(d):artifact(d));assert.throws(()=>kind==='packets'?j.preparePackets():j.recordReview(batch(d)),error);assert.deepEqual(fs.readFileSync(kind==='packets'?collection(d):artifact(d)),before);assert.throws(()=>j.close(),error);});
});
test('even a valid newly generated collection cannot replace the originally registered collection',async()=>sandbox((d,l)=>{
 const j=begin(d,l);j.preparePackets();j.close();const forged=JSON.stringify(createSubjectRoleReviewPackets(l));verifySubjectRoleReviewPackets(l,forged);fs.writeFileSync(collection(d),forged);assert.throws(()=>begin(d,l),error);
}));
test('replay refuses changed original review artifact summary or decision despite rehashed journal',async()=>{
 for(const kind of ['artifact','decision','cases','mapping'])await sandbox((d,l)=>{
  const j=begin(d,l);j.preparePackets();j.recordReview(batch(d));j.close();
  const rows=fs.readFileSync(journal(d),'utf8').trimEnd().split('\n').map(JSON.parse);
  if(kind==='artifact'){const a=JSON.parse(fs.readFileSync(artifact(d),'utf8'));a.submissions[0].review='{}';const raw=JSON.stringify(a);fs.writeFileSync(artifact(d),raw);rows[2].artifactHash=hash(raw);}
  if(kind==='decision')rows[2].comparisonDecision='stop';if(kind==='cases')rows[2].casesHash='0'.repeat(64);if(kind==='mapping')rows[1].mappingHash='0'.repeat(64);
  for(let i=1;i<rows.length;i++)rows[i].previous=hash(JSON.stringify(rows[i-1]));fs.writeFileSync(journal(d),rows.map(JSON.stringify).join('\n')+'\n');assert.throws(()=>begin(d,l),error);
 });
});
test('missing orphan source ledger or checkpoint changes all prevent reuse',async()=>{
 for(const kind of ['missing','orphan','source','ledger','checkpoint','tail','empty'])await sandbox((d,l)=>{
  if(kind==='empty'){fs.mkdirSync(d,{mode:0o700});assert.throws(()=>begin(d,l),error);return;}
  const j=begin(d,l);j.preparePackets();j.close();
  if(kind==='missing')fs.unlinkSync(collection(d));if(kind==='orphan')fs.writeFileSync(artifact(d),'{}',{mode:0o600});if(kind==='ledger')fs.appendFileSync(file(d,'ledger.ndjson'),'\n');if(kind==='tail')fs.appendFileSync(journal(d),'{');
  if(kind==='source'||kind==='checkpoint'){const rows=fs.readFileSync(journal(d),'utf8').trimEnd().split('\n').map(JSON.parse);if(kind==='source')rows[0].manifest.sourceHashes['subject-role-review-artifact.ts']='0'.repeat(64);else rows[0].manifest.binding.checkpointHash='0'.repeat(64);for(let i=1;i<rows.length;i++)rows[i].previous=hash(JSON.stringify(rows[i-1]));fs.writeFileSync(journal(d),rows.map(JSON.stringify).join('\n')+'\n');}
  assert.throws(()=>begin(d,l),error);
 });
});
test('concurrent owner uses common lock and unsafe permissions links or oversized files fail',async()=>{
 for(const kind of ['concurrent','mode','hardlink','symlink','bytes','utf8'])await sandbox((d,l,p)=>{const j=begin(d,l);j.preparePackets();if(kind==='concurrent'){assert.throws(()=>begin(d,l),error);j.close();return;}j.close();if(kind==='mode')fs.chmodSync(collection(d),0o644);if(kind==='hardlink')fs.linkSync(collection(d),file(p,'extra'));if(kind==='symlink'){fs.renameSync(collection(d),file(p,'actual'));fs.symlinkSync(file(p,'actual'),collection(d));}if(kind==='bytes')fs.writeFileSync(collection(d),Buffer.alloc(2097153));if(kind==='utf8')fs.appendFileSync(collection(d),Buffer.from([255]));assert.throws(()=>begin(d,l),error);});
});
test('active handle detects same-byte inode replacement and source changes',async t=>{
 for(const kind of ['inode','source'])await sandbox((d,l,p)=>{const j=begin(d,l);j.preparePackets();let stub;
  if(kind==='inode'){fs.renameSync(collection(d),file(p,'old'));fs.writeFileSync(collection(d),fs.readFileSync(file(p,'old')),{mode:0o600});}
  if(kind==='source'){const original=fs.readFileSync;stub=t.mock.method(fs,'readFileSync',(f,...args)=>{const raw=original(f,...args);return String(f).endsWith('subject-role-review-control.ts')?Buffer.concat([Buffer.from(raw),Buffer.from('changed')]):raw;});}
  try{assert.throws(()=>j.status(),error);}finally{stub?.mock.restore();}assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
 });
});
test('partial collection or artifact saves and journal fsync uncertainty retain stop lock',async t=>{
 for(const kind of ['collection','artifact','packets_ready','review'])await sandbox((d,l)=>{
  const j=begin(d,l);if(kind==='artifact'||kind==='review')j.preparePackets();const submission=kind==='artifact'||kind==='review'?batch(d):null;
  const original=fs.fsyncSync;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()){const raw=fs.readFileSync(fd,'utf8');if(kind==='collection'&&raw.includes('"packets"')||kind==='artifact'&&raw.includes('"submissions"')||kind==='packets_ready'&&raw.includes('"type":"packets_ready"')||kind==='review'&&raw.includes('"type":"review"'))throw Error('private fsync detail');}return original(fd);});
  try{assert.throws(()=>submission?j.recordReview(submission):j.preparePackets(),error);}finally{stub.mock.restore();}assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));assert.throws(()=>begin(d,l),error);
 });
});
test('invalid reviews and caller overrides are rejected before creating an artifact',async()=>{
 for(const kind of ['invalid','override','duplicate'])await sandbox((d,l)=>{const j=begin(d,l);j.preparePackets();const b=JSON.parse(batch(d));if(kind==='invalid')b.submissions[0].review='private';if(kind==='override')b.comparisonDecision='continue';if(kind==='duplicate')b.submissions[1]=b.submissions[0];assert.throws(()=>j.recordReview(JSON.stringify(b)),error);assert.equal(fs.existsSync(artifact(d)),false);assert.throws(()=>j.close(),error);});
});
test('close sync failures restore a stop marker and option argument errors remain fixed',async t=>{
 await sandbox((d,l)=>{const j=begin(d,l),original=fs.fsyncSync;let once=false;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(!once&&fs.fstatSync(fd).isDirectory()){once=true;throw Error('private sync');}return original(fd);});try{assert.throws(()=>j.close(),error);}finally{stub.mock.restore();}assert.ok(fs.existsSync(lock(d)));assert.throws(()=>begin(d,l),error);});
 assert.throws(()=>open({directory:'relative',rawLedger:'private'}),error);assert.throws(()=>open({},{}),error);
});
test('short writes during file creation or journal append never acknowledge saved review state',async t=>{
 for(const kind of ['collection','artifact','packets_ready','review'])await sandbox((d,l)=>{
  const j=begin(d,l);if(kind==='artifact'||kind==='review')j.preparePackets();const submission=kind==='artifact'||kind==='review'?batch(d):null;
  const original=fs.writeSync,stub=t.mock.method(fs,'writeSync',(...args)=>{const text=Buffer.isBuffer(args[1])?args[1].toString('utf8'):'';const n=original(...args);return kind==='collection'&&text.includes('"packets"')||kind==='artifact'&&text.includes('"submissions"')||kind==='packets_ready'&&text.includes('"type":"packets_ready"')||kind==='review'&&text.includes('"type":"review"')?n-1:n;});
  try{assert.throws(()=>submission?j.recordReview(submission):j.preparePackets(),error);}finally{stub.mock.restore();}
  assert.throws(()=>j.status(),error);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
 });
});
test('collection replacement during bounded read is detected and stop lock is retained',async t=>sandbox((d,l,p)=>{
 const j=begin(d,l);j.preparePackets();const original=fs.readSync;let swapped=false;
 const stub=t.mock.method(fs,'readSync',(...args)=>{const n=original(...args);if(!swapped&&Buffer.isBuffer(args[1])&&args[1].subarray(0,n).toString('utf8').includes('"packets"')){swapped=true;fs.renameSync(collection(d),file(p,'old'));fs.writeFileSync(collection(d),fs.readFileSync(file(p,'old')),{mode:0o600});}return n;});
 try{assert.throws(()=>j.status(),error);}finally{stub.mock.restore();}assert.equal(swapped,true);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
}));
