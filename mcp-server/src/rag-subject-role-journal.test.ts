// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
import {openSubjectRolePairedJournal as open,subjectRolePairedJournalManifest as manifest} from '../scripts/rag-quality/subject-role-paired-journal.ts';
import {subjectRoleTaskPlannerRequest as request} from '../scripts/rag-quality/subject-role-task-planner-request.ts';
import {parseSubjectRoleTaskPlannerResponse as parse} from '../scripts/rag-quality/subject-role-task-planner-response.ts';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.ts';
const cases=JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/role-preservation-oracle-v1.json',import.meta.url))).cases;
const hash=x=>createHash('sha256').update(x).digest('hex');
const file=d=>path.join(d,'journal.ndjson'),lock=d=>path.join(d,'running.lock');
const error=e=>e.message==='subject_role_journal_audit_required';
async function sandbox(fn){const p=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-subject-journal-')));try{await fn(path.join(p,'run'),p);}finally{fs.rmSync(p,{recursive:true,force:true});}}
function result(job){
 const c=cases[job.index],s=createQuestionUnits(c.question),refs=t=>s.units.filter(u=>u.start<t.end&&u.end>t.start).map(u=>u.id),role=t=>({label:t.text,unitIds:refs(t)});
 const plan={version:4,questionHash:s.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return parse(job.index,job.variant,job.requestHash,JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:request(job.index,job.variant).model,output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:100,total_tokens:200,output_tokens_details:{reasoning_tokens:10}}}));
}
function stage(j){for(let i=0;i<2;i++){const job=j.reserveNext();j.complete(result(job),1);}j.finishStage();}
test('separate persistence manifest fixes offline stage0 scope and hashes wrapper plus ledger',()=>{
 const m=manifest();assert.equal(m.persistenceAttached,true);assert.equal(m.transportAttached,false);assert.equal(m.reviewGateAttached,false);assert.equal(m.maxExecutableStage,0);assert.equal(m.ledger.persistenceAttached,false);assert.equal(m.ledger.jobs.length,24);assert.equal(m.sourceHash,hash(fs.readFileSync(new URL('../scripts/rag-quality/subject-role-paired-journal.ts',import.meta.url))));assert.throws(()=>manifest({}),error);
});
test('private initial and first-pair checkpoints reopen with same run and review still pending',async()=>sandbox(d=>{
 let j=open(d);const initial=j.status();assert.equal(initial.reservedRequests,0);j.close();j=open(d);assert.equal(j.status().runId,initial.runId);stage(j);const s=j.status();assert.equal(s.completedRequests,2);assert.equal(s.comparablePairs,0);assert.equal(s.audit,'pending');assert.equal(s.nextJob,null);assert.equal(s.persistenceAttached,true);j.close();assert.equal(fs.existsSync(lock(d)),false);
 j=open(d);assert.equal(j.status().checkpointHash,s.checkpointHash);assert.equal(j.status().journalManifestHash,s.journalManifestHash);j.close();assert.equal(fs.statSync(d).mode&0o777,0o700);assert.equal(fs.statSync(file(d)).mode&0o777,0o600);
}));
test('reservation and partial-pair interruption retain stop lock and never resume',async()=>{
 for(const kind of ['reserved','one_complete','two_complete','failed'])await sandbox(d=>{const j=open(d),job=j.reserveNext();if(kind==='one_complete'||kind==='two_complete')j.complete(result(job),1);if(kind==='two_complete'){const next=j.reserveNext();j.complete(result(next),1);}if(kind==='failed')j.markFailed({phase:'fetch',httpStatus:429,reason:'upstream_http'});const s=j.status();assert.equal(s.safeReopenCheckpoint,false);assert.equal(s.reservedPairs,1);assert.equal(s.unreservedPairs,11);j.close();assert.equal(fs.existsSync(lock(d)),true);assert.throws(()=>open(d),error);});
});
test('stage1 reservation is rejected and does not write or release lock',async()=>sandbox(d=>{
 const j=open(d);stage(j);const before=fs.readFileSync(file(d));assert.throws(()=>j.reserveNext(),error);assert.deepEqual(fs.readFileSync(file(d)),before);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
}));
test('concurrent handle uses common lock and cannot disturb original journal',async()=>sandbox(d=>{
 const j=open(d),before=fs.readFileSync(file(d));assert.throws(()=>open(d),error);assert.deepEqual(fs.readFileSync(file(d)),before);j.close();const again=open(d);again.close();
}));
test('insecure paths files hardlinks and symlinks stop before reusing data',async()=>{
 for(const kind of ['empty','mode','directory_mode','hardlink','symlink','directory_link'])await sandbox((d,p)=>{
  if(kind==='empty'){fs.mkdirSync(d,{mode:0o700});assert.throws(()=>open(d),error);return;}
  const j=open(d);j.close();if(kind==='mode')fs.chmodSync(file(d),0o644);if(kind==='directory_mode')fs.chmodSync(d,0o755);
  if(kind==='hardlink')fs.linkSync(file(d),path.join(p,'extra'));
  if(kind==='symlink'){fs.renameSync(file(d),path.join(p,'actual'));fs.symlinkSync(path.join(p,'actual'),file(d));}
  if(kind==='directory_link'){fs.renameSync(d,path.join(p,'actual'));fs.symlinkSync(path.join(p,'actual'),d);}
  assert.throws(()=>open(d),error);
 });
});
test('journal byte cap UTF8 truncation old manifests and orphan artifacts all reject',async()=>{
 for(const kind of ['bytes','utf8','tail','old','source','orphan','runid'])await sandbox(d=>{
  const j=open(d);j.close();
  if(kind==='bytes')fs.writeFileSync(file(d),Buffer.alloc(2097153));if(kind==='utf8')fs.appendFileSync(file(d),Buffer.from([255,10]));if(kind==='tail')fs.appendFileSync(file(d),'{');
  if(kind==='old')fs.writeFileSync(file(d),'{}\n');if(kind==='orphan')fs.writeFileSync(path.join(d,'review-stage-0.json'),'{}',{mode:0o600});
  if(kind==='source'||kind==='runid'){const rows=fs.readFileSync(file(d),'utf8').trimEnd().split('\n').map(JSON.parse);if(kind==='source')rows[0].manifest.sourceHash='0'.repeat(64);else rows[0].runId='other';fs.writeFileSync(file(d),rows.map(JSON.stringify).join('\n')+'\n');}
  assert.throws(()=>open(d),error);
 });
});
test('active file changes same inode replacement lock and source changes poison handle',async t=>{
 for(const kind of ['same_inode','replacement','lock','source'])await sandbox((d,p)=>{
  const j=open(d);let stub;
  if(kind==='same_inode'){const raw=fs.readFileSync(file(d),'utf8');fs.writeFileSync(file(d),raw.replace('persistence_manifest','persistence_manifesX'));}
  if(kind==='replacement'){fs.renameSync(file(d),path.join(p,'old'));fs.writeFileSync(file(d),fs.readFileSync(path.join(p,'old')),{mode:0o600});}
  if(kind==='lock'){fs.renameSync(lock(d),path.join(p,'old-lock'));fs.mkdirSync(lock(d),{mode:0o700});}
  if(kind==='source'){const orig=fs.readFileSync;stub=t.mock.method(fs,'readFileSync',(f,...args)=>{const v=orig(f,...args);return String(f).endsWith('subject-role-paired-journal.ts')?Buffer.concat([Buffer.from(v),Buffer.from('changed')]):v;});}
  try{assert.throws(()=>j.reserveNext(),error);}finally{stub?.mock.restore();}assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
 });
});
test('save snapshots are isolated from result or returned job mutation',async()=>sandbox(d=>{
 const j=open(d),job=j.reserveNext(),r=result(job);job.variant='other';j.complete(r,1);r.plan.tasks[0].subjects=[];r.structuralProvenance.units[0].text='changed';const next=j.reserveNext();j.complete(result(next),1);j.finishStage();const s=j.status();s.nextJob={ordinal:2};j.close();const again=open(d);assert.equal(again.status().audit,'pending');assert.equal(again.status().nextJob,null);again.close();
}));
test('strict bad completion or failure fields are refused without saving raw diagnostics',async()=>{
 for(const kind of ['undefined','role','failure'])await sandbox(d=>{const j=open(d),job=j.reserveNext(),before=fs.readFileSync(file(d));if(kind==='failure')assert.throws(()=>j.markFailed({phase:'fetch',httpStatus:500,reason:'private upstream error'}),error);else{const r=result(job);if(kind==='undefined')r.plan.extra=undefined;else r.variant='candidate';assert.throws(()=>j.complete(r,1),error);}assert.deepEqual(fs.readFileSync(file(d)),before);assert.throws(()=>j.close(),error);});
});
test('write fsync and short-write uncertainty retain lock and never acknowledge completion',async t=>{
 for(const kind of ['short','sync'])await sandbox(d=>{const j=open(d),original=fs[kind==='short'?'writeSync':'fsyncSync'];const stub=t.mock.method(fs,kind==='short'?'writeSync':'fsyncSync',(...args)=>{if(kind==='short')return original(...args)-1;throw Error('private diagnostic');});try{assert.throws(()=>j.reserveNext(),error);}finally{stub.mock.restore();}assert.throws(()=>j.status(),error);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);});
});
test('lock release and directory sync failures restore or keep stop marker',async t=>{
 for(const kind of ['remove','sync'])await sandbox(d=>{const j=open(d),original=fs.fsyncSync;let once=false;const stub=kind==='remove'?t.mock.method(fs,'rmdirSync',()=>{throw Error('private');}):t.mock.method(fs,'fsyncSync',fd=>{if(!once&&fs.fstatSync(fd).isDirectory()){once=true;throw Error('private');}return original(fd);});try{assert.throws(()=>j.close(),error);}finally{stub.mock.restore();}assert.ok(fs.existsSync(lock(d)));assert.throws(()=>open(d),error);});
});
test('close exception after descriptor closure is fixed and leaves stop lock',async t=>sandbox(d=>{
 const j=open(d),original=fs.closeSync,stub=t.mock.method(fs,'closeSync',fd=>{original(fd);throw Error('private close fault');});
 try{assert.throws(()=>j.close(),error);}finally{stub.mock.restore();}
 assert.ok(fs.existsSync(lock(d)));assert.throws(()=>j.status(),error);assert.throws(()=>open(d),error);
}));
test('path replacement during bounded read is caught by post-read same-fd identity check',async t=>sandbox((d,p)=>{
 const j=open(d),original=fs.readSync;let swapped=false;
 const stub=t.mock.method(fs,'readSync',(...args)=>{const n=original(...args);if(!swapped){swapped=true;fs.renameSync(file(d),path.join(p,'original'));fs.writeFileSync(file(d),fs.readFileSync(path.join(p,'original')),{mode:0o600});}return n;});
 try{assert.throws(()=>j.status(),error);}finally{stub.mock.restore();}
 assert.equal(swapped,true);assert.throws(()=>j.close(),error);assert.ok(fs.existsSync(lock(d)));
}));
