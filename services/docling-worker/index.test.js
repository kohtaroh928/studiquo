import assert from 'node:assert/strict';
import test from 'node:test';
import { register } from 'node:module';
register('data:text/javascript,' + encodeURIComponent(`
export function resolve(s,c,n){if(s==='cloudflare:workers')return{url:'cloudflare-shim:',shortCircuit:true};return n(s,c);}
export function load(u,c,n){if(u==='cloudflare-shim:')return{format:'module',shortCircuit:true,source:'export class DurableObject {constructor(ctx,env){this.ctx=ctx;this.env=env;}}; export class WorkerEntrypoint {constructor(ctx,env){this.ctx=ctx;this.env=env;}}'};return n(u,c);}
`), import.meta.url);
const { DoclingJob, DoclingProcessor, validateManifest } = await import('./index.js');
const ID = '12345678-1234-4123-8123-123456789abc';
const PDF = new TextEncoder().encode('%PDF-synthetic-only');
const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', PDF)), b => b.toString(16).padStart(2,'0')).join('');
function manifest() {return {version:1,integration:'prepared_only_no_upload',batches:[{structure:{version:1,documentNamespace:'a'.repeat(64),document:{pdfSha256:digest}},totalPages:1,pages:[{pageNumber:1,text:'synthetic',structured:{version:1,records:[{text:'synthetic',metadata:{}}]}}]}]};}
let gateEscapes = 0;
test.afterEach(() => { assert.equal(gateEscapes, 0, 'no gate callback may throw/reset the DO'); });
const json = value => new Response(JSON.stringify(value), {headers:{'Content-Type':'application/json'}});
function deferred() {let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}
function fixture(options={}) {
  const stored=new Map(), calls=[], writes=[], monitor=deferred(); let alarm, lock=Promise.resolve();
  const storage={async get(k){return structuredClone(stored.get(k));},async put(k,v){writes.push(structuredClone(v));stored.set(k,structuredClone(v));},async setAlarm(v){if(options.alarmFail)throw Error('private-alarm');alarm=v;},async deleteAlarm(){alarm=undefined;}};
  const container={start(value){calls.push(['start',value]);if(options.startFail)throw Error('private-start');},monitor(){return monitor.promise;},getTcpPort(port){assert.equal(port,8080);return {fetch:async(url,init)=>{calls.push(['fetch',url,init]);if(url.endsWith('/ready'))return options.ready ? options.ready() : new Response(null,{status:204});return options.parse ? options.parse() : json(manifest());}};},async destroy(){calls.push(['destroy']);if(options.destroyFail)throw Error('private-destroy');monitor.resolve();}};
  const ctx={storage,container,waitUntil(p){p.catch(()=>{});},blockConcurrencyWhile(fn){const next=lock.then(async()=>{try{return await fn();}catch{gateEscapes++;assert.fail('blockConcurrencyWhile callback escaped and would reset DO');}});lock=next.catch(()=>{});return next;}};
  const job=new DoclingJob(ctx,{DOCLING_EXECUTION_ENABLED:'true'});
  return {job,ctx,stored,calls,writes,monitor,get alarm(){return alarm;}};
}
test('success uses default offline start, readiness then exactly one PDF POST and destroys before returning',async()=>{
 const f=fixture();assert.deepEqual(await f.job.parse(ID,PDF),manifest());
 assert.deepEqual(f.calls[0],['start',{enableInternet:false}]);
 const requests=f.calls.filter(v=>v[0]==='fetch'); assert.equal(requests.length,2);
 assert.equal(requests[0][1],'http://127.0.0.1:8080/ready');assert.equal(requests[0][2].body,undefined);
 assert.equal(requests[1][2].headers['Content-Length'],String(PDF.length));assert.equal(requests[1][2].headers['Content-Type'],'application/pdf');
 assert.deepEqual(f.calls.at(-1),['destroy']);assert.equal(f.stored.get('job').status,'completed');assert.equal(f.alarm,undefined);
 assert.equal(JSON.stringify(f.writes).includes('synthetic'),false);assert.equal(JSON.stringify(f.writes).includes(digest),false);
 await assert.rejects(f.job.parse(ID,PDF),/^Error: processing_failed$/);
});
test('public HTTP is 404 and flag disabled never dispatches; cancel still dispatches',async()=>{
 let calls=0;const stub={parse(){calls++;},cancel(){calls++;return {cancelled:true};}};
 const entry=new DoclingProcessor({}, {DOCLING_JOBS:{idFromName:x=>x,get:()=>stub}});
 assert.equal((await entry.fetch()).status,404);await assert.rejects(entry.parse(ID,PDF),/execution_disabled/);assert.equal(calls,0);
 assert.deepEqual(await entry.cancel(ID),{cancelled:true});assert.equal(calls,1);assert.equal((await fixture().job.fetch()).status,404);
});
test('input requires bounded bytes, PDF magic and canonical UUIDv4',async()=>{
 const f=fixture();for(const [id,bytes] of [['bad',PDF],[ID,new Uint8Array(11*1024*1024)],[ID,new TextEncoder().encode('other')],[ID,'PDF']])await assert.rejects(f.job.parse(id,bytes),/processing_failed/);
 assert.equal(f.calls.length,0);assert.equal(f.writes.length,0);
});
test('early cancellation is a persistent one-use tombstone across restart',async()=>{
 const f=fixture();await f.job.cancel(ID);const restarted=new DoclingJob(f.ctx,{DOCLING_EXECUTION_ENABLED:'true'});await assert.rejects(restarted.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.some(c=>c[0]==='start'),false);
});
test('duplicate parse cannot start a second job while first is active',async()=>{
 const waiting=deferred();const f=fixture({parse:()=>waiting.promise});const first=f.job.parse(ID,PDF);await new Promise(r=>setTimeout(r,10));await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);waiting.resolve(json(manifest()));await first;assert.equal(f.calls.filter(c=>c[0]==='start').length,1);
});
test('explicit cancel runs during POST and discards late response',async()=>{
 const waiting=deferred(),f=fixture({parse:()=>waiting.promise});const first=f.job.parse(ID,PDF);const rejection=assert.rejects(first,/processing_failed/);await new Promise(r=>setTimeout(r,10));await f.job.cancel(ID);waiting.resolve(json(manifest()));await rejection;assert.equal(f.stored.get('job').status,'cancelled');
});
test('deadline alarm interrupts POST, destroys and prevents late result',async()=>{
 const waiting=deferred(),f=fixture({parse:()=>waiting.promise});const first=f.job.parse(ID,PDF);const rejection=assert.rejects(first,/processing_failed/);await new Promise(r=>setTimeout(r,10));f.job.now=()=>f.stored.get('job').deadline;await f.job.alarm();waiting.resolve(json(manifest()));await rejection;assert.equal(f.stored.get('job').status,'expired');
});
test('start failure and monitor rejection fail closed without revealing raw errors',async()=>{
 for(const options of [{startFail:true},{parse:()=>new Promise(()=>{})}]){const f=fixture(options);const pending=f.job.parse(ID,PDF);const rejected=assert.rejects(pending,/^Error: processing_failed$/);if(!options.startFail){await new Promise(r=>setTimeout(r,10));f.monitor.reject(Error('private-native-body'));}await rejected;assert.ok(f.calls.some(c=>c[0]==='destroy'));}
});
test('alarm persistence failure never starts the container',async()=>{const f=fixture({alarmFail:true});await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.some(c=>c[0]==='start'),false);assert.ok(f.calls.some(c=>c[0]==='destroy'));assert.equal(f.stored.get('job').status,'poisoned');});
test('wrong digest, incomplete pages, malformed JSON and oversized output are rejected and destroyed',async()=>{
 const wrong=manifest();wrong.batches[0].structure.document.pdfSha256='b'.repeat(64);const missing=manifest();missing.batches[0].totalPages=2;
 for(const response of [json(wrong),json(missing),new Response('{',{headers:{'Content-Type':'application/json'}}),new Response('x',{headers:{'Content-Type':'application/json','Content-Length':String(4*1024*1024+1)}}),new Response('x'.repeat(4*1024*1024+1),{headers:{'Content-Type':'application/json'}})]){const f=fixture({parse:()=>response});await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.ok(f.calls.some(c=>c[0]==='destroy'));}
});
test('destroy failure poisons persistently, bounded alarm cleanup retries and restart cannot parse',async()=>{
 const f=fixture({destroyFail:true});await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.stored.get('job').status,'poisoned');assert.equal(f.stored.get('job').cleanupAttempts,1);
 for(let i=0;i<3;i++)await f.job.alarm();assert.equal(f.stored.get('job').cleanupAttempts,4);
 const restarted=new DoclingJob(f.ctx,{DOCLING_EXECUTION_ENABLED:'true'});await assert.rejects(restarted.parse(ID,PDF),/processing_failed/);
});
test('restart of interrupted active job persists poison and schedules cleanup',async()=>{
 const f=fixture();f.stored.set('job',{jobId:ID,status:'running',deadline:Date.now()+10000,cleanupAttempts:0});const restarted=new DoclingJob(f.ctx,{DOCLING_EXECUTION_ENABLED:'true'});await restarted.ready;assert.equal(f.stored.get('job').status,'poisoned');assert.ok(f.alarm);await assert.rejects(restarted.parse(ID,PDF),/processing_failed/);await restarted.alarm();assert.ok(f.calls.some(c=>c[0]==='destroy'));
});
test('manifest boundary requires canonical complete pages and common document across batches',()=>{
 const x=manifest();x.batches[0].pages[0].pageNumber=2;assert.throws(()=>validateManifest(x,digest),/output_invalid/);
 const y=manifest();y.batches.push(structuredClone(y.batches[0]));assert.throws(()=>validateManifest(y,digest),/output_invalid/);
});
test('startup readiness timeout never submits PDF and destroys',async()=>{
 const f=fixture({ready:()=>new Response(null,{status:503})});let clock=0;f.job.now=()=>clock;const original=f.ctx.container.getTcpPort;f.ctx.container.getTcpPort=p=>{const port=original(p);return {fetch:async(...args)=>{clock+=31000;return port.fetch(...args);}};};
 await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.filter(c=>c[0]==='fetch'&&c[2].method==='POST').length,0);assert.ok(f.calls.some(c=>c[0]==='destroy'));
});
test('invalid UTF8, response status and redirect are rejected without second POST',async()=>{
 for(const response of [new Response(new Uint8Array([0xff]),{headers:{'Content-Type':'application/json'}}),new Response(null,{status:302,headers:{Location:'https://example.invalid'}}),new Response('private-native-error',{status:500})]){const f=fixture({parse:()=>response});await assert.rejects(f.job.parse(ID,PDF),/^Error: processing_failed$/);assert.equal(f.calls.filter(c=>c[0]==='fetch'&&c[2].method==='POST').length,1);assert.equal(JSON.stringify(f.writes).includes('private'),false);}
});
test('PDF input is snapshotted before asynchronous claim',async()=>{
 const f=fixture();const bytes=new Uint8Array(PDF);const pending=f.job.parse(ID,bytes);bytes.fill(0);await pending;const post=f.calls.find(c=>c[0]==='fetch'&&c[2].method==='POST');assert.deepEqual(post[2].body,PDF);
});
test('destroy timeout with an unresolved native operation poisons and never returns result',async()=>{
 const f=fixture();f.ctx.container.destroy=()=>new Promise(()=>{});const limited=f.job.limited.bind(f.job);f.job.limited=(work,ms,signal)=>ms===10000?Promise.reject(Error('fixed-timeout')):limited(work,ms,signal);
 await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.stored.get('job').status,'poisoned');assert.equal(f.stored.get('job').cleanupAttempts,1);assert.ok(f.alarm);
});
test('DO disabled parse never starts; cancel is allowed even when disabled',async()=>{
 const f=fixture();f.job.env.DOCLING_EXECUTION_ENABLED='false';await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.length,0);await f.job.cancel(ID);assert.equal(f.stored.get('job').status,'cancelled');
});
test('post-claim state persistence faults cannot bypass destroy or return success',async()=>{
 for(const operation of ['get','put','setAlarm','deleteAlarm']) {
  const f=fixture({parse:()=>{if(operation==='get'||operation==='put')f.ctx.storage[operation]=async()=>{throw Error('private-storage-body');};return json(manifest());}});
  await f.job.ready;
  if(operation==='setAlarm'||operation==='deleteAlarm')f.ctx.storage[operation]=async()=>{throw Error('private-storage-body');};
  await assert.rejects(f.job.parse(ID,PDF),/^Error: processing_failed$/);
  assert.ok(f.calls.some(c=>c[0]==='destroy'),operation);assert.notEqual(f.stored.get('job')?.status,'completed');
 }
});
test('constructor read failure still permits best effort teardown from parse, cancel and alarm',async()=>{
 for(const operation of ['parse','cancel','alarm']) {
  const f=fixture();f.ctx.storage.get=async()=>{throw Error('private-storage-path');};
  if(operation==='alarm')await f.job.alarm();else await assert.rejects(operation==='parse'?f.job.parse(ID,PDF):f.job.cancel(ID),/^Error: (processing_failed|cleanup_failed)$/);
  assert.ok(f.calls.some(c=>c[0]==='destroy'),operation);assert.equal(f.job.stopping,true);
 }
});
test('cancel storage faults always destroy, reject cancellation success and invalidate in memory',async()=>{
 for(const operation of ['get','put','setAlarm','deleteAlarm']) {
  const f=fixture();await f.job.ready;f.ctx.storage[operation]=async()=>{throw Error('private-storage-path');};
  await assert.rejects(f.job.cancel(ID),/^Error: cleanup_failed$/);assert.ok(f.calls.some(c=>c[0]==='destroy'),operation);assert.equal(f.job.stopping,true);
 }
});
test('alarm storage faults always try destroy and invalidate in memory',async()=>{
 for(const operation of ['get','put','setAlarm','deleteAlarm']) {
  const f=fixture();await f.job.ready;f.stored.set('job',{jobId:ID,status:'running',deadline:operation==='setAlarm'?Date.now()+10000:0,cleanupAttempts:0});
  f.ctx.storage[operation]=async()=>{throw Error('private-storage-path');};await f.job.alarm();assert.ok(f.calls.some(c=>c[0]==='destroy'),operation);assert.equal(f.job.stopping,true);
 }
});
test('cancellation after claim before start never starts container',async()=>{
 const f=fixture();const claim=f.job.claim.bind(f.job);f.job.claim=async id=>{const state=await claim(id);await f.job.cancel(id);return state;};await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.some(c=>c[0]==='start'),false);
});
test('deadline alarm after claim before start never starts container',async()=>{
 const f=fixture();const claim=f.job.claim.bind(f.job);f.job.claim=async id=>{const state=await claim(id);f.job.now=()=>state.deadline;await f.job.alarm();return state;};await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.equal(f.calls.some(c=>c[0]==='start'),false);
});
test('known mismatched cancel identity never destroys or interrupts active job',async()=>{
 const waiting=deferred(),f=fixture({parse:()=>waiting.promise});const first=f.job.parse(ID,PDF);await new Promise(r=>setTimeout(r,10));await assert.rejects(f.job.cancel('12345678-1234-4123-8123-123456789abd'),/cleanup_failed/);assert.equal(f.calls.some(c=>c[0]==='destroy'),false);waiting.resolve(json(manifest()));await first;
});
test('claim read/write faults and interrupted-constructor recovery faults still attempt teardown',async()=>{
 for(const operation of ['get','put']) {
  const f=fixture();await f.job.ready;f.ctx.storage[operation]=async()=>{throw Error('private-storage-path');};await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);assert.ok(f.calls.some(c=>c[0]==='destroy'));assert.equal(f.calls.some(c=>c[0]==='start'),false);
 }
 for(const operation of ['put','setAlarm']) {
  const f=fixture();f.stored.set('job',{jobId:ID,status:'running',deadline:0,cleanupAttempts:0});f.ctx.storage[operation]=async()=>{throw Error('private-storage-path');};await f.job.alarm();assert.ok(f.calls.some(c=>c[0]==='destroy'));assert.equal(f.job.stopping,true);
 }
});
test('monitor failure still destroys when marking stopped fails in storage',async()=>{
 const f=fixture({parse:()=>new Promise(()=>{})});const pending=f.job.parse(ID,PDF);const rejected=assert.rejects(pending,/^Error: processing_failed$/);await new Promise(r=>setTimeout(r,10));f.ctx.storage.put=async()=>{throw Error('private-storage-path');};f.monitor.reject(Error('private-native-body'));await rejected;assert.ok(f.calls.some(c=>c[0]==='destroy'));assert.equal(f.job.stopping,true);
});
test('public and disabled entrances handle rejected constructor initialization without concealing it from cancellation',async()=>{
 // node:test treats any unhandled rejection as a failure; no process-wide handler
 // is installed. Deliberately leave ready unawaited across two event-loop turns.
 for(const entrance of ['fetch','disabled']) {
  const f=fixture();f.ctx.storage.get=async()=>{throw Error('private-storage-path');};
  if(entrance==='fetch')assert.equal((await f.job.fetch()).status,404);
  else {f.job.env.DOCLING_EXECUTION_ENABLED='false';await assert.rejects(f.job.parse(ID,PDF),/processing_failed/);}
  await new Promise(r=>setImmediate(r));await new Promise(r=>setImmediate(r));
  await assert.rejects(f.job.ready,/processing_failed/);
  await assert.rejects(f.job.cancel(ID),/cleanup_failed/);
  assert.ok(f.calls.some(c=>c[0]==='destroy'));
 }
});
