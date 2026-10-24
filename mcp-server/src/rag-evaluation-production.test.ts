// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {captureProductionProbe,capturePolicyProbe,productionProbeMetadata,productionProbeBody,PRODUCTION_CASE_IDS,POLICY_CASE_IDS} from '../scripts/rag-quality/evaluation-50-production.ts';
import {e50Manifest,runE50Stage} from '../scripts/rag-quality/evaluation-50-live.ts';
import {loadEvaluation50} from '../scripts/rag-quality/evaluation-50.ts';
import {comparisonBoundaryFixture} from '../scripts/rag-quality/comparison-boundary-fixture.ts';
const directory=()=>fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()),'studiquo-prod-test-'));
const response=()=>new Response('data: {"type":"response.output_text.delta","delta":"synthetic test"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"gpt-6-luna","usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60,"output_tokens_details":{"reasoning_tokens":3}}}}\n\n');

test('fixed production capture is offline, paired, opaque and cannot be modified',async()=>{
 const original=globalThis.fetch;let external=0;
 globalThis.fetch=async()=>{external++;throw Error('unexpected_external_call');};
 try {
  const p=await captureProductionProbe();assert.equal(external,0);
  const meta=productionProbeMetadata(p);assert.equal(meta.rows.length,6);
  assert.deepEqual([...new Set(meta.rows.map(r=>r.caseId))],[...PRODUCTION_CASE_IDS]);
  for(const id of PRODUCTION_CASE_IDS) {
   const a=productionProbeBody(p,id,'source_only'),b=productionProbeBody(p,id,'explain');
   assert.deepEqual(a.input,b.input);assert.match(a.instructions,/学習アプリ「Studiquo」/);
   assert.equal(a.max_output_tokens,8192);assert.equal(a.reasoning.effort,'medium');
   assert.equal(a.service_tier,'default');assert.equal(a.store,false);assert.equal(a.tools,undefined);
   assert.ok(Buffer.byteLength(JSON.stringify(a))<=24576);
   a.instructions='mutated';assert.notEqual(productionProbeBody(p,id,'source_only').instructions,'mutated');
  }
  meta.rows.length=0;assert.equal(productionProbeMetadata(p).rows.length,6);
  assert.throws(()=>productionProbeBody({},PRODUCTION_CASE_IDS[0],'source_only'));
  assert.throws(()=>productionProbeBody(p,'e50-versions-04','source_only'));
  assert.throws(()=>e50Manifest(loadEvaluation50(),['e50-versions-04'],p));
  const bank=loadEvaluation50();bank.cases[0].question+='changed';assert.throws(()=>e50Manifest(bank,[...PRODUCTION_CASE_IDS],p));
 }finally{globalThis.fetch=original;}
});

test('concurrent capture is rejected and restores the fetch boundary',async()=>{
 const original=globalThis.fetch,first=captureProductionProbe();
 await assert.rejects(captureProductionProbe(),/production_capture_busy/);
 await first;assert.equal(globalThis.fetch,original);
});

test('production stage reserves 8192 output, caps six sends, skips completions and blocks uncertainty',async()=>{
 const productionProbe=await captureProductionProbe();
 for(const failed of [false,true]) {
  const d=directory();let calls=0;
  const options={directory:d,apiKey:'synthetic-test-key',caseIds:[...PRODUCTION_CASE_IDS],productionProbe,
   fetchImpl:async()=>{
    calls++;const last=JSON.parse(fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').trim().split('\n').at(-1));
    assert.equal(last.type,'reserved');assert.equal(last.reservedMicroUSD,8192);
    return failed?new Response('synthetic error',{status:503}):response();
   }};
  try {
   if(failed) {
    await assert.rejects(runE50Stage(options));await assert.rejects(runE50Stage(options),/unresolved_dispatch/);
    assert.equal(calls,1);
   }else {
    const result=await runE50Stage(options);assert.equal(calls,6);assert.equal(result.reservedMicroUSD,49152);
    await runE50Stage(options);assert.equal(calls,6);
    const fresh=await captureProductionProbe();await assert.rejects(runE50Stage({...options,productionProbe:fresh}),/manifest_mismatch/);assert.equal(calls,6);
   }
  }finally{fs.rmSync(d,{recursive:true});}
 }
});

test('CLI refuses an existing run before capture and key loading',()=>{
 const d=directory();
 try {
  const result=spawnSync(process.execPath,[new URL('../scripts/rag-quality/evaluation-50-production-live.ts',import.meta.url).pathname,d],{
   env:{...process.env,STUDIQUO_RAG_E50_PRODUCTION_REMOTE:'true',OPENAI_API_KEY:'synthetic-test-key'},encoding:'utf8'});
  assert.equal(result.status,1);assert.equal(result.stdout,'');assert.match(result.stderr,/production_evaluation_stopped/);
  assert.deepEqual(fs.readdirSync(d),[]);
 }finally{fs.rmSync(d,{recursive:true});}
});

test('separate fixed boundary suite preserves the 50 bank and never sends gold checks',async()=>{
 const before=JSON.stringify(loadEvaluation50()),fixture=comparisonBoundaryFixture();
 assert.equal(fixture.cases.length,3);assert.equal(new Set(fixture.cases.map(c=>c.id)).size,3);
 const p=await captureProductionProbe('boundary'),meta=productionProbeMetadata(p);
 const ids=fixture.cases.map(c=>c.id),manifest=e50Manifest(loadEvaluation50(),ids,p);
 assert.equal(manifest.suiteId,fixture.suiteId);assert.equal(manifest.jobs.length,6);
 assert.equal(manifest.config.maxDispatches,6);assert.equal(manifest.config.outputTokens,8192);
 for(const c of fixture.cases)for(const style of ['source_only','explain']) {
  const body=productionProbeBody(p,c.id,style);
  assert.equal(meta.rows.find(r=>r.caseId===c.id&&r.style===style).status,'grounded');
  assert.ok(JSON.stringify(body.input).includes(c.question));
  assert.ok(!JSON.stringify(body).includes('humanGoldReview'));
  for(const check of c.checks)assert.ok(!JSON.stringify(body).includes(check));
 }
 assert.equal(JSON.stringify(loadEvaluation50()),before);
 assert.throws(()=>e50Manifest(loadEvaluation50(),[...PRODUCTION_CASE_IDS],p));
 const changed=loadEvaluation50();changed.cases[0].question+='changed';assert.throws(()=>e50Manifest(changed,ids,p));
 await assert.rejects(captureProductionProbe('reserved_holdout'),/invalid_production_suite/);
 const d=directory();let calls=0;
 try {
  const result=await runE50Stage({directory:d,apiKey:'synthetic-test-key',caseIds:ids,productionProbe:p,fetchImpl:async()=>{calls++;return response();}});
  assert.equal(calls,6);assert.equal(result.reservedMicroUSD,49152);
  const other=await captureProductionProbe();await assert.rejects(runE50Stage({directory:d,apiKey:'synthetic-test-key',caseIds:[...PRODUCTION_CASE_IDS],productionProbe:other,fetchImpl:async()=>{calls++;return response();}}),/manifest_mismatch/);
  assert.equal(calls,6);
 }finally{fs.rmSync(d,{recursive:true});}
});

test('policy variants preserve identical saved inputs and isolate dedup from partial changes',()=>{
 const probes=['v1','dedup','partial_only'].map(capturePolicyProbe);
 for(const id of POLICY_CASE_IDS)for(const style of ['source_only','explain']) {
  const bodies=probes.map(p=>productionProbeBody(p,id,style));
  const rows=probes.map(p=>productionProbeMetadata(p).rows.find(r=>r.caseId===id&&r.style===style));
  for(let i=1;i<3;i++) {
   const {instructions:a,...old}=bodies[0],{instructions:b,...next}=bodies[i];
   assert.deepEqual(next,old);assert.deepEqual(rows[i].citations,rows[0].citations);
   assert.equal(rows[i].referenceHash,rows[0].referenceHash);
  }
  if(style==='explain') assert.equal(bodies[0].instructions,bodies[1].instructions);
  // Dedup was rejected after real-answer regression; retained candidate is C only.
  if(rows[0].status==='grounded') assert.equal(bodies[0].instructions,bodies[2].instructions);
  else {
   assert.equal(rows[0].status,'partial');
   assert.match(bodies[0].instructions,/at least one requested comparison subject is missing/);
   assert.match(bodies[2].instructions,/A missing attribute does not mean that all evidence for that subject is missing/);
  }
 }
 assert.throws(()=>capturePolicyProbe('holdout'),/invalid_policy_variant/);
 const p=probes[0],ids=[...POLICY_CASE_IDS];
 assert.throws(()=>e50Manifest(loadEvaluation50(),ids.slice(1),p),/invalid_policy_selection/);
 const bank=loadEvaluation50();bank.cases[0].question+='changed';
 assert.throws(()=>e50Manifest(bank,ids,p),/invalid_policy_selection/);
 const body=productionProbeBody(p,ids[0],'source_only');body.instructions='changed';
 assert.notEqual(productionProbeBody(p,ids[0],'source_only').instructions,'changed');
 assert.throws(()=>productionProbeBody({},ids[0],'source_only'));
});

test('policy run reuses reservation-before-dispatch, uncertainty stop and cross-variant manifest rejection',async()=>{
 for(const failed of [false,true]) {
  const d=directory(),p=capturePolicyProbe('v1');let calls=0;
  const options={directory:d,apiKey:'synthetic-test-key',caseIds:[...POLICY_CASE_IDS],productionProbe:p,fetchImpl:async()=>{
   calls++;const records=fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').trim().split('\n').map(JSON.parse);
   assert.equal(records.at(-1).type,'reserved');assert.equal(records.at(-1).reservedMicroUSD,8192);
   return failed?new Response('synthetic error',{status:503}):response();
  }};
  try {
   if(failed) {
    await assert.rejects(runE50Stage(options));
    await assert.rejects(runE50Stage(options),/unresolved_dispatch/);assert.equal(calls,1);
   }else {
    const result=await runE50Stage(options);assert.equal(calls,6);assert.equal(result.reservedMicroUSD,49152);
    await runE50Stage({...options,productionProbe:capturePolicyProbe('v1')});assert.equal(calls,6);
   }
   await assert.rejects(runE50Stage({...options,productionProbe:capturePolicyProbe('current')}),/manifest_mismatch/);
   assert.equal(calls,failed?1:6);
  }finally{fs.rmSync(d,{recursive:true});}
 }
});

test('policy CLI rejects existing directories and invalid revisions before credential loading or sends',()=>{
 const d=directory(),fresh=path.join(d,'not-created');
 try {
  for(const [dir,variant] of [[d,'v1'],[fresh,'untrusted variant']]) {
   const result=spawnSync(process.execPath,[new URL('../scripts/rag-quality/prompt-policy-live.ts',import.meta.url).pathname,dir,variant],{
    env:{...process.env,STUDIQUO_RAG_POLICY_REMOTE:'true',OPENAI_API_KEY:'synthetic-test-key'},encoding:'utf8'});
   assert.equal(result.status,1);assert.equal(result.stdout,'');assert.match(result.stderr,/policy_evaluation_stopped/);
  }
  assert.deepEqual(fs.readdirSync(d),[]);
 }finally{fs.rmSync(d,{recursive:true});}
});
