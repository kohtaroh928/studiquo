import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {runUnitPlannerStage as run} from '../scripts/rag-quality/unit-task-planner-live.mjs';
import {recordUnitLivePlannerReview as register} from '../scripts/rag-quality/unit-task-planner-live-review.mjs';
import {createQuestionUnits} from '../scripts/rag-quality/question-units.mjs';
import {unitTaskPlannerRequest} from '../scripts/rag-quality/unit-task-planner-request.mjs';
import {unitPlanReviewBinding,UNIT_REVIEW_DIMENSIONS} from '../scripts/rag-quality/unit-plan-semantic-review.mjs';
const oracle=JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
const key='synthetic_dummy_quoted_key_123456';
const rows=d=>fs.readFileSync(path.join(d,'journal.ndjson'),'utf8').trim().split('\n').map(JSON.parse);
async function sandbox(fn){const parent=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-unit-live-')));try{await fn(path.join(parent,'run'));}finally{fs.rmSync(parent,{recursive:true,force:true});}}
function response(body){
 const question=JSON.parse(JSON.parse(body).input[0].content[0].text).question,c=oracle.cases.find(c=>c.question===question);assert.ok(c);
 const source=createQuestionUnits(c.question),refs=s=>source.units.filter(u=>u.start<s.end&&u.end>s.start).map(u=>u.id),role=s=>({label:s.text,unitIds:refs(s)}),plan={version:4,questionHash:source.questionHash,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:role(r.attribute),subjects:r.subjects.map(role),conditions:r.conditions.map(role),requestUnitIds:[...new Set(r.requestSpans.flatMap(refs))],resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:20}}};}
const json=x=>new Response(JSON.stringify(x),{headers:{'content-type':'application/json'}});
const mock=async(url,o)=>json(response(o.body));
function review(s,decision='continue'){
 const cases=[];for(let index=[0,1,4][s.stage];index<[1,4,8][s.stage];index++){
  const c=oracle.cases[index],p=JSON.parse(response(JSON.stringify(unitTaskPlannerRequest(index))).output[0].content[0].text),binding=unitPlanReviewBinding(c.question,JSON.stringify(p),JSON.stringify(c));
  const v={...binding,reviewerRole:'independent_scope_reviewer',artifactHash:'a'.repeat(64),representability:c.requirements.map(r=>({requirementId:r.id,status:'representable'})),pairs:p.tasks.map((t,i)=>({taskId:t.id,requirementId:c.requirements[i].id,dimensions:Object.fromEntries(UNIT_REVIEW_DIMENSIONS.map(k=>[k,'pass']))}))};cases.push({index,review:JSON.stringify(v)});
 }return {stage:s.stage,completed:s.completed,checkpointHash:s.checkpointHash,manifestHash:s.manifestHash,runId:s.runId,decision,cases};
}
test('fixed stages send 1+3+4 after durable reservations and only after bound reviews',async()=>sandbox(async directory=>{
 let calls=0;const fetchImpl=async(url,o)=>{assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(o.redirect,'error');assert.equal(o.headers.authorization,'Bearer '+key);assert.equal(rows(directory).at(-1).type,'reserved');assert.equal(rows(directory).at(-1).index,calls++);return json(response(o.body));};
 for(const [i,expected] of [1,4,8].entries()){
  const result=await run({directory,apiKey:key,fetchImpl});assert.equal(result.completed,expected);assert.equal(result.dispatches,[1,3,4][i]);assert.equal(result.reviewRequired,true);
  const waiting=await run({directory,apiKey:key,fetchImpl});assert.equal(waiting.dispatches,0);assert.equal(calls,expected);
  register({directory,review:review(result)});
 }
 const done=await run({directory,apiKey:key,fetchImpl});assert.equal(done.dispatches,0);assert.equal(done.finalReviewComplete,true);assert.equal(done.reservedMicroUSD,65536);assert.equal(calls,8);assert.ok(!JSON.stringify(rows(directory)).includes(key));
}));
test('review stop prevents every later stage and review entry rejects extra capability arguments',async()=>sandbox(async directory=>{
 const s=await run({directory,apiKey:key,fetchImpl:mock});register({directory,review:review(s,'stop')});let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);assert.throws(()=>register({directory,review:review(s),apiKey:key}));
}));
test('HTTP usage refusal and role contract failures stop once with fixed diagnosis and no raw content',async()=>{
 for(const kind of ['http','usage','refusal','references','label','transport'])await sandbox(async directory=>{
  let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async(url,o)=>{calls++;if(kind==='http')return new Response('synthetic_private_detail',{status:429});if(kind==='transport')throw Error('synthetic_private_detail '+key);const r=response(o.body);
   if(kind==='usage')r.usage.total_tokens++;
   if(kind==='refusal')r.output[0].content=[{type:'refusal',refusal:'synthetic_private_detail'}];
   if(kind==='references'||kind==='label'){const p=JSON.parse(r.output[0].content[0].text);if(kind==='references')p.tasks[0].attribute.unitIds=['u99'];else p.tasks[0].attribute.label='x'.repeat(257);r.output[0].content[0].text=JSON.stringify(p);}return json(r);
  }}),/audit_required/);assert.equal(calls,1);const last=rows(directory).at(-1);assert.equal(last.type,'failed');assert.equal(last.reason,{http:'upstream_http',usage:'unit_task_planner_invalid_usage',refusal:'unit_task_planner_refused',references:'unit_task_planner_references',label:'unit_task_planner_label',transport:'transport_or_unknown'}[kind]);
  assert.ok(!JSON.stringify(rows(directory)).includes(key));assert.ok(!JSON.stringify(rows(directory)).includes('synthetic_private_detail'));assert.ok(fs.existsSync(path.join(directory,'running.lock')));await assert.rejects(run({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,1);
 });
});
test('secret reflection invalid UTF8 content type and oversized bodies stop before persistence',async()=>{
 for(const kind of ['secret','utf8','type','bytes'])await sandbox(async directory=>{
  await assert.rejects(run({directory,apiKey:key,fetchImpl:async(url,o)=>{
   if(kind==='secret'){const r=response(o.body);r.extra=key;return json(r);}return new Response(kind==='utf8'?new Uint8Array([255]):kind==='bytes'?'x'.repeat(262145):'synthetic_private_detail',{headers:{'content-type':kind==='type'?'text/plain':'application/json'}});
  }}));assert.equal(rows(directory).at(-1).reason,'response_body_failure');assert.ok(!JSON.stringify(rows(directory)).includes(key));
 });
});
test('stalled headers and body cancel on request deadline without retries',async()=>{
 for(const kind of ['headers','body'])await sandbox(async directory=>{
  let calls=0,cancelled=false;await assert.rejects(run({directory,apiKey:key,timeoutMs:10,fetchImpl:async()=>{calls++;if(kind==='headers')await new Promise(r=>setTimeout(r,35));return new Response(new ReadableStream({cancel(){cancelled=true;}}),{headers:{'content-type':'application/json'}});}}));await new Promise(r=>setTimeout(r,40));assert.equal(calls,1);assert.equal(cancelled,true);assert.equal(rows(directory).at(-1).reason,'timeout');
 });
});
test('reservation fsync failure or expiry causes zero dispatches',async t=>{
 for(const kind of ['failure','expiry'])await sandbox(async directory=>{
  const original=fs.fsyncSync;let hit=false,calls=0;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(!hit&&fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"reserved"')){hit=true;if(kind==='failure')throw Error('private');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,40);}return original(fd);});
  try{await assert.rejects(run({directory,apiKey:key,totalMs:10,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);}finally{stub.mock.restore();}
  assert.ok(fs.existsSync(path.join(directory,'running.lock')));
 });
});
test('deadline crossed during completion guard prevents a completed record',async t=>sandbox(async directory=>{
 let ready=false,delayed=false;const original=fs.readFileSync;const stub=t.mock.method(fs,'readFileSync',(file,...args)=>{const value=original(file,...args);if(ready&&!delayed&&String(file).endsWith('task-plan-v2.mjs')){delayed=true;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,60);}return value;});
 try{await assert.rejects(run({directory,apiKey:key,timeoutMs:30,fetchImpl:async(url,o)=>{ready=true;return json(response(o.body));}}));assert.equal(delayed,true);assert.equal(rows(directory).at(-1).type,'reserved');assert.ok(fs.existsSync(path.join(directory,'running.lock')));}finally{stub.mock.restore();}
}));
test('completion fsync failure leaves uncertain terminal without a second failure record',async t=>sandbox(async directory=>{
 const original=fs.fsyncSync;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"completed"'))throw Error('private');return original(fd);});
 try{await assert.rejects(run({directory,apiKey:key,fetchImpl:mock}));assert.equal(rows(directory).at(-1).type,'completed');assert.equal(rows(directory).filter(r=>r.type==='failed').length,0);assert.ok(fs.existsSync(path.join(directory,'running.lock')));}finally{stub.mock.restore();}
}));
test('concurrency cannot duplicate a stage and progress exceptions retain an incomplete run',async()=>{
 await sandbox(async directory=>{let release;const pending=new Promise(r=>release=r);const first=run({directory,apiKey:key,fetchImpl:async(url,o)=>{await pending;return json(response(o.body));}});try{await assert.rejects(run({directory,apiKey:key,fetchImpl:mock}));}finally{release();}assert.equal((await first).dispatches,1);});
 await sandbox(async directory=>{await assert.rejects(run({directory,apiKey:key,fetchImpl:mock,onProgress:()=>{throw Error(key);}}));assert.equal(rows(directory).at(-1).type,'completed');assert.ok(fs.existsSync(path.join(directory,'running.lock')));});
});
test('unknown selectors widened limits and credentials embedded in request are rejected before dispatch',async()=>{
 for(const change of [{index:0},{model:'other'},{timeoutMs:60001},{totalMs:240001},{apiKey:'comparisonPermission'}])await sandbox(async directory=>{let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async()=>{calls++;},...change}));assert.equal(calls,0);});
});
test('completed and stage checkpoint fsync overruns or failure retain uncertain terminal and lock',async t=>{
 for(const kind of ['completed_overrun','stage_overrun','stage_failure'])await sandbox(async directory=>{
  const target=kind==='completed_overrun'?'completed':'stage_finished';let hit=false;const original=fs.fsyncSync;
  const stub=t.mock.method(fs,'fsyncSync',fd=>{if(!hit&&fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"'+target+'"')){hit=true;if(kind==='stage_failure')throw Error('private');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,250);}return original(fd);});
  try{await assert.rejects(run({directory,apiKey:key,totalMs:200,fetchImpl:mock}));assert.equal(hit,true);assert.equal(rows(directory).at(-1).type,target);assert.equal(rows(directory).filter(r=>r.type==='failed').length,0);assert.ok(fs.existsSync(path.join(directory,'running.lock')));}finally{stub.mock.restore();}
 });
});
test('decoded response and twice-decoded final plan secrets are rejected before journal completion',async()=>{
 const escaped=[...key].map(c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0')).join('');
 for(const kind of ['outer','inner','property'])await sandbox(async directory=>{
  let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async(url,o)=>{
   calls++;const r=response(o.body);let raw;
   if(kind==='inner'){
    const p=JSON.parse(r.output[0].content[0].text);p.tasks[0].attribute.label='SYNTHETICGUARDLABEL';r.output[0].content[0].text=JSON.stringify(p).replace('SYNTHETICGUARDLABEL',escaped);raw=JSON.stringify(r);
   }else{if(kind==='outer')r.extra=key;else r[key]=0;raw=JSON.stringify(r).replaceAll(key,escaped);}
   assert.equal(raw.includes(key),false);return new Response(raw,{headers:{'content-type':'application/json'}});
  }}));
  assert.equal(calls,1);const list=rows(directory);assert.equal(list.at(-1).reason,'unit_secret_guard_reflection');assert.equal(list.some(r=>r.type==='completed'),false);assert.equal(JSON.stringify(list).includes(key),false);assert.equal(JSON.stringify(list).includes(escaped),false);assert.ok(fs.existsSync(path.join(directory,'running.lock')));
 });
});
test('live stage2 refuses missing stage0 artifact before any dispatch or reservation',async()=>sandbox(async directory=>{
 let s;for(let stage=0;stage<2;stage++){s=await run({directory,apiKey:key,fetchImpl:mock});register({directory,review:review(s)});}const count=rows(directory).length;fs.unlinkSync(path.join(directory,'review-stage-0.json'));let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);assert.equal(rows(directory).length,count);
}));
test('offline v4 manifests are never accepted as live runs',async()=>sandbox(async directory=>{
 const {openUnitPlannerJournal}=await import('../scripts/rag-quality/unit-task-planner-journal.mjs');const j=openUnitPlannerJournal(directory);j.close();let calls=0;await assert.rejects(run({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);assert.equal(rows(directory)[0].manifest.transportAttached,false);
}));
test('request-secret collision and overlarge stage timeout fail before sending',async()=>{
 for(const options of [{apiKey:'comparisonPermission'},{totalMs:60001}])await sandbox(async directory=>{let calls=0;await assert.rejects(run({directory,apiKey:key,...options,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);if(options.apiKey)assert.equal(fs.existsSync(directory),false);});
});
