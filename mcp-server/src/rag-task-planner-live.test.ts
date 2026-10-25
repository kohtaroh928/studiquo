// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {runTaskPlanner,TASK_PLANNER_LIMITS} from '../scripts/rag-quality/task-planner-live.ts';
import {taskPlanOracleV2} from '../scripts/rag-quality/task-plan-oracle-v2.ts';
const apiKey='synthetic_dummy_key_only_123456';
function response(i){
 const c=taskPlanOracleV2().cases[i],plan={version:2,status:'candidate',unresolved:[],tasks:c.requirements.map((r,k)=>({id:'t'+(k+1),operation:r.allowedOperations[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:10}}};
}
const json=r=>new Response(JSON.stringify(r),{headers:{'content-type':'application/json'}});
const records=dir=>fs.readFileSync(path.join(dir,'journal.ndjson'),'utf8').trim().split('\n').map(JSON.parse);
async function sandbox(work){const parent=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-planner-test-')));try{await work(path.join(parent,'run'),parent);}finally{fs.rmSync(parent,{recursive:true,force:true});}}

test('six fixed requests have durable prior reservations, private chained results and no seventh call',async()=>sandbox(async directory=>{
 let calls=0;const progress=[];
 const result=await runTaskPlanner({directory,apiKey,onProgress:r=>progress.push(r),fetchImpl:async(url,o)=>{
  assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(o.redirect,'error');assert.equal(o.headers.authorization,'Bearer '+apiKey);
  assert.equal(JSON.parse(o.body).stream,false);const rows=records(directory);assert.equal(rows.at(-1).type,'reserved');assert.equal(rows.at(-1).index,calls);
  return json(response(calls++));
 }});
 assert.equal(calls,6);assert.equal(result.completed,6);assert.equal(result.reservedMicroUSD,49152);assert.equal(result.releaseAccepted,false);
 assert.equal(fs.statSync(directory).mode&0o777,0o700);assert.equal(fs.statSync(path.join(directory,'journal.ndjson')).mode&0o777,0o600);
 let previous=null;for(const r of records(directory)){assert.equal(r.previous,previous);previous=createHash('sha256').update(JSON.stringify(r)).digest('hex');}
 assert.equal(records(directory).filter(r=>r.type==='reserved').length,6);
 assert.ok(!fs.readFileSync(path.join(directory,'journal.ndjson'),'utf8').includes(apiKey));
 assert.deepEqual(progress,Array.from({length:6},(_,index)=>({index,completed:index+1})));
 await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:()=>{throw Error('must not send');}}),/run_stopped/);
}));
test('HTTP error, invalid plan, usage overrun and secret reflection stop after one attempt',async()=>{
 for(const kind of ['http','plan','usage','secret'])await sandbox(async directory=>{
  let calls=0;await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:async()=>{
   calls++;if(kind==='http')return new Response('synthetic upstream secret',{status:429});
   const r=response(0);if(kind==='plan')r.output[0].content[0].text='{}';
   if(kind==='usage')r.usage.output_tokens=9000;if(kind==='secret')r.extra=apiKey;
   return json(r);
  }}),/^Error: task_planner_run_stopped$/);
  assert.equal(calls,1);const rows=records(directory);assert.equal(rows.at(-1).type,'failed');assert.equal(rows.filter(r=>r.type==='completed').length,0);
  assert.ok(!JSON.stringify(rows).includes(apiKey));assert.ok(!JSON.stringify(rows).includes('upstream secret'));
 });
});
test('timeout covers stalled response bodies and cancels their reader',async()=>sandbox(async directory=>{
 let calls=0,cancelled=false;
 const stream=new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('{'));},cancel(){cancelled=true;}});
 await assert.rejects(runTaskPlanner({directory,apiKey,timeoutMs:15,fetchImpl:async()=>{calls++;return new Response(stream,{headers:{'content-type':'application/json'}});}}),/run_stopped/);
 assert.equal(calls,1);assert.equal(cancelled,true);assert.equal(records(directory).at(-1).type,'failed');
}));
test('oversize streaming JSON is cancelled before parser acceptance',async()=>sandbox(async directory=>{
 let cancelled=false;
 const stream=new ReadableStream({start(c){c.enqueue(new Uint8Array(262145));},cancel(){cancelled=true;}});
 await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:async()=>new Response(stream,{headers:{'content-type':'application/json'}})}),/run_stopped/);
 assert.equal(cancelled,true);assert.equal(records(directory).at(-1).type,'failed');
}));
test('late headers after timeout are cancelled and never dispatch a second request',async()=>sandbox(async directory=>{
 let calls=0,cancelled=false;
 await assert.rejects(runTaskPlanner({directory,apiKey,timeoutMs:5,fetchImpl:async()=>{
  calls++;await new Promise(r=>setTimeout(r,20));return new Response(new ReadableStream({cancel(){cancelled=true;}}),{headers:{'content-type':'application/json'}});
 }}),/run_stopped/);
 await new Promise(r=>setTimeout(r,30));assert.equal(calls,1);assert.equal(cancelled,true);
}));
test('existing dirs, stale artifacts and symlink targets are refused before fetch',async()=>sandbox(async(directory,parent)=>{
 fs.mkdirSync(directory,{mode:0o700});fs.mkdirSync(path.join(directory,'running.lock'));
 let calls=0;const fetchImpl=async()=>{calls++;return json(response(0));};
 await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl}),/run_stopped/);
 const link=path.join(parent,'alias');fs.symlinkSync(directory,link);
 await assert.rejects(runTaskPlanner({directory:link,apiKey,fetchImpl}),/run_stopped/);assert.equal(calls,0);
}));
test('reservation fsync failure sends nothing; completed save failure never retries',async t=>{
 for(const phase of ['reserved','completed'])await sandbox(async directory=>{
  const original=fs.fsyncSync;let failed=false,calls=0;
  const stub=t.mock.method(fs,'fsyncSync',fd=>{
   const s=fs.fstatSync(fd);
   if(s.isFile()&&!failed&&fs.readFileSync(fd,'utf8').includes('"type":"'+phase+'"')){failed=true;throw Error('synthetic write failure');}
   return original(fd);
  });
  try{
   await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:async()=>json(response(calls++))}),/run_stopped/);
   assert.equal(calls,phase==='reserved'?0:1);
   await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:async()=>{calls++;return json(response(0));}}),/run_stopped/);
   assert.equal(calls,phase==='reserved'?0:1);
  }finally{stub.mock.restore();}
 });
});
test('limits cannot be increased by caller options and invalid keys never create runs',async()=>sandbox(async directory=>{
 assert.equal(TASK_PLANNER_LIMITS.totalReservedMicroUSD,49152);
 for(const options of [{timeoutMs:60001},{totalMs:360001},{apiKey:'bad key'}])await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:()=>{throw Error();},...options}),/run_stopped/);
 assert.equal(fs.existsSync(directory),false);
}));
test('deadline is checked again after reservation fsync before sending',async t=>sandbox(async directory=>{
 const original=fs.fsyncSync;let delayed=false,calls=0;
 const stub=t.mock.method(fs,'fsyncSync',fd=>{
  if(fs.fstatSync(fd).isFile()&&!delayed&&fs.readFileSync(fd,'utf8').includes('"type":"reserved"')){
   delayed=true;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,25);
  }return original(fd);
 });
 try{
  await assert.rejects(runTaskPlanner({directory,apiKey,totalMs:10,fetchImpl:async()=>{calls++;return json(response(0));}}),/run_stopped/);
  assert.equal(calls,0);assert.equal(records(directory).at(-1).type,'reserved');
 }finally{stub.mock.restore();}
}));
test('progress notification failure never creates a contradictory failed terminal',async()=>sandbox(async directory=>{
 let calls=0;await assert.rejects(runTaskPlanner({directory,apiKey,fetchImpl:async()=>json(response(calls++)),onProgress:()=>{throw Error('synthetic notification');}}),/^Error: task_planner_run_stopped$/);
 assert.equal(calls,1);assert.deepEqual(records(directory).map(r=>r.type),['manifest','reserved','completed']);
}));
