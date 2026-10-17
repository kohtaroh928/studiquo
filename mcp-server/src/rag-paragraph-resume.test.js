import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,writeFile,link,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {newResumeState,resumePlan,checkpointRow,saveResumeState,resumeEvaluation,withResumeLock,checkResumePaths,loadResumeFixture} from '../scripts/rag-quality/paragraph-resume.mjs';
const original=JSON.parse(await readFile(new URL('../scripts/rag-quality/citation-intent-fixture.json',import.meta.url)));
const fixture={...original,cases:original.cases.slice(0,2)};
const row=(id,status='shadow')=>({id,status,shadow:{referenceIds:['r1']},provider:null});
test('quota wait blocks before key reading or external evaluation',async()=>{
 const state=newResumeState(fixture);state.notBeforeUTC=new Date(2000).toISOString();state.quotaOrigin='api_completed_at';let reads=0,calls=0;
 const out=await resumeEvaluation(fixture,state,{now:()=>1000,loadKey:async()=>{reads++;},evaluate:async()=>{calls++;}});
 assert.equal(out.status,'quota_wait');assert.equal(out.newCalls,0);assert.equal(reads,0);assert.equal(calls,0);
});
test('identity binds question, references, label rubric and snapshot',()=>{
 const state=newResumeState(fixture);
 for(const mutate of [f=>f.cases[0].question+='追記',f=>f.cases[0].references[0].pageNumber=99,f=>f.cases[0].facts[0].protected=!f.cases[0].facts[0].protected]){
  const changed=structuredClone(fixture);mutate(changed);assert.throws(()=>resumePlan(changed,state,1000),/stale/);
 }
});
test('checkpoint skips structurally completed cases and reruns failed or unattempted only',async()=>{
 let state=checkpointRow(newResumeState(fixture),row(fixture.cases[0].id),1000);state=checkpointRow(state,row(fixture.cases[1].id,'fallback'),1000);let saves=0;
 const out=await resumeEvaluation(fixture,state,{now:()=>2000,loadKey:async()=>'synthetic',save:async()=>saves++,evaluate:async(f,options)=>{
  assert.deepEqual(f.cases.map(c=>c.id),[fixture.cases[1].id]);await options.onRow(row(f.cases[0].id));return {summary:{attempts:1}};
 }});
 assert.equal(out.newCalls,1);assert.equal(saves,1);assert.deepEqual(out.inheritedIds,[fixture.cases[0].id]);assert.equal(resumePlan(fixture,out.state,2000).remaining.length,0);
});
test('already complete run reads no key and starts no provider',async()=>{
 let state=newResumeState(fixture);for(const c of fixture.cases)state=checkpointRow(state,row(c.id),1000);
 const out=await resumeEvaluation(fixture,state,{now:()=>2000,loadKey:async()=>{throw Error('must not read');}});assert.equal(out.status,'already_complete');
});
test('daily quota checkpoint persists deadline and never shortens an existing hint',()=>{
 const state=newResumeState(fixture);state.notBeforeUTC=new Date(50000).toISOString();state.quotaOrigin='legacy_mtime_hint';
 const updated=checkpointRow(state,{...row(fixture.cases[0].id,'fallback'),provider:{httpStatus:429,error:{retrySeconds:20}}},1000);assert.equal(updated.notBeforeUTC,state.notBeforeUTC);assert.equal(updated.quotaOrigin,'legacy_mtime_hint');
 assert.equal(resumePlan(fixture,updated,2000).blocked,true);assert.equal(resumePlan(fixture,updated,50001).blocked,false);
});
test('checkpoint survives interruption after one response',async()=>{
 let saved;
 await assert.rejects(resumeEvaluation(fixture,newResumeState(fixture),{now:()=>1000,loadKey:async()=>'synthetic',save:async s=>{saved=s;},evaluate:async(f,o)=>{await o.onRow(row(f.cases[0].id));throw Error('interrupted');}}),/interrupted/);
 assert.deepEqual(resumePlan(fixture,saved,2000).completedIds,[fixture.cases[0].id]);
});
test('state rejects unknown references, case duplication and arbitrary fields',()=>{
 for(const mutate of [s=>s.cases.push({...row('missing'),referenceIds:[],completedAtUTC:new Date(1000).toISOString()}),s=>s.rawBody='PRIVATE',s=>s.cases[0].referenceIds=['missing']]){
  const s=checkpointRow(newResumeState(fixture),row(fixture.cases[0].id),1000);mutate(s);assert.throws(()=>resumePlan(fixture,s,2000));
 }
});
test('atomic state writer refuses credential path, hardlink and symlink',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'paragraph-resume-test-'));
 try{
  const key=join(dir,'key'),hard=join(dir,'hard'),sym=join(dir,'sym'),out=join(dir,'state');await writeFile(key,'SYNTHETIC_SECRET');await link(key,hard);await symlink(key,sym);
  for(const path of [key,hard,sym])await assert.rejects(saveResumeState(path,key,newResumeState(fixture)));
  await saveResumeState(out,key,newResumeState(fixture));assert.equal(JSON.parse(await readFile(out,'utf8')).version,1);assert.equal(await readFile(key,'utf8'),'SYNTHETIC_SECRET');
 }finally{await rm(dir,{recursive:true,force:true});}
});

test('run lock prevents concurrent evaluation and releases on error',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'paragraph-lock-test-'));
 try{
  const state=join(dir,'state'),key=join(dir,'key');await writeFile(key,'SYNTHETIC');
  await withResumeLock(state,key,async()=>{await assert.rejects(withResumeLock(state,key,async()=>{throw Error('must not run');}),e=>e.code==='EEXIST');});
  await assert.rejects(withResumeLock(state,key,async()=>{throw Error('interrupted');}),/interrupted/);
  assert.equal(await withResumeLock(state,key,async()=>42),42);
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('report cannot overwrite the reserved lock through a path or alias',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'paragraph-path-test-'));
 try{
  const state=join(dir,'state'),key=join(dir,'key'),lock=`${state}.lock`,hard=join(dir,'hard'),sym=join(dir,'sym');
  await writeFile(key,'SYNTHETIC');await writeFile(lock,'');await link(lock,hard);await symlink(lock,sym);
  for(const report of [lock,hard,sym])await assert.rejects(checkResumePaths(state,key,report));
  await checkResumePaths(state,key,join(dir,'report'));
  const alias=join(dir,'alias');await symlink(dir,alias);const absent=join(dir,'absent-state');
  await assert.rejects(checkResumePaths(absent,key,join(alias,'absent-state.lock')));
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('default fixture profile preserves the existing four-case experiment identity',async()=>{
 const f=await loadResumeFixture();assert.equal(f.cases.length,4);
 assert.equal(newResumeState(f).identity,'64065b142e48cca4b4295ba6359e74d5339a38296fb8e1625cf79f669a5a0f58');
});
test('multi-paragraph profile is separate and cannot reuse the original completed state',async()=>{
 const coverage=await loadResumeFixture(),multi=await loadResumeFixture('multiparagraph');
 assert.equal(multi.cases.length,4);assert.ok(multi.cases.every(c=>c.id.startsWith('multi-')));
 assert.throws(()=>resumePlan(multi,newResumeState(coverage)),/stale/);
});
test('arbitrary paths and unknown fixture profiles are refused',async()=>{
 for(const profile of ['../private.json','library','',null])await assert.rejects(loadResumeFixture(profile),/unknown_fixture_profile/);
});
