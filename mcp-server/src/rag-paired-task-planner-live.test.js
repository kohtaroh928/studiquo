import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
import {pairedLiveManifest,runPairedPlannerStage,runPairedCandidateDiagnostic} from '../scripts/rag-quality/paired-task-planner-live.mjs';
const oracle=JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/task-plan-paired-oracle-v1.json',import.meta.url)));
const key='synthetic_paired_dummy_key_123456';
const hash=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const file=d=>path.join(d,'journal.ndjson');
const rows=d=>fs.readFileSync(file(d),'utf8').trim().split('\n').map(JSON.parse);
function rewrite(d,records){let previous=null;const out=records.map(r=>{const next={...r,previous};previous=hash(next);return JSON.stringify(next);}).join('\n')+'\n';fs.writeFileSync(file(d),out,{mode:0o600});}
async function sandbox(work){const parent=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-paired-live-')));try{await work(path.join(parent,'run'),parent);}finally{fs.rmSync(parent,{recursive:true,force:true});}}
function response(body){const question=JSON.parse(JSON.parse(body).input[0].content[0].text).question,c=oracle.cases.find(c=>c.question===question);assert.ok(c);
 const plan={version:2,status:'candidate',unresolved:[],tasks:c.requirements.map((r,i)=>({id:'t'+(i+1),operation:r.allowedOperations[0],attribute:r.attribute,subjects:r.subjects,conditions:r.conditions,requestSpans:r.requestSpans,resolution:'unknown',evidenceSupport:'unknown',comparisonPermission:'unknown'}))};
 return {object:'response',status:'completed',error:null,incomplete_details:null,model:'gpt-6-luna',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(plan)}]}],usage:{input_tokens:100,output_tokens:200,total_tokens:300,output_tokens_details:{reasoning_tokens:20}}};}
const json=r=>new Response(JSON.stringify(r),{headers:{'content-type':'application/json'}});
const mock=async(url,o)=>json(response(o.body));

test('fixed manifest alternates variant order within eight pairs and rejects selectors',()=>{
 const m=pairedLiveManifest();assert.equal(m.jobs.length,16);assert.equal(m.limits.totalReservedMicroUSD,131072);
 for(let i=0;i<8;i++){const pair=m.jobs.slice(i*2,i*2+2);assert.deepEqual(pair.map(j=>j.index),[i,i]);assert.deepEqual(pair.map(j=>j.variant),i%2?['candidate','baseline']:['baseline','candidate']);}
 assert.throws(()=>pairedLiveManifest({index:0}));
});
test('one private ledger resumes only at 6/12/16 and sends nothing after completion',async()=>sandbox(async directory=>{
 let calls=0;const fetchImpl=async(url,o)=>{
  assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(o.redirect,'error');assert.equal(o.headers.authorization,'Bearer '+key);
  const last=rows(directory).at(-1);assert.equal(last.type,'reserved');assert.equal(last.ordinal,calls++);return json(response(o.body));
 };
 for(const expected of [6,12,16]){const r=await runPairedPlannerStage({directory,apiKey:key,fetchImpl});assert.equal(r.completed,expected);assert.equal(r.reservedMicroUSD,expected*8192);assert.equal(fs.existsSync(path.join(directory,'running.lock')),false);}
 const final=await runPairedPlannerStage({directory,apiKey:key,fetchImpl});assert.equal(final.dispatches,0);assert.equal(calls,16);
 assert.equal(rows(directory).filter(r=>r.type==='reserved').length,16);assert.equal(rows(directory).filter(r=>r.type==='stage_finished').length,3);
 let previous=null;for(const r of rows(directory)){assert.equal(r.previous,previous);previous=hash(r);}
 assert.equal(fs.statSync(directory).mode&0o777,0o700);assert.equal(fs.statSync(file(directory)).mode&0o777,0o600);
 assert.ok(!fs.readFileSync(file(directory),'utf8').includes(key));
}));
test('HTTP, invalid usage and secret reflection halt all later stages with persistent lock',async()=>{
 for(const kind of ['http','usage','secret'])await sandbox(async directory=>{
  let calls=0;await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async(url,o)=>{calls++;if(kind==='http')return new Response('synthetic private detail',{status:500});const r=response(o.body);if(kind==='usage')r.usage.output_tokens=9000;if(kind==='secret')r.extra=key;return json(r);}}),/audit_required/);
  assert.equal(calls,1);assert.equal(rows(directory).at(-1).type,'failed');assert.equal(fs.existsSync(path.join(directory,'running.lock')),true);
  await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async()=>{calls++;return mock();}}),/audit_required/);assert.equal(calls,1);
  assert.ok(!fs.readFileSync(file(directory),'utf8').includes(key));assert.ok(!fs.readFileSync(file(directory),'utf8').includes('private detail'));
 });
});
test('valid hashchain cannot hide wrong saved plan, usage, request binding or stage checkpoint',async()=>{
 const changes=[r=>r[2].usage.total++,r=>r[2].variant='candidate',r=>r[2].requestHash='0'.repeat(64),r=>r[2].plan.tasks[0].attribute.start++,r=>r.at(-1).stage=1,r=>r.splice(-1,1),r=>r[1].reservedMicroUSD=1,r=>r[0].manifest.limits.dispatches=17];
 for(const change of changes)await sandbox(async directory=>{
  await runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock});const saved=rows(directory);change(saved);rewrite(directory,saved);let calls=0;
  await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async()=>{calls++;return mock();}}),/audit_required/);assert.equal(calls,0);
 });
});
test('truncated journal, stale lock, insecure mode and hardlink are rejected without sending',async()=>{
 for(const kind of ['tail','lock','mode','hardlink','symlink'])await sandbox(async(directory,parent)=>{
  await runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock});
  if(kind==='tail')fs.appendFileSync(file(directory),'{');
  if(kind==='lock')fs.mkdirSync(path.join(directory,'running.lock'),{mode:0o700});
  if(kind==='mode')fs.chmodSync(file(directory),0o644);
  if(kind==='hardlink')fs.linkSync(file(directory),path.join(parent,'extra'));
  if(kind==='symlink'){const actual=path.join(parent,'actual');fs.renameSync(file(directory),actual);fs.symlinkSync(actual,file(directory));}
  let calls=0;await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async()=>{calls++;return mock();}}),/audit_required/);assert.equal(calls,0);
 });
});
test('concurrent stage cannot acquire an active ledger lock',async()=>sandbox(async directory=>{
 let release;const wait=new Promise(r=>release=r);let calls=0;
 const first=runPairedPlannerStage({directory,apiKey:key,fetchImpl:async(url,o)=>{calls++;if(calls===1)await wait;return json(response(o.body));}});
 try{await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock}),/audit_required/);}finally{release();}
 assert.equal((await first).completed,6);assert.equal(calls,6);
}));
test('reservation and completion fsync failures do not send again even with visible terminal bytes',async t=>{
 for(const type of ['reserved','completed','stage_finished'])await sandbox(async directory=>{
  let fail=false,calls=0;const original=fs.fsyncSync;
  const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&!fail&&fs.readFileSync(fd,'utf8').includes('"type":"'+type+'"')){fail=true;throw Error('synthetic fsync');}return original(fd);});
  try{await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async(url,o)=>{calls++;return json(response(o.body));}}),/audit_required/);assert.equal(calls,type==='reserved'?0:type==='completed'?1:6);
   await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock}),/audit_required/);assert.equal(calls,type==='reserved'?0:type==='completed'?1:6);
   assert.equal(rows(directory).filter(r=>r.type==='failed').length,0);
  }finally{stub.mock.restore();}
 });
});
test('reservation delay crosses stage deadline before fetch',async t=>sandbox(async directory=>{
 let delayed=false,calls=0;const original=fs.fsyncSync;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&!delayed&&fs.readFileSync(fd,'utf8').includes('"type":"reserved"')){delayed=true;Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,25);}return original(fd);});
 try{await assert.rejects(runPairedPlannerStage({directory,apiKey:key,totalMs:10,fetchImpl:async()=>{calls++;return mock();}}),/audit_required/);assert.equal(calls,0);}finally{stub.mock.restore();}
}));
test('stalled headers/body and oversized body cancel without later dispatch',async()=>{
 for(const kind of ['headers','body','oversize'])await sandbox(async directory=>{
  let calls=0,cancelled=false;await assert.rejects(runPairedPlannerStage({directory,apiKey:key,timeoutMs:10,fetchImpl:async()=>{
   calls++;if(kind==='headers')await new Promise(r=>setTimeout(r,30));
   return new Response(new ReadableStream({start(c){if(kind==='oversize')c.enqueue(new Uint8Array(262145));},cancel(){cancelled=true;}}),{headers:{'content-type':'application/json'}});
  }}),/audit_required/);
  await new Promise(r=>setTimeout(r,35));assert.equal(calls,1);assert.equal(cancelled,true);
 });
});
test('notification failures never add a failed terminal or release an incomplete stage',async()=>sandbox(async directory=>{
 await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock,onProgress:()=>{throw Error('synthetic notification');}}),/audit_required/);
 assert.deepEqual(rows(directory).map(r=>r.type),['manifest','reserved','completed']);assert.equal(fs.existsSync(path.join(directory,'running.lock')),true);
}));
test('unknown options and widened limits cannot select more work',async()=>sandbox(async directory=>{
 for(const extra of [{stage:1},{body:'synthetic'},{timeoutMs:60001},{totalMs:360001},{apiKey:'bad key'}])await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock,...extra}),/audit_required/);
 assert.equal(fs.existsSync(directory),false);
}));


test('lock removal and close failures are fixed errors and prevent automatic resume',async t=>{
 for(const kind of ['release_sync','release_remove','close'])await sandbox(async directory=>{
  let failed=false,calls=0;const originalSync=fs.fsyncSync,originalRemove=fs.rmdirSync,originalClose=fs.closeSync;let stub;
  if(kind==='release_sync')stub=t.mock.method(fs,'fsyncSync',fd=>{
   if(!failed&&fs.fstatSync(fd).isDirectory()&&fs.existsSync(file(directory))&&!fs.existsSync(path.join(directory,'running.lock'))&&rows(directory).at(-1)?.type==='stage_finished'){failed=true;throw Error('synthetic cleanup');}return originalSync(fd);
  });
  if(kind==='release_remove')stub=t.mock.method(fs,'rmdirSync',p=>{if(!failed&&p===path.join(directory,'running.lock')){failed=true;throw Error('synthetic cleanup');}return originalRemove(p);});
  if(kind==='close')stub=t.mock.method(fs,'closeSync',fd=>{
   const terminal=!failed&&fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"stage_finished"');originalClose(fd);if(terminal){failed=true;throw Error('synthetic close');}
  });
  try{
   await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:async(url,o)=>{calls++;return json(response(o.body));}}),/^Error: paired_planner_stopped_audit_required$/);
   assert.equal(calls,6);assert.equal(fs.existsSync(path.join(directory,'running.lock')),true);
   await assert.rejects(runPairedPlannerStage({directory,apiKey:key,fetchImpl:mock}),/audit_required/);
  }finally{stub.mock.restore();}
 });
});

test('failed diagnostics retain only fixed category phase and HTTP status without upstream text',async()=>{
 for(const kind of ['http','validation','transport','body','timeout'])await sandbox(async directory=>{
  await assert.rejects(runPairedPlannerStage({directory,apiKey:key,timeoutMs:10,fetchImpl:async(url,o)=>{
   if(kind==='http')return new Response('synthetic upstream private text',{status:429});
   if(kind==='transport')throw Error('synthetic upstream '+key);
   if(kind==='body')return new Response(key,{headers:{'content-type':'application/json'}});
   if(kind==='timeout')return new Response(new ReadableStream({}),{headers:{'content-type':'application/json'}});
   const r=response(o.body);r.output[0].content[0].text='{}';return json(r);
  }}),/^Error: paired_planner_stopped_audit_required$/);
  const last=rows(directory).at(-1);assert.equal(last.type,'failed');
  const expected={http:['upstream_http',429,'body'],validation:['task_planner_invalid_plan',200,'validation'],transport:['transport_or_unknown',null,'fetch'],body:['response_body_failure',200,'body'],timeout:['timeout',200,'body']}[kind];
  assert.deepEqual([last.reason,last.httpStatus,last.phase],expected);
  assert.ok(!JSON.stringify(rows(directory)).includes(key));assert.ok(!JSON.stringify(rows(directory)).includes('upstream private'));
 });
});

test('candidate diagnostic sends fixed candidate once after reservation and never reopens any directory',async()=>sandbox(async directory=>{
 let calls=0;const result=await runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:async(url,o)=>{
  calls++;const reserved=rows(directory).at(-1);assert.equal(reserved.type,'reserved');assert.equal(reserved.variant,'candidate');assert.equal(reserved.index,0);assert.equal(reserved.reservedMicroUSD,8192);
  assert.equal(rows(directory)[0].manifest.jobs.length,1);return json(response(o.body));
 }});assert.equal(calls,1);assert.equal(result.done,true);assert.equal(result.reservedMicroUSD,8192);
 await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:mock}),/audit_required/);
}));
test('candidate diagnostic retains only mismatch category on failure without raw text and never retries',async()=>sandbox(async directory=>{
 let calls=0;await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:async(url,o)=>{
  calls++;const r=response(o.body),p=JSON.parse(r.output[0].content[0].text);p.tasks[0].attribute.text='synthetic_private_detail';r.output[0].content[0].text=JSON.stringify(p);return json(r);
 }}),/audit_required/);
 const last=rows(directory).at(-1);assert.equal(last.reason,'task_planner_invalid_plan');assert.deepEqual(last.diagnostic,{code:'span_quote_mismatch',role:'attribute',taskIndex:0,spanIndex:-1});
 assert.ok(!fs.readFileSync(file(directory),'utf8').includes('synthetic_private_detail'));assert.equal(calls,1);assert.ok(fs.existsSync(path.join(directory,'running.lock')));
 await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:mock}),/audit_required/);
}));
test('one-shot stops before dispatch on fsync failure and rejects preexisting empty directories',async t=>{
 await sandbox(async directory=>{fs.mkdirSync(directory,{mode:0o700});let calls=0;await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);});
 await sandbox(async directory=>{let calls=0;const original=fs.fsyncSync;const stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"reserved"'))throw Error('private');return original(fd);});
  try{await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,fetchImpl:async()=>{calls++;}}));assert.equal(calls,0);}finally{stub.mock.restore();}
 });
});
test('one-shot rejects selectors, secret reflection, stalled body and forged transport diagnostic without retry',async()=>{
 for(const kind of ['selector','secret','timeout','forged'])await sandbox(async directory=>{
  let calls=0;await assert.rejects(runPairedCandidateDiagnostic({directory,apiKey:key,timeoutMs:10,...(kind==='selector'?{index:1}:{}),fetchImpl:async(url,o)=>{
   calls++;if(kind==='forged')throw Object.assign(Error('task_planner_invalid_plan'),{taskPlanDiagnostic:{code:'span_bounds',role:'attribute',taskIndex:0,spanIndex:-1}});
   if(kind==='timeout')return new Response(new ReadableStream({}),{headers:{'content-type':'application/json'}});
   const r=response(o.body);r.extra=key;return json(r);
  }}));assert.equal(calls,kind==='selector'?0:1);
  if(calls){const last=rows(directory).at(-1);assert.equal(last.diagnostic,undefined);assert.ok(!fs.readFileSync(file(directory),'utf8').includes(key));}
 });
});
