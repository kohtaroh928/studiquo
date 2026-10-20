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
  const job=new DoclingJob(ctx,{DOCLING_EXECUTION_ENABLED:'true',DOCLING_RPC_V2_ONLY:'true'});
  return {job,ctx,stored,calls,writes,monitor,get alarm(){return alarm;}};
}

const contract=(more={})=>({version:2,jobId:ID,pdfSha256:digest,notAfter:Date.now()+60000,...more});
const stop=c=>({version:2,jobId:c.jobId,notAfter:c.notAfter});

test('v2 success fixes deadline in durable state, never stores PDF or its digest and prevents replay',async()=>{
 const f=fixture(),c=contract();assert.deepEqual(await f.job.parseV2(c,PDF),manifest());
 assert.equal(f.stored.get('job').notAfter,c.notAfter);assert.equal(f.stored.get('job').rpcVersion,2);
 assert.equal(f.stored.get('job').deadline,c.notAfter);assert.equal(f.stored.get('job').status,'completed');
 assert.equal(JSON.stringify(f.writes).includes(digest),false);
 await assert.rejects(f.job.parseV2({...c,notAfter:c.notAfter+1},PDF),/processing_failed/u);
 assert.equal(f.calls.filter(c=>c[0]==='start').length,1);
});

test('v2-only rejects legacy signatures at entrypoint and DO, including old helper entrances',async()=>{
 const f=fixture();for(const call of [()=>f.job.parse(ID,PDF),()=>f.job.cancel(ID),()=>f.job.execute(ID,PDF),()=>f.job.claim(ID),()=>f.job.cancelJob(ID)])
  await assert.rejects(call);assert.equal(f.calls.length,0);assert.equal(f.stored.size,0);
 let calls=0;const entry=new DoclingProcessor({}, {DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true',
  DOCLING_JOBS:{idFromName:x=>x,get:()=>({parse(){calls++;},cancel(){calls++;}})}});
 await assert.rejects(entry.parse(ID,PDF),/rpc_upgrade_required/u);await assert.rejects(entry.cancel(ID),/rpc_upgrade_required/u);assert.equal(calls,0);
});

test('strict envelope and actual bytes digest reject before claim or VM start',async()=>{
 const fixed=Date.now();for(const c of [null,{},contract({extra:1}),contract({version:1}),contract({notAfter:0}),contract({notAfter:'1'}),
  contract({notAfter:fixed-1}),contract({notAfter:fixed+180001}),contract({jobId:'bad'}),contract({pdfSha256:'b'.repeat(64)})]){
  const f=fixture();f.job.now=()=>fixed;await assert.rejects(f.job.parseV2(c,PDF),/processing_failed/u);
  assert.equal(f.calls.length,0);assert.equal(f.stored.size,0);
 }
});

test('cancel-before-parse fixes the original deadline, survives restart and cannot be extended',async()=>{
 const f=fixture(),c=contract();await f.job.cancelV2(stop(c));const state=structuredClone(f.stored.get('job'));
 await assert.rejects(f.job.cancelV2({...stop(c),notAfter:c.notAfter+1}),/cleanup_failed/u);
 assert.deepEqual(f.stored.get('job'),state);
 const restarted=new DoclingJob(f.ctx,{DOCLING_EXECUTION_ENABLED:'true',DOCLING_RPC_V2_ONLY:'true'});
 await assert.rejects(restarted.parseV2(c,PDF),/processing_failed/u);assert.equal(f.calls.some(c=>c[0]==='start'),false);
 assert.equal(f.stored.get('job').notAfter,c.notAfter);
});

test('mismatched deadline cannot interrupt a running job',async()=>{
 const waiting=deferred(),f=fixture({parse:()=>waiting.promise}),c=contract();const active=f.job.parseV2(c,PDF);
 while(!f.calls.some(x=>x[0]==='fetch'&&x[2].method==='POST'))await new Promise(r=>setTimeout(r,1));
 await assert.rejects(f.job.cancelV2({...stop(c),notAfter:c.notAfter+1}),/cleanup_failed/u);
 assert.equal(f.calls.some(x=>x[0]==='destroy'),false);waiting.resolve(json(manifest()));await active;
});

test('expiry forbids results but permits existing cancellation with execution disabled',async()=>{
 const waiting=deferred(),f=fixture({parse:()=>waiting.promise}),c=contract();const active=f.job.parseV2(c,PDF),rejected=assert.rejects(active,/processing_failed/u);
 while(!f.calls.some(x=>x[0]==='fetch'&&x[2].method==='POST'))await new Promise(r=>setTimeout(r,1));
 f.job.now=()=>c.notAfter;f.job.env.DOCLING_EXECUTION_ENABLED='false';
 assert.deepEqual(await f.job.cancelV2(stop(c)),{cancelled:true});waiting.resolve(json(manifest()));await rejected;
 assert.equal(f.stored.get('job').notAfter,c.notAfter);assert.notEqual(f.stored.get('job').status,'completed');
});

test('expired empty cancellation destroys before ack, adds no marker and expired parse stays rejected',async()=>{
 const f=fixture(),c=contract({notAfter:Date.now()-1000});
 assert.deepEqual(await f.job.cancelV2(stop(c)),{cancelled:true});assert.equal(f.stored.size,0);assert.equal(f.writes.length,0);
 assert.ok(f.calls.some(x=>x[0]==='destroy'));
 const restart=new DoclingJob(f.ctx,{DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true'});
 await assert.rejects(restart.parseV2(c,PDF),/processing_failed/u);assert.equal(f.stored.size,0);
});

test('empty storage never substitutes for confirmed VM destruction',async()=>{
 const f=fixture({destroyFail:true}),c=contract({notAfter:Date.now()-1000});
 await assert.rejects(f.job.cancelV2(stop(c)),/^Error: cleanup_failed$/u);assert.equal(f.stored.size,0);
 assert.ok(f.calls.some(x=>x[0]==='destroy'));
});

test('expiry is rechecked inside claim before container start and again before result',async()=>{
 const a=fixture(),c=contract(),claim=a.job.claim.bind(a.job);a.job.claim=async(...args)=>{a.job.now=()=>c.notAfter;return claim(...args);};
 await assert.rejects(a.job.parseV2(c,PDF),/processing_failed/u);assert.equal(a.calls.some(x=>x[0]==='start'),false);
 const b=fixture({parse:()=>{b.job.now=()=>d.notAfter;return json(manifest());}}),d=contract();
 await assert.rejects(b.job.parseV2(d,PDF),/processing_failed/u);assert.notEqual(b.stored.get('job').status,'completed');
});

test('input envelope and bytes are snapshotted before async initialization',async()=>{
 const f=fixture(),c=contract(),expiry=c.notAfter,bytes=new Uint8Array(PDF);const active=f.job.parseV2(c,bytes);
 c.notAfter=1;c.pdfSha256='b'.repeat(64);bytes.fill(0);await active;
 assert.equal(f.stored.get('job').notAfter,expiry);assert.deepEqual(f.calls.find(x=>x[0]==='fetch'&&x[2].method==='POST')[2].body,PDF);
});

test('v2 stop can drain legacy state without inventing a finite retention deadline',async()=>{
 const f=fixture();await f.job.ready;
 f.stored.set('job',{jobId:ID,status:'running',deadline:Date.now()+10000,cleanupAttempts:0});
 await f.job.cancelV2(stop(contract()));assert.equal(f.stored.get('job').rpcVersion,undefined);assert.equal(f.stored.get('job').notAfter,undefined);
 await assert.rejects(f.job.parseV2(contract(),PDF),/processing_failed/u);
});

test('restart poison and alarm retain the original v2 deadline',async()=>{
 const f=fixture(),c=contract();await f.job.ready;f.stored.set('job',{jobId:ID,status:'running',deadline:c.notAfter,cleanupAttempts:0,rpcVersion:2,notAfter:c.notAfter});
 const restarted=new DoclingJob(f.ctx,{DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true'});await restarted.ready;await restarted.alarm();
 assert.equal(f.stored.get('job').notAfter,c.notAfter);assert.equal(f.stored.get('job').status,'poisoned');
});

test('entrypoint forwards exact v2 snapshots and stopping stays available with execution off',async()=>{
 let parsed,stopped;const c=contract(),entry=new DoclingProcessor({}, {DOCLING_RPC_V2_ONLY:'true',DOCLING_EXECUTION_ENABLED:'true',
  DOCLING_JOBS:{idFromName:x=>x,get:()=>({parseV2:(v,b)=>{parsed={v,b};return 'synthetic';},cancelV2:v=>{stopped=v;return {cancelled:true};}})}});
 assert.equal(await entry.parseV2(c,PDF),'synthetic');assert.deepEqual(parsed.v,c);assert.notEqual(parsed.v,c);
 entry.env.DOCLING_EXECUTION_ENABLED='false';await entry.cancelV2(stop(c));assert.deepEqual(stopped,stop(c));
 await assert.rejects(entry.parseV2(c,PDF),/execution_disabled/u);
});
