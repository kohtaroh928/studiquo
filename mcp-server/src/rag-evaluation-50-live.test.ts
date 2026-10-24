// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {e50Body,e50Manifest,runE50Stage} from '../scripts/rag-quality/evaluation-50-live.ts';
import {loadEvaluation50} from '../scripts/rag-quality/evaluation-50.ts';

const key='synthetic-e50-test-key';
const temp=()=>fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()),'studiquo-e50-test-'));
const good=(usage={input_tokens:200,output_tokens:50,total_tokens:250,output_tokens_details:{reasoning_tokens:20}})=>new Response('data: '+JSON.stringify({type:'response.output_text.delta',delta:'synthetic answer'})+'\n\ndata: '+JSON.stringify({type:'response.completed',response:{status:'completed',model:'gpt-6-luna',usage}})+'\n\n');
const records=d=>fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').trimEnd().split('\n').map(JSON.parse);
const sha=v=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
function rewrite(d,events){let previous=null;const lines=events.map(e=>{const r={...e,previous};previous=sha(r);return JSON.stringify(r);});fs.writeFileSync(path.join(d,'journal.ndjson'),lines.join('\n')+'\n',{mode:0o600});}

test('fixed body excludes gold and pins storage model output reasoning and input limits',()=>{
 const bank=loadEvaluation50(),c=bank.cases[0],body=e50Body(c,'source_only');
 assert.equal(body.model,'gpt-6-luna');assert.equal(body.store,false);assert.equal(body.max_output_tokens,2048);assert.equal(body.service_tier,'default');assert.equal(body.reasoning.effort,'medium');
 assert.equal(body.tools,undefined);assert.equal(body.previous_response_id,undefined);
 const edited=structuredClone(c);edited.claims=[];edited.forbiddenClaims=['rubric sentinel'];
 assert.deepEqual(e50Body(edited,'source_only'),body);
 assert.match(body.instructions,/信頼できない資料データ/);
 assert.match(body.instructions,/even if labeled as supplemental/); // Existing source-only policy boundary.
 edited.question='x'.repeat(30000);assert.throws(()=>e50Body(edited,'explain'),/input_size_limit/);
 const a=e50Body(c,'source_only'),b=e50Body(c,'explain');assert.deepEqual(a.input,b.input);
 assert.equal(e50Manifest().jobs.length,60);assert.ok(e50Manifest().jobs.every(j=>!j.caseId.endsWith('-04')&&!j.caseId.endsWith('-05')));
});

test('private durable reserve precedes every call; stage cap and resume skip successful rows',async()=>{
 const d=temp();let n=0;
 try {
  const fetchImpl=async(url,o)=>{n++;assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(o.redirect,'error');assert.equal(records(d).at(-1).type,'reserved');return good();};
  const a=await runE50Stage({directory:d,apiKey:key,fetchImpl});
  assert.equal(n,6);assert.equal(a.completed,6);assert.equal(a.dispatches,6);
  const old=records(d).filter(r=>r.type==='reserved').map(r=>r.id);
  const b=await runE50Stage({directory:d,apiKey:key,fetchImpl});
  assert.equal(n,12);assert.equal(b.completed,12);assert.equal(b.reservedMicroUSD,a.reservedMicroUSD*2);
  assert.ok(records(d).filter(r=>r.type==='reserved').slice(6).every(r=>!old.includes(r.id)));
  assert.equal(fs.statSync(d).mode&0o777,0o700);assert.equal(fs.statSync(path.join(d,'journal.ndjson')).mode&0o777,0o600);
  assert.ok(!fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').includes(key));
 }finally{fs.rmSync(d,{recursive:true});}
});

for(const status of [429,503])test(`first ${status} stops and blocks all future automatic dispatches`,async()=>{
 const d=temp();let n=0;const fetchImpl=async()=>{n++;return new Response('private '+key,{status});};
 try {await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl}));await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl}),/unresolved_dispatch/);assert.equal(n,1);assert.ok(!JSON.stringify(records(d)).includes(key));}
 finally{fs.rmSync(d,{recursive:true});}
});

test('usage missing overshoot incomplete reflected secret and mismatched model all stop after one',async()=>{
 const bodies=[()=>good(undefined),()=>good({input_tokens:40000,output_tokens:1,total_tokens:40001,output_tokens_details:{reasoning_tokens:0}}),()=>new Response('data: {"type":"response.output_text.delta","delta":"partial"}\n\n'),()=>new Response('data: '+JSON.stringify({type:'response.output_text.delta',delta:key})+'\n\n'),()=>new Response('data: {"type":"response.output_text.delta","delta":"a"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"other"}}\n\n')];
 // Explicit missing usage response (good(undefined) would use its default).
 bodies[0]=()=>new Response('data: {"type":"response.output_text.delta","delta":"a"}\n\ndata: {"type":"response.completed","response":{"status":"completed","model":"gpt-6-luna"}}\n\n');
 for(const response of bodies) {
  const d=temp();let n=0;
  try{await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return response();}}));assert.equal(n,1);await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return good();}}));assert.equal(n,1);}
  finally{fs.rmSync(d,{recursive:true});}
 }
});

test('stale lock symlink and permissive artifact are refused before dispatch',async()=>{
 let n=0;const fetchImpl=async()=>{n++;return good();};
 for(const mode of ['lock','symlink','permissions']) {
  const d=temp();
  try {
   if(mode==='lock')fs.mkdirSync(path.join(d,'running.lock'));
   if(mode==='symlink')fs.symlinkSync('/private/tmp/absent-e50-file',path.join(d,'journal.ndjson'));
   if(mode==='permissions')fs.chmodSync(d,0o755);
   await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl}));assert.equal(n,0);
  }finally{fs.rmSync(d,{recursive:true});}
 }
});

test('crash reservation completion-save failure corruption and changed bank/rates block resume',async()=>{
 for(const mode of ['reserved','save-failed','truncated','bank','rates','budget']) {
  const d=temp();let n=0;const fetchImpl=async()=>{n++;return good();};
  try {
   await runE50Stage({directory:d,apiKey:key,fetchImpl});
   const events=records(d);
   if(mode==='reserved'||mode==='save-failed')rewrite(d,events.slice(0,mode==='reserved'?2:events.length-1));
   if(mode==='truncated')fs.appendFileSync(path.join(d,'journal.ndjson'),'partial');
   if(mode==='rates'){events[0].manifest.config.inputMicroUSDPerToken=1;rewrite(d,events);}
   if(mode==='budget'){events[0].manifest.config.budgetMicroUSD=1;rewrite(d,events);}
   const bank=loadEvaluation50();if(mode==='bank')bank.cases[0].question+=' altered';
   await assert.rejects(runE50Stage({directory:d,apiKey:key,bank,fetchImpl}));assert.equal(n,6);
  }finally{fs.rmSync(d,{recursive:true});}
 }
});

test('concurrent run cannot acquire lock while first dispatch is in flight',async()=>{
 const d=temp();let resolve,started;const ready=new Promise(r=>started=r),wait=new Promise(r=>resolve=r);
 try {
  const first=runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{started();await wait;return good();}});
  await ready;await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>good()}),/evaluation_locked/);resolve();await first;
 }finally{fs.rmSync(d,{recursive:true});}
});

test('actual reserve fsync failure prevents dispatch and actual completion write failure blocks retry',async()=>{
 for(const point of ['reserve-fsync','completed-write']) {
  const d=temp();let n=0,armed=true;
  const originalSync=fs.fsyncSync,originalWrite=fs.writeSync;
  try {
   fs.fsyncSync=function(fd){
    if(point==='reserve-fsync'&&armed&&fs.existsSync(path.join(d,'journal.ndjson'))&&fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').includes('"type":"reserved"')){armed=false;throw Error('synthetic fsync failure');}
    return originalSync(fd);
   };
   fs.writeSync=function(...args){
    if(point==='completed-write'&&armed&&Buffer.isBuffer(args[1])&&args[1].toString().includes('"type":"completed"')){armed=false;throw Error('synthetic write failure');}
    return originalWrite(...args);
   };
   await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return good();}}));
   fs.fsyncSync=originalSync;fs.writeSync=originalWrite;
   assert.equal(n,point==='reserve-fsync'?0:1);
   assert.equal(records(d).at(-1).type,'reserved');
   await assert.rejects(runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return good();}}),/unresolved_dispatch/);
   assert.equal(n,point==='reserve-fsync'?0:1);
  }finally{fs.fsyncSync=originalSync;fs.writeSync=originalWrite;fs.rmSync(d,{recursive:true});}
 }
});

test('whole development allocation stops at sixty and conservatively retains every reservation',async()=>{
 const d=temp();let n=0;
 try {
  let result;
  for(let i=0;i<10;i++)result=await runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return good();}});
  assert.equal(n,60);assert.equal(result.done,true);assert.equal(result.reservedMicroUSD,307200);
  assert.ok(result.reservedMicroUSD<=e50Manifest().config.budgetMicroUSD);
  const again=await runE50Stage({directory:d,apiKey:key,fetchImpl:async()=>{n++;return good();}});
  assert.equal(again.dispatches,0);assert.equal(n,60);
 }finally{fs.rmSync(d,{recursive:true});}
});

test('bounded development recheck excludes holdout and selection changes block resume',async()=>{
 const bank=loadEvaluation50();
 for(const ids of [[],['e50-versions-04'],['unknown'],['e50-versions-03','e50-versions-03'],bank.cases.filter(c=>c.split==='development').slice(0,4).map(c=>c.id)])assert.throws(()=>e50Manifest(bank,ids),/invalid_recheck_selection/);
 const d=temp(),caseIds=['e50-versions-03','e50-context_time-01','e50-math-01'];let n=0;
 try {
  const fetchImpl=async()=>{n++;return good();};
  const r=await runE50Stage({directory:d,apiKey:key,caseIds,fetchImpl});
  assert.equal(n,6);assert.equal(r.done,true);
  assert.deepEqual(records(d)[0].manifest.selectedCaseIds,caseIds);
  await runE50Stage({directory:d,apiKey:key,caseIds,fetchImpl});assert.equal(n,6);
  await assert.rejects(runE50Stage({directory:d,apiKey:key,caseIds:['e50-versions-01'],fetchImpl}),/manifest_mismatch/);assert.equal(n,6);
 }finally{fs.rmSync(d,{recursive:true});}
});
