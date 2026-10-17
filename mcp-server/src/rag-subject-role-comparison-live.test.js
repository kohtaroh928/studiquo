import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {performance} from 'node:perf_hooks';
import {runSubjectRoleComparisonStage as run} from '../scripts/rag-quality/subject-role-comparison-live.mjs';
import {openSubjectRoleComparisonLiveJournal as open} from '../scripts/rag-quality/subject-role-comparison-live-journal.mjs';
import {openSubjectRoleComparisonJournal as openOffline} from '../scripts/rag-quality/subject-role-comparison-journal.mjs';
import {subjectRoleComparisonLiveManifest as manifest} from '../scripts/rag-quality/subject-role-comparison-live-contract.mjs';
import {subjectRoleTaskPlannerRequest} from '../scripts/rag-quality/subject-role-task-planner-request.mjs';
import {rawResponse,mockFetch,syntheticKey as key,hash,mockBatch} from './test-support/rag-subject-role-comparison-live.mjs';
const error=e=>e.message==='subject_role_comparison_stopped_audit_required';
const file=d=>path.join(d,'journal.ndjson'),lock=d=>path.join(d,'running.lock');
const rows=d=>fs.readFileSync(file(d),'utf8').trimEnd().split('\n').map(JSON.parse);
async function sandbox(fn){const p=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'studiquo-comparison-live-')));try{await fn(path.join(p,'run'),p);}finally{fs.rmSync(p,{recursive:true,force:true});}}
function review(d,modes={}){const j=open(d),stage=j.status().stage;j.preparePackets();const c=JSON.parse(fs.readFileSync(path.join(d,'packets-stage-'+stage+'.json'),'utf8'));const s=j.recordReview(JSON.stringify(mockBatch(c,modes)));j.close();return s;}
test('explicit stage entry sends exactly 2/6/8/8 fixed bodies only after independent review checkpoints',async()=>sandbox(async d=>{
 const calls=[],progress=[],fetchImpl=mockFetch(calls);for(let stage=0;stage<4;stage++){
  const s=await run({directory:d,apiKey:key,fetchImpl,onProgress:p=>progress.push(p)});assert.equal(s.stage,stage);assert.equal(s.phase,'checkpoint');assert.equal(s.dispatches,[2,6,8,8][stage]);assert.equal(s.transportAttached,true);assert.equal(s.dispatchAuthorized,false);assert.equal(s.reviewRequired,true);assert.equal(s.generationComplete,stage===3);
  const again=await run({directory:d,apiKey:key,fetchImpl});assert.equal(again.dispatches,0);assert.equal(again.reviewRequired,true);assert.equal(calls.length,[2,8,16,24][stage]);review(d);
 }
 const done=await run({directory:d,apiKey:key,fetchImpl});assert.equal(done.dispatches,0);assert.equal(done.phase,'done');assert.equal(done.allReviewsComplete,true);assert.equal(done.reviewRequired,false);assert.equal(done.reservedMicroUSD,196608);assert.equal(done.releaseAccepted,false);
 const m=manifest();assert.equal(calls.length,24);for(const [i,c] of calls.entries()){assert.equal(c.url,'https://api.openai.com/v1/responses');assert.equal(c.options.method,'POST');assert.equal(c.options.redirect,'error');assert.equal(hash(c.options.body),m.jobs[i].requestHash);assert.equal(c.job.ordinal,i);assert.equal(c.options.headers.authorization,'Bearer '+key);assert.equal(c.options.signal.aborted,true);}for(const p of progress)assert.deepEqual(Object.keys(p),['ordinal','index','variant','completedRequests','stage']);assert.equal(fs.readFileSync(file(d),'utf8').includes(key),false);
}));
test('baseline definite mismatch allows next stage but candidate semantic failure prevents further sends',async()=>sandbox(async d=>{
 const calls=[],fetchImpl=mockFetch(calls);await run({directory:d,apiKey:key,fetchImpl});assert.equal(review(d,{baseline:'fail'}).stage,1);await run({directory:d,apiKey:key,fetchImpl});assert.equal(review(d,{candidate:'fail'}).finalDecision,'stop');await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,8);assert.ok(fs.existsSync(lock(d)));
}));
test('HTTP and thrown transport errors stop at first arm without retry or persisting raw details',async()=>{
 for(const kind of ['http','throw'])await sandbox(async d=>{const calls=[],fetchImpl=mockFetch(calls,()=>{if(kind==='throw')throw Error('private upstream detail');return new Response('private upstream detail',{status:429});});await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,1);const r=rows(d);assert.equal(r.filter(r=>r.type==='failed').length,1);assert.equal(r.at(-1).reason,kind==='http'?'upstream_http':'transport_or_unknown');assert.equal(fs.readFileSync(file(d),'utf8').includes('private upstream'),false);assert.ok(fs.existsSync(lock(d)));});
});
test('first successful arm followed by failure remains partial with no automatic compensation',async()=>sandbox(async d=>{
 const calls=[],fetchImpl=mockFetch(calls,job=>new Response(job.ordinal===0?JSON.stringify(rawResponse(job)):'private',{status:job.ordinal===0?200:500,headers:{'content-type':'application/json'}}));await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);const r=rows(d);assert.equal(calls.length,2);assert.equal(r.filter(r=>r.type==='completed').length,1);assert.equal(r.filter(r=>r.type==='reserved').length,2);assert.equal(r.at(-1).ordinal,1);await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,2);
}));
test('headers body stream byte size UTF8 content type and redirect errors are bounded and canceled',async()=>{
 for(const kind of ['type','length','bytes','utf8','redirect'])await sandbox(async d=>{let canceled=false;const calls=[],fetchImpl=mockFetch(calls,()=>{
  const stream=new ReadableStream({start(c){if(kind==='bytes')c.enqueue(new Uint8Array(262145));else if(kind==='utf8')c.enqueue(new Uint8Array([255]));else c.enqueue(new TextEncoder().encode('{}'));if(kind==='utf8')c.close();},cancel(){canceled=true;}});
  const response=new Response(stream,{headers:{'content-type':kind==='type'?'text/plain':'application/json',...(kind==='length'?{'content-length':'262145'}:{})}});if(kind==='redirect')Object.defineProperty(response,'redirected',{value:true});return response;
 });await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,1);assert.equal(rows(d).at(-1).reason,'response_body_failure');if(kind!=='utf8')assert.equal(canceled,true);});
});
test('incomplete refusal wrong model plan and malformed usage are validation failures not successes',async()=>{
 for(const kind of ['incomplete','refusal','model','plan','usage'])await sandbox(async d=>{const calls=[],fetchImpl=mockFetch(calls,job=>{const r=rawResponse(job);if(kind==='incomplete')r.status='incomplete';if(kind==='refusal')r.output[0].content=[{type:'refusal',refusal:'private'}];if(kind==='model')r.model='other';if(kind==='plan')r.output[0].content[0].text='private';if(kind==='usage')r.usage.total_tokens++;return new Response(JSON.stringify(r),{headers:{'content-type':'application/json'}});});await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(rows(d).filter(r=>r.type==='completed').length,0);assert.equal(rows(d).at(-1).phase,'validation');assert.equal(calls.length,1);});
});
test('request raw decoded and final two-level decoded secret reflections stop before completion',async()=>{
 await sandbox(async d=>{const calls=[];await assert.rejects(()=>run({directory:d,apiKey:'comparisonPermission',fetchImpl:mockFetch(calls)}),error);assert.equal(calls.length,0);assert.equal(fs.existsSync(d),false);});
 for(const kind of ['literal','unicode','property','nested'])await sandbox(async d=>{const escaped=[...key].map(c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0')).join('');const calls=[],fetchImpl=mockFetch(calls,job=>{const r=rawResponse(job);let raw;
  if(kind==='nested'){const plan=JSON.parse(r.output[0].content[0].text);plan.tasks[0].attribute.label='synthetic_marker';r.output[0].content[0].text=JSON.stringify(plan).replace('synthetic_marker',escaped);raw=JSON.stringify(r);}
  else if(kind==='property'){r[key]='synthetic';raw=JSON.stringify(r).replace(key,escaped);}else{r.note=kind==='literal'?key:'synthetic_marker';raw=JSON.stringify(r);if(kind==='unicode')raw=raw.replace('synthetic_marker',escaped);}
  return new Response(raw,{headers:{'content-type':'application/json'}});
 });await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,1);assert.equal(rows(d).filter(r=>r.type==='completed').length,0);assert.equal(rows(d).at(-1).reason,'unit_secret_guard_reflection');assert.equal(fs.readFileSync(file(d),'utf8').includes(key),false);});
});
test('header and body hangs abort at the request deadline without a second request',async()=>{
 for(const kind of ['header','body'])await sandbox(async d=>{const calls=[];let aborted=false,canceled=false;const fetchImpl=mockFetch(calls,(job,url,options)=>{options.signal.addEventListener('abort',()=>{aborted=true;});if(kind==='header')return new Promise(()=>{});return new Response(new ReadableStream({cancel(){canceled=true;}}),{headers:{'content-type':'application/json'}});});await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl,timeoutMs:20}),error);assert.equal(calls.length,1);assert.equal(aborted,true);if(kind==='body')assert.equal(canceled,true);assert.equal(rows(d).at(-1).reason,'timeout');});
});
test('reservation expiry sends nothing and save expiry creates no second terminal record',async t=>{
 for(const target of ['reserved','completed'])await sandbox(async d=>{const originalNow=performance.now.bind(performance),originalSync=fs.fsyncSync;let offset=0;const now=t.mock.method(performance,'now',()=>originalNow()+offset),sync=t.mock.method(fs,'fsyncSync',fd=>{const result=originalSync(fd);if(fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"'+target+'"'))offset=600000;return result;});const calls=[];
  try{await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);}finally{sync.mock.restore();now.mock.restore();}assert.equal(calls.length,target==='reserved'?0:1);assert.equal(rows(d).filter(r=>r.type==='failed').length,0);assert.ok(fs.existsSync(lock(d)));await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);
 });
});
test('deadline expiry after normal lock removal restores a stop marker before returning failure',async t=>sandbox(async d=>{
 const originalNow=performance.now.bind(performance),originalSync=fs.fsyncSync;let offset=0;const now=t.mock.method(performance,'now',()=>originalNow()+offset),sync=t.mock.method(fs,'fsyncSync',fd=>{const result=originalSync(fd);if(fs.fstatSync(fd).isDirectory()&&fs.existsSync(file(d))&&fs.readFileSync(file(d),'utf8').includes('"type":"stage_finished"')&&!fs.existsSync(lock(d)))offset=600000;return result;});const calls=[];
 try{await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);}finally{sync.mock.restore();now.mock.restore();}assert.equal(calls.length,2);assert.ok(fs.existsSync(lock(d)));await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);assert.equal(calls.length,2);
}));
test('save fsync uncertainty is not overwritten by a failed record or retried',async t=>sandbox(async d=>{
 const original=fs.fsyncSync,stub=t.mock.method(fs,'fsyncSync',fd=>{if(fs.fstatSync(fd).isFile()&&fs.readFileSync(fd,'utf8').includes('"type":"completed"'))throw Error('private disk');return original(fd);}),calls=[];
 try{await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);}finally{stub.mock.restore();}assert.equal(calls.length,1);assert.equal(rows(d).filter(r=>r.type==='failed').length,0);assert.ok(fs.existsSync(lock(d)));
}));
test('offline suites and changed prior artifacts cannot reach fetch',async()=>{
 await sandbox(async d=>{const j=openOffline(d);j.close();const calls=[];await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);assert.equal(calls.length,0);});
 await sandbox(async d=>{const calls=[],fetchImpl=mockFetch(calls);await run({directory:d,apiKey:key,fetchImpl});review(d);fs.appendFileSync(path.join(d,'review-stage-0.json'),' ');await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl}),error);assert.equal(calls.length,2);});
});
test('limits only shorten and endpoint body model or journal overrides never reach transport',async()=>{
 for(const extra of [{timeoutMs:60001},{timeoutMs:0},{totalMs:480001},{totalMs:120001},{endpoint:'private'},{model:'other'},{body:{}},{directoryOverride:'private'}])await sandbox(async d=>{const calls=[];await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls),...extra}),error);assert.equal(calls.length,0);});
});
test('progress callbacks cannot log raw results and rejected async callbacks cause a fixed stop',async()=>{
 for(const kind of ['throw','async'])await sandbox(async d=>{const calls=[];const onProgress=kind==='throw'?()=>{throw Error('private callback');}:()=>Promise.reject(Error('private async callback'));await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls),onProgress}),error);assert.equal(calls.length,1);assert.ok(fs.existsSync(lock(d)));});
});
test('synchronous pre-dispatch secret validation expiry prevents fetch before incrementing dispatches',async t=>sandbox(async d=>{
 const body=JSON.stringify(subjectRoleTaskPlannerRequest(0,'baseline')),originalParse=JSON.parse,originalNow=performance.now.bind(performance);let offset=0,injected=false;
 const now=t.mock.method(performance,'now',()=>originalNow()+offset),parse=t.mock.method(JSON,'parse',(text,...args)=>{
  if(!injected&&text===body&&fs.existsSync(file(d))&&fs.readFileSync(file(d),'utf8').includes('"type":"reserved"')){injected=true;offset=600000;}
  return originalParse(text,...args);
 });const calls=[];
 try{await assert.rejects(()=>run({directory:d,apiKey:key,fetchImpl:mockFetch(calls)}),error);}finally{parse.mock.restore();now.mock.restore();}
 assert.equal(injected,true);assert.equal(calls.length,0);assert.equal(rows(d).filter(r=>r.type==='reserved').length,1);assert.equal(rows(d).at(-1).reason,'timeout');assert.ok(fs.existsSync(lock(d)));
}));
