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
  const storage={async get(k){return structuredClone(stored.get(k));},async put(k,v){if(options.confirmationWriteFail&&v.destroyConfirmedAt!==undefined)throw Error('private-write');writes.push(structuredClone(v));stored.set(k,structuredClone(v));},async setAlarm(v){if(options.alarmFail)throw Error('private-alarm');alarm=v;},async deleteAlarm(){if(options.deleteAlarmFail)throw Error('private-alarm-delete');alarm=undefined;}};
  const container={start(value){calls.push(['start',value]);if(options.startFail)throw Error('private-start');},monitor(){return monitor.promise;},getTcpPort(port){assert.equal(port,8080);return {fetch:async(url,init)=>{calls.push(['fetch',url,init]);if(url.endsWith('/ready'))return options.ready ? options.ready() : new Response(null,{status:204});return options.parse ? options.parse() : json(manifest());}};},async destroy(){calls.push(['destroy']);if(options.destroyFail)throw Error('private-destroy');monitor.resolve();}};
  const ctx={storage,container,waitUntil(p){p.catch(()=>{});},blockConcurrencyWhile(fn){const next=lock.then(async()=>{try{return await fn();}catch{gateEscapes++;assert.fail('blockConcurrencyWhile callback escaped and would reset DO');}});lock=next.catch(()=>{});return next;}};
  const job=new DoclingJob(ctx,{DOCLING_EXECUTION_ENABLED:'true',DOCLING_RPC_V2_ONLY:'true'});
  return {job,ctx,stored,calls,writes,monitor,get alarm(){return alarm;}};
}

const contract=(more={})=>({version:2,jobId:ID,pdfSha256:digest,notAfter:Date.now()+60000,...more});
const stop=c=>({version:2,jobId:c.jobId,notAfter:c.notAfter});

test('v2 destroy confirmation is stored only after VM destroy resolves and is fixed on repeated cancellation',async()=>{
 const f=fixture(),c=contract();await f.job.parseV2(c,PDF);const first=f.stored.get('job').destroyConfirmedAt;
 assert.ok(Number.isSafeInteger(first));assert.equal(f.stored.get('job').status,'completed');
 f.job.now=()=>first+1;await f.job.cancelV2(stop(c));assert.equal(f.stored.get('job').destroyConfirmedAt,first);
 assert.equal(f.stored.get('job').notAfter,c.notAfter);assert.equal(f.alarm,undefined);
});

test('pending VM destroy never records confirmation or acknowledges cancellation',async()=>{
 const f=fixture(),c=contract(),entered=deferred(),finish=deferred();
 f.ctx.container.destroy=async()=>{entered.resolve();await finish.promise;};
 const active=f.job.cancelV2(stop(c));await entered.promise;
 assert.equal(f.stored.get('job').destroyConfirmedAt,undefined);
 finish.resolve();assert.deepEqual(await active,{cancelled:true});assert.ok(f.stored.get('job').destroyConfirmedAt);
});

test('failed durable confirmation keeps the job poisoned, held and retryable despite actual VM stop',async()=>{
 const options={confirmationWriteFail:true},f=fixture(options),c=contract();
 await assert.rejects(()=>f.job.cancelV2(stop(c)),/^Error: cleanup_failed$/u);
 assert.ok(f.calls.some(x=>x[0]==='destroy'));assert.equal(f.stored.get('job').destroyConfirmedAt,undefined);
 assert.equal(f.stored.get('job').status,'poisoned');assert.ok(f.alarm);
 options.confirmationWriteFail=false;await f.job.cancelV2(stop(c));assert.ok(f.stored.get('job').destroyConfirmedAt);
});

test('destroy failure never invents confirmation and does not erase the immutable earlier observation',async()=>{
 const options={},f=fixture(options),c=contract();await f.job.cancelV2(stop(c));const first=f.stored.get('job').destroyConfirmedAt;
 options.destroyFail=true;await assert.rejects(()=>f.job.cancelV2(stop(c)));
 assert.equal(f.stored.get('job').status,'poisoned');assert.equal(f.stored.get('job').destroyConfirmedAt,first);
 // A historical observation is not current cleanup success; a fresh ack failed.
 assert.ok(f.alarm);assert.equal(f.stored.get('job').notAfter,c.notAfter);
});

test('alarm failure after confirmation rejects ack and retains poison and the original stop observation',async()=>{
 const options={deleteAlarmFail:true},f=fixture(options),c=contract();
 await assert.rejects(()=>f.job.cancelV2(stop(c)));const first=f.stored.get('job').destroyConfirmedAt;
 assert.ok(first);assert.equal(f.stored.get('job').status,'poisoned');
 options.deleteAlarmFail=false;await f.job.cancelV2(stop(c));assert.equal(f.stored.get('job').destroyConfirmedAt,first);
});

test('clock rollback and invalid time cannot authorize a new successful ack or replace the saved observation',async()=>{
 for(const time of [NaN,-1,Number.MAX_SAFE_INTEGER+1]){
  const f=fixture(),c=contract();f.job.now=()=>time;await assert.rejects(()=>f.job.cancelV2(stop(c)));
  assert.equal(f.stored.get('job')?.destroyConfirmedAt,undefined);
 }
 const f=fixture(),c=contract();await f.job.cancelV2(stop(c));const first=f.stored.get('job').destroyConfirmedAt;
 f.job.now=()=>first-1;await assert.rejects(()=>f.job.cancelV2(stop(c)));
 assert.equal(f.stored.get('job').destroyConfirmedAt,first);assert.equal(f.stored.get('job').status,'poisoned');
});

test('restart and delayed cleanup alarm preserve fixed deadline and the first observation without purging',async()=>{
 const f=fixture(),c=contract();await f.job.cancelV2(stop(c));const first=f.stored.get('job').destroyConfirmedAt;
 const restart=new DoclingJob(f.ctx,{DOCLING_EXECUTION_ENABLED:'false',DOCLING_RPC_V2_ONLY:'true'});await restart.ready;
 restart.now=()=>c.notAfter+1000;await restart.alarm();const saved=f.stored.get('job');
 assert.equal(saved.notAfter,c.notAfter);assert.equal(saved.destroyConfirmedAt,first);assert.ok(saved.jobId);
 await assert.rejects(()=>restart.parseV2(c,PDF));
});

test('expired empty v2 cancellation and legacy cleanup do not create or backfill confirmation records',async()=>{
 const f=fixture(),c=contract({notAfter:Date.now()-1000});await f.job.cancelV2(stop(c));assert.equal(f.stored.size,0);
 f.stored.set('job',{jobId:ID,status:'cancelled',deadline:Date.now(),cleanupAttempts:0});
 await f.job.cancelV2(stop(c));assert.equal(f.stored.get('job').destroyConfirmedAt,undefined);
 assert.equal(f.stored.get('job').rpcVersion,undefined);assert.equal(f.stored.get('job').notAfter,undefined);
});

test('late destroy completion after timeout cannot create durable confirmation or erase retry alarm',async()=>{
 const f=fixture(),c=contract(),finish=deferred();f.ctx.container.destroy=()=>finish.promise;
 const limited=f.job.limited.bind(f.job);f.job.limited=(fn,ms,signal)=>limited(fn,Math.min(ms,5),signal);
 await assert.rejects(()=>f.job.cancelV2(stop(c)));assert.equal(f.stored.get('job').destroyConfirmedAt,undefined);
 const alarm=f.alarm;finish.resolve();await new Promise(r=>setTimeout(r,10));
 assert.equal(f.stored.get('job').destroyConfirmedAt,undefined);assert.equal(f.alarm,alarm);
});

test('retained marker rejects replay after clock rollback; an artificial full erase demonstrates why physical purge stays out',async()=>{
 const f=fixture(),c=contract(),before=Date.now();await f.job.cancelV2(stop(c));
 f.job.now=()=>c.notAfter+1000;await f.job.alarm();assert.ok(f.stored.get('job'));
 const env={DOCLING_EXECUTION_ENABLED:'true',DOCLING_RPC_V2_ONLY:'true'};
 const retained=new DoclingJob(f.ctx,env);retained.now=()=>before+1;
 await assert.rejects(()=>retained.parseV2(c,PDF));assert.equal(f.calls.some(x=>x[0]==='start'),false);
 // Counterexample ONLY: erase the in-memory test fixture, never real storage.
 // Once the clock also rolls back, no local fence remains to identify replay.
 f.stored.clear();const erased=new DoclingJob(f.ctx,env);erased.now=()=>before+2;
 assert.deepEqual(await erased.parseV2(c,PDF),manifest());assert.ok(f.calls.some(x=>x[0]==='start'));
});
