import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {openQuotedPlannerJournal as open,quotedJournalManifest as manifest} from '../scripts/rag-quality/quoted-task-planner-journal.mjs';
import {parseQuotedTaskPlannerResponse} from '../scripts/rag-quality/quoted-task-planner-response.mjs';
const oracle=JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const file=d=>path.join(d,'journal.ndjson');
const rows=d=>fs.readFileSync(file(d),'utf8').trim().split('\n').map(JSON.parse);
function rewrite(d,list){let previous=null;fs.writeFileSync(file(d),list.map(r=>{const next={...r,previous};previous=hash(next);return JSON.stringify(next);}).join('\n')+'\n',{mode:0o600});}
async function sandbox(fn){const parent=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-quoted-journal-')));try{await fn(path.join(parent,'run'),parent);}finally{fs.rmSync(parent,{recursive:true,force:true});}}
function completion(index){const c=oracle.cases[index],quote=s=>({text:s.text,prefix:c.question.slice(Math.max(0,s.start-128),s.start),suffix:c.question.slice(s.end,s.end+128)}),plan={version:3,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:quote(r.attribute),subjects:r.subjects.map(quote),conditions:r.conditions.map(quote),requestSpans:r.requestSpans.map(quote),resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};return parseQuotedTaskPlannerResponse(index,JSON.stringify({object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:100,total_tokens:200,output_tokens_details:{reasoning_tokens:10}}}));}
function review(j,decision='continue'){const s=j.status();return {stage:s.stage,completed:s.completed,checkpointHash:s.checkpointHash,manifestHash:s.manifestHash,runId:s.runId,reviewerRole:'independent_scope_reviewer',artifactHash:'a'.repeat(64),decision};}
function stage(j){const end=[1,4,8][j.status().stage];while(j.status().completed<end){const job=j.reserveNext();j.complete(completion(job.index),1);}j.finishStage();}
test('fixed offline manifest binds all dependencies jobs checkpoints and limits',()=>{
 const m=manifest();assert.equal(m.transportAttached,true);assert.equal(m.jobs.length,8);assert.deepEqual(m.jobs.map(j=>j.stage),[0,1,1,1,2,2,2,2]);assert.equal(m.limits.totalReservedMicroUSD,65536);assert.deepEqual(m.limits.checkpoints,[1,4,8]);assert.ok(m.sourceHashes['task-plan-v2.mjs']);assert.ok(m.sourceHashes['task-plan-paired-draft.json']);assert.throws(()=>manifest({}));
});
test('1+3+4 checkpoints require bound independent review and distinguish final generation from final review',async()=>sandbox(directory=>{
 let j=open(directory);for(const [i,end] of [1,4,8].entries()){
  stage(j);const s=j.status();assert.equal(s.completed,end);assert.equal(s.audit,'pending');assert.equal(s.generationComplete,end===8);assert.equal(s.finalReviewComplete,false);j.close();
  j=open(directory);j.recordReview(review(j));assert.equal(j.status().stage,i+1);j.close();j=open(directory);
 }
 assert.equal(j.status().finalReviewComplete,true);assert.equal(j.status().reservedMicroUSD,65536);j.close();assert.equal(rows(directory).filter(r=>r.type==='reserved').length,8);
 assert.equal(fs.statSync(directory).mode&0o777,0o700);assert.equal(fs.statSync(file(directory)).mode&0o777,0o600);
}));
test('checkpoint without review cannot reserve another job and stop review retains lock',async()=>{
 await sandbox(directory=>{const j=open(directory);stage(j);assert.throws(()=>j.reserveNext());assert.throws(()=>j.close());assert.ok(fs.existsSync(path.join(directory,'running.lock')));});
 await sandbox(directory=>{const j=open(directory);stage(j);j.recordReview(review(j,'stop'));assert.equal(j.status().stopped,true);j.close();assert.ok(fs.existsSync(path.join(directory,'running.lock')));assert.throws(()=>open(directory));});
});
test('review binds run checkpoint manifest counts role and artifact with exact fields',async()=>{
 for(const change of [r=>r.stage++,r=>r.completed++,r=>r.runId='other',r=>r.checkpointHash='0'.repeat(64),r=>r.manifestHash='0'.repeat(64),r=>r.reviewerRole='other',r=>r.artifactHash='private',r=>r.extra=0,r=>r.decision='pending'])await sandbox(directory=>{const j=open(directory);stage(j);const r=review(j);change(r);assert.throws(()=>j.recordReview(r));assert.throws(()=>j.close());});
});
test('valid chains cannot hide inconsistent quoted/resolved plans or wrong checkpoint/source',async()=>{
 for(const change of [r=>r[2].plan.tasks[0].attribute.start++,r=>r[2].quotedPlan.tasks[0].attribute.prefix='wrong',r=>r[2].usage.total++,r=>r[2].requestHash='0'.repeat(64),r=>r[3].completed=4,r=>r[0].manifest.sourceHashes['task-plan-v2.mjs']='0'.repeat(64),r=>r[1].index=1])await sandbox(directory=>{const j=open(directory);stage(j);j.close();const r=rows(directory);change(r);rewrite(directory,r);assert.throws(()=>open(directory),/audit_required/);});
});
test('reserved incomplete stages failed records and partial tails never reopen automatically',async()=>{
 for(const kind of ['reserved','complete','failed','tail'])await sandbox(directory=>{const j=open(directory);j.reserveNext();if(kind==='complete')j.complete(completion(0),1);if(kind==='failed')j.markFailed({phase:'fetch',httpStatus:null,reason:'timeout'});j.close();if(kind==='tail')fs.appendFileSync(file(directory),'{');assert.ok(fs.existsSync(path.join(directory,'running.lock')));assert.throws(()=>open(directory));});
});
test('existing empty directories symlinks hardlinks insecure files and concurrent opens are rejected',async()=>{
 for(const kind of ['empty','symlink','hardlink','mode','concurrent'])await sandbox((directory,parent)=>{
  if(kind==='empty'){fs.mkdirSync(directory,{mode:0o700});assert.throws(()=>open(directory));return;}
  const j=open(directory);if(kind==='concurrent'){assert.throws(()=>open(directory));j.close();return;}j.close();
  if(kind==='mode')fs.chmodSync(file(directory),0o644);if(kind==='hardlink')fs.linkSync(file(directory),path.join(parent,'extra'));if(kind==='symlink'){fs.renameSync(file(directory),path.join(parent,'actual'));fs.symlinkSync(path.join(parent,'actual'),file(directory));}assert.throws(()=>open(directory));
 });
});
test('fsync failures poison journal before reservation returns and never expose partial success',async t=>{
 for(const target of ['reserved','completed','stage_finished','review'])await sandbox(directory=>{
  const j=open(directory);if(target==='review')stage(j);else if(target!=='reserved')j.reserveNext();if(target==='stage_finished')j.complete(completion(0),1);
  const original=fs.fsyncSync;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"'+target+'"'))throw Error('synthetic_private_detail');return original(fd);});
  try{assert.throws(()=>target==='reserved'?j.reserveNext():target==='completed'?j.complete(completion(0),1):target==='stage_finished'?j.finishStage():j.recordReview(review(j)),e=>e.message==='quoted_journal_audit_required');}finally{stub.mock.restore();}
  assert.throws(()=>j.close());assert.ok(fs.existsSync(path.join(directory,'running.lock')));assert.throws(()=>open(directory));
 });
});
test('completion snapshots cannot be altered by caller mutation after durable save',async()=>sandbox(directory=>{
 const j=open(directory);j.reserveNext();const result=completion(0);j.complete(result,1);result.quotedPlan.tasks[0].attribute.text='changed';result.plan.tasks[0].attribute.text='changed';result.usage.total=0;j.finishStage();j.close();const reopened=open(directory);assert.equal(reopened.status().audit,'pending');reopened.close();
}));
test('undefined extra fields cannot vanish during strict comparison and source change poisons an open handle',async t=>{
 await sandbox(directory=>{const j=open(directory);j.reserveNext();const result=completion(0);result.plan.extra=undefined;assert.throws(()=>j.complete(result,1));assert.throws(()=>j.close());});
 await sandbox(directory=>{const j=open(directory),original=fs.readFileSync,stub=t.mock.method(fs,'readFileSync',(file,...args)=>{const result=original(file,...args);return String(file).endsWith('task-plan-v2.mjs')?Buffer.concat([Buffer.from(result),Buffer.from('\n// changed')]):result;});
  try{assert.throws(()=>j.reserveNext());}finally{stub.mock.restore();}assert.throws(()=>j.close());
 });
});
test('close and lock-release faults remain fixed errors and prevent automatic reuse',async t=>{
 for(const kind of ['close','rmdir','directory_sync'])await sandbox(directory=>{
  const j=open(directory);let stub,once=false;
  if(kind==='close'){const original=fs.closeSync;stub=t.mock.method(fs,'closeSync',fd=>{original(fd);throw Error('synthetic_private');});}
  if(kind==='rmdir')stub=t.mock.method(fs,'rmdirSync',()=>{throw Error('synthetic_private');});
  if(kind==='directory_sync'){const original=fs.fsyncSync;stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isDirectory()&&!once){once=true;throw Error('synthetic_private');}return original(fd);});}
  try{assert.throws(()=>j.close(),e=>e.message==='quoted_journal_audit_required');}finally{stub.mock.restore();}
  assert.ok(fs.existsSync(path.join(directory,'running.lock')));assert.throws(()=>open(directory));
 });
});
test('oversized or invalid UTF8 journals are rejected before replay without raw error text',async()=>{
 for(const kind of ['bytes','utf8'])await sandbox(directory=>{const j=open(directory);j.close();if(kind==='bytes')fs.writeFileSync(file(directory),Buffer.alloc(1048577));else fs.appendFileSync(file(directory),Buffer.from([0xff,10]));assert.throws(()=>open(directory),e=>e.message==='quoted_journal_audit_required');});
});
