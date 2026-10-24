// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {qualityEnvironment, qualitySource} from './rag-quality-fixture.ts';
import {accountKey, indexSource, deleteSource, deleteAccountRAG, cleanupRAG, cleanupScheduledRAG} from './rag/storage.ts';
import {updateConsent, prepareDocument, invalidateDocument, readControl} from './rag/control.ts';
import {retrieve, handleRAG} from './rag/index.ts';
import {revalidateRetrieval} from './rag/authorization.ts';
import {sourceReadiness} from './rag/readiness.ts';
import {handleAI} from './ai.ts';

const owner = {sub:'synthetic-control-owner'};
const other = {sub:'synthetic-control-other'};
const scope = {rag:{scope:{kind:'library'}},message:'光合成のしくみを説明して'};
async function managed(overrides={}) {
 const env = qualityEnvironment(); env.RAG_AUTO_INDEX_ENABLED='true';
 env.RATE_LIMIT_RAG_INDEX={limit:async()=>({success:true})};
 const key=await accountKey(owner.sub);
 await updateConsent(env,key,{enabled:true,expectedEpoch:0});
 const prepare={documentId:'document-a',requestId:'prepare-a',expectedGeneration:0,consentEpoch:1,
  sourceHash:'a'.repeat(64),title:'合成教材',folderId:'folder-a',totalPages:1,...overrides};
 const proof=await prepareDocument(env,key,prepare);
 const source=qualitySource({...prepare,sourceId:proof.sourceId,kind:'pdf',control:proof});
 return {env,key,proof,source,prepare};
}
async function route(env,path,payload,session=owner,method='POST') {
 const req=new Request('https://example.test'+path,{method,...(method==='GET'?{}:{body:JSON.stringify(payload)})});
 const response=await handleRAG(new URL(req.url),req,env,session);
 return {status:response.status,body:await response.json()};
}
async function block(c,state='locked') {
 return invalidateDocument(c.env,c.key,c.proof.documentId,{state,expectedGeneration:c.proof.generation,consentEpoch:c.proof.consentEpoch});
}
test('managed PDF retains page correctness, notebook/folder scope, and tenant isolation',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 const result=await retrieve(c.env,owner,scope);assert.equal(result.citations.length,1);
 assert.equal(result.citations[0].sourceId,c.proof.sourceId);assert.equal(result.citations[0].pageNumber,1);
 assert.ok(!result.context.includes('authorization'));assert.ok(!JSON.stringify(result).includes('sourceSnapshot'));
 assert.equal((await retrieve(c.env,other,scope)).context,'');
 for(const requested of [{kind:'folder',folderId:'wrong'},{kind:'notebook',sourceId:'wrong'}])
  assert.equal((await retrieve(c.env,owner,{...scope,rag:{scope:requested}})).context,'');
 assert.equal((await retrieve(c.env,owner,{...scope,rag:{scope:{kind:'folder',folderId:'folder-a'}}})).citations.length,1);
});
test('100-page managed PDF uploads in 5-page batches; identical retry does not re-embed',async()=>{
 const c=await managed({totalPages:100});
 for(let start=1;start<=100;start+=5){
  const batch={...c.source,pages:Array.from({length:5},(_,i)=>({pageNumber:start+i,text:`合成資料 ${start+i}ページ。光合成は植物が光を使って養分を作るしくみ。`}))};
  await indexSource(c.env,c.key,batch); const retry=await indexSource(c.env,c.key,batch);assert.equal(retry.embedded,0);assert.equal(retry.skipped,5);
 }
 const rows=c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_pages WHERE account_key=?').get(c.key);assert.equal(rows.n,100);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT complete FROM rag_sources').get().complete,1);
 assert.equal((await sourceReadiness(c.env,c.key,c.proof.sourceId)).state,'ready');
 assert.equal(c.env.calls.filter(c=>c.model.includes('bge-m3')).length,100);
 assert.deepEqual(await prepareDocument(c.env,c.key,c.prepare),c.proof);
});
test('managed mode rejects legacy source IDs and forged account/body eligibility',async()=>{
 const c=await managed();
 await assert.rejects(indexSource(c.env,c.key,qualitySource({sourceId:'new-unmanaged'})),/control_required/);
 await assert.rejects(indexSource(c.env,await accountKey(other.sub),c.source),/control_required/);
 await block(c,'excluded');
 await assert.rejects(indexSource(c.env,c.key,{...c.source,locked:false,state:'eligible',accountKey:'other'}),/control_conflict/);
 await assert.rejects(indexSource(c.env,c.key,{...c.source,sourceId:'replacement-id'}),/control_conflict/);
});
test('reordered generations reject stale writer and stale manifest',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 const second=await prepareDocument(c.env,c.key,{...c.prepare,requestId:'prepare-b',expectedGeneration:1});
 await assert.rejects(indexSource(c.env,c.key,c.source),/control_conflict/);
 await assert.rejects(prepareDocument(c.env,c.key,{...c.prepare,requestId:'stale'}),/control_conflict/);
 await indexSource(c.env,c.key,{...c.source,sourceId:second.sourceId,control:second});
 await cleanupRAG(c.env,c.key);assert.equal((await retrieve(c.env,owner,scope)).citations[0].sourceId,second.sourceId);
});
for(const moment of ['embedding','upsert']) test(`in-flight ${moment} cannot publish after revocation`,async()=>{
 const c=await managed();let once=false;
 const target=moment==='embedding'?c.env.AI:c.env.RAG_VECTORIZE,method=moment==='embedding'?'run':'upsert';
 const original=target[method].bind(target);
 target[method]=async(...args)=>{if(!once){once=true;await updateConsent(c.env,c.key,{enabled:false,expectedEpoch:1});}return original(...args);};
 await assert.rejects(indexSource(c.env,c.key,c.source),/index_cancelled/);
 assert.equal((await retrieve(c.env,owner,scope)).context,'');
 await cleanupRAG(c.env,c.key);assert.equal(c.env.vectors.size,0);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks').get().n,0);
});
test('lock during rerank removes context and citation before final assembly',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);const run=c.env.AI.run.bind(c.env.AI);
 c.env.AI.run=async(model,input)=>{if(model.includes('reranker'))await block(c);return run(model,input);};
 const result=await retrieve(c.env,owner,scope);assert.equal(result.context,'');assert.deepEqual(result.citations,[]);
});
test('final proof checks neighbors, not just citation anchor',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);const result=await retrieve(c.env,owner,scope);assert.ok(result.context);
 const proof=result.authorization.references[0];
 proof.chunkIds.push('missing-neighbor');assert.equal((await revalidateRetrieval(c.env,owner,result)).context,'');
});
test('final revalidation rejects revoked data and a foreign session',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);const result=await retrieve(c.env,owner,scope);assert.ok(result.context);
 assert.equal((await revalidateRetrieval(c.env,other,result)).context,'');
 await block(c);assert.equal((await revalidateRetrieval(c.env,owner,result)).context,'');
 assert.equal((await sourceReadiness(c.env,c.key,c.proof.sourceId)).state,'missing');
});
test('failed physical cleanup keeps eligibility closed and retries when flags are off',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);await block(c,'deleted');
 const deletion=c.env.RAG_VECTORIZE.deleteByIds;c.env.RAG_VECTORIZE.deleteByIds=async()=>{throw Error('synthetic outage');};
 const pending=await cleanupRAG(c.env,c.key);assert.equal(pending.pending,1);
 assert.equal((await retrieve(c.env,owner,scope)).context,'');
 c.env.RAG_ENABLED='false';c.env.RAG_AUTO_INDEX_ENABLED='false';c.env.RAG_VECTORIZE.deleteByIds=deletion;
 await cleanupScheduledRAG(c.env);assert.equal(c.env.vectors.size,0);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_cleanup_jobs').get().n,0);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks_fts').get().n,0);
});
test('late upsert after expired-lease cleanup is durably compensated even when deletion fails',async()=>{
 const c=await managed();const upsert=c.env.RAG_VECTORIZE.upsert.bind(c.env.RAG_VECTORIZE),del=c.env.RAG_VECTORIZE.deleteByIds;
 c.env.RAG_VECTORIZE.upsert=async rows=>{
  await block(c);c.env.ADMIN_DB.db.prepare('UPDATE rag_sources SET lease_until=0 WHERE account_key=?').run(c.key);
  await cleanupRAG(c.env,c.key);assert.equal(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks').get().n,0);
  await upsert(rows);c.env.RAG_VECTORIZE.deleteByIds=async()=>{throw Error('synthetic outage');};
 };
 await assert.rejects(indexSource(c.env,c.key,c.source),/synthetic outage/);
 assert.ok(c.env.vectors.size);assert.ok(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_cleanup_vectors').get().n);
 c.env.RAG_VECTORIZE.deleteByIds=del;await cleanupScheduledRAG(c.env);assert.equal(c.env.vectors.size,0);
});
test('source and account erasure invalidate registry, FTS, vectors and future stale grants',async()=>{
 for(const kind of ['source','account']){
  const c=await managed();await indexSource(c.env,c.key,c.source);
  if(kind==='source')await deleteSource(c.env,c.key,c.proof.sourceId);else await deleteAccountRAG(c.env,owner.sub);
  assert.equal(c.env.vectors.size,0);assert.equal(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks_fts').get().n,0);
  assert.equal(c.env.ADMIN_DB.db.prepare('SELECT title FROM rag_documents').get().title,'');
  assert.equal((await retrieve(c.env,owner,scope)).context,'');
  assert.ok(await readControl(c.env.ADMIN_DB,c.key));
 }
});
test('management routes enforce flags, size, rate, authentication and disabled erasure',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 assert.equal((await route(c.env,'/api/rag/consent',{},null,'GET')).status,401);
 assert.equal((await route(c.env,'/api/rag/documents/prepare',{extra:'x'.repeat(9000)})).status,413);
 c.env.RAG_AUTO_INDEX_ENABLED='false';
 assert.equal((await route(c.env,'/api/rag/index',c.source)).status,403);
 assert.equal((await route(c.env,'/api/rag/documents/prepare',c.prepare)).status,403);
 c.env.RAG_ENABLED='false';
 assert.equal((await route(c.env,'/api/rag/consent',{enabled:false,expectedEpoch:1})).status,200);
 assert.equal((await route(c.env,'/api/rag/cleanup',{})).status,200);
 c.env.RATE_LIMIT_RAG_INDEX.limit=async()=>({success:false});assert.equal((await route(c.env,'/api/rag/consent',{},owner,'GET')).status,429);
});
test('missing control schema and broken registry never downgrade a managed upload',async()=>{
 const c=await managed();c.env.ADMIN_DB.db.exec('DROP TABLE rag_controls');
 assert.equal((await route(c.env,'/api/rag/index',c.source)).status,503);
 assert.equal((await retrieve(c.env,owner,scope)).context,'');
 assert.equal((await route(c.env,'/api/rag/index',qualitySource())).status,503);
 assert.equal((await route(c.env,'/api/rag/consent',{enabled:true,expectedEpoch:0})).status,503);
 const d=await managed();await indexSource(d.env,d.key,d.source);d.env.ADMIN_DB.db.exec('DROP TABLE rag_documents');
 assert.equal((await retrieve(d.env,owner,scope)).context,'');
 assert.equal((await route(d.env,'/api/rag/index',d.source)).status,503);
});
test('ordinary OpenAI retries do not resend RAG data revoked during the first attempt',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 const values=new Map();Object.assign(c.env,{OPENAI_LUNA_MODEL: "gpt-test-luna", AI_MODERATION: "off", OPENAI_API_KEY:'synthetic-key',AI_RETRY_BASE_MS:'1',
  STUDIQUO_DATA:{get:async(k,type)=>type==='json'&&values.get(k)?JSON.parse(values.get(k)):values.get(k)??null,put:async(k,v)=>values.set(k,v)},
  RATE_COUNTER:{getByName:()=>({bump:async()=>true,take:async()=>({ok:true,windowEndsAt:1}),give:async()=>{},reserve:async()=>({ok:true,windowEndsAt:1}),release:async()=>true})}});
 const original=globalThis.fetch;const bodies=[];
 try{
  globalThis.fetch=async(url,opts)=>{
   bodies.push(JSON.parse(opts.body));
   if(bodies.length===1){await block(c);return new Response('synthetic quota',{status:429});}
   return new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
  };
  const req=new Request('https://example.test/api/ai/chat',{method:'POST',headers:{'X-Studiquo-RAG-Consent':'rag-openai-v1'},body:JSON.stringify({messages:[{role:'user',text:scope.message}],rag:scope.rag})});
  const tasks=[];const response=await handleAI(new URL(req.url),req,c.env,'synthetic-device',{waitUntil:p=>tasks.push(p)},owner,'standard');
  const text=await response.text();await Promise.all(tasks);
  assert.ok(bodies[0].instructions.includes('UNTRUSTED'));
  assert.ok(!bodies[1].instructions.includes('UNTRUSTED'));
  assert.ok(!text.includes('"citations"'));
 }finally{globalThis.fetch=original;}
});

test('expired writer compensation never invalidates a successful same-source retry',async()=>{
 const c=await managed();const upsert=c.env.RAG_VECTORIZE.upsert.bind(c.env.RAG_VECTORIZE);let first=true;
 c.env.RAG_VECTORIZE.upsert=async rows=>{
  if(first){first=false;c.env.ADMIN_DB.db.prepare('UPDATE rag_sources SET lease_until=0 WHERE account_key=?').run(c.key);
   await indexSource(c.env,c.key,c.source);
  }
  await upsert(rows);
 };
 await assert.rejects(indexSource(c.env,c.key,c.source),/index_cancelled/);
 await cleanupScheduledRAG(c.env);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT state FROM rag_documents').get().state,'eligible');
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT complete,deleted FROM rag_sources').get().complete,1);
 assert.equal((await retrieve(c.env,owner,scope)).citations.length,1);
 assert.equal(c.env.vectors.size,1);
});
test('accepted upsert with lost response retains write-ahead IDs after source cleanup',async()=>{
 const c=await managed();const upsert=c.env.RAG_VECTORIZE.upsert.bind(c.env.RAG_VECTORIZE);
 c.env.RAG_VECTORIZE.upsert=async rows=>{
  await block(c);c.env.ADMIN_DB.db.prepare('UPDATE rag_sources SET lease_until=0 WHERE account_key=?').run(c.key);
  await cleanupRAG(c.env,c.key);await upsert(rows);throw Error('synthetic response lost');
 };
 await assert.rejects(indexSource(c.env,c.key,c.source),/synthetic response lost/);
 assert.ok(c.env.vectors.size);assert.ok(c.env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_cleanup_vectors').get().n);
 await cleanupScheduledRAG(c.env);assert.equal(c.env.vectors.size,0);
});
test('unsettled writes remain journaled across cleanup passes and block completed account erasure',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 const pending='synthetic-abandoned-id';
 c.env.ADMIN_DB.db.prepare('INSERT INTO rag_cleanup_vectors(account_key,source_id,chunk_id,writer_lease) VALUES(?,?,?,?)').run(c.key,c.proof.sourceId,pending,'terminated-writer');
 await block(c);await cleanupScheduledRAG(c.env);await cleanupScheduledRAG(c.env);
 assert.ok(c.env.ADMIN_DB.db.prepare('SELECT 1 FROM rag_cleanup_vectors WHERE chunk_id=?').get(pending));
 await assert.rejects(deleteAccountRAG(c.env,owner.sub),/deletion_busy/);
 assert.equal((await retrieve(c.env,owner,scope)).context,'');
});
test('revocation immediately before embedding prevents any document text model call',async()=>{
 const c=await managed();const prepare=c.env.ADMIN_DB.prepare;let fired=false;
 c.env.ADMIN_DB.prepare=sql=>{
  const statement=prepare(sql);return {bind(...args){const bound=statement.bind(...args);
   if(sql.startsWith('SELECT chunk_id FROM rag_chunks')&&sql.includes('ready=0'))return {...bound,all:async()=>{const rows=await bound.all();if(!fired){fired=true;await block(c);}return rows;}};
   return bound;
  }};
 };
 await assert.rejects(indexSource(c.env,c.key,c.source),/index_cancelled/);
 assert.equal(c.env.calls.length,0);
});
test('maximum document ID supports prepare and exclusion through the same routes',async()=>{
 const c=await managed({documentId:'d'.repeat(64)});
 assert.equal((await route(c.env,`/api/rag/documents/${c.prepare.documentId}/state`,{state:'excluded',expectedGeneration:1,consentEpoch:1})).status,200);
 assert.equal((await route(c.env,'/api/rag/documents/prepare',{...c.prepare,documentId:'d'.repeat(65)})).status,400);
});
test('simultaneous generation CAS admits exactly one update',async()=>{
 const c=await managed();const batch=c.env.ADMIN_DB.batch.bind(c.env.ADMIN_DB);let queue=Promise.resolve();
 // D1 batch transactions run serially, unlike this asynchronous SQLite shim.
 c.env.ADMIN_DB.batch=statements=>{const run=queue.then(()=>batch(statements));queue=run.catch(()=>{});return run;};
 const results=await Promise.allSettled(['concurrent-a','concurrent-b'].map(requestId=>prepareDocument(c.env,c.key,{...c.prepare,expectedGeneration:1,requestId})));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.equal(results.filter(r=>r.status==='rejected').length,1);
 assert.equal(c.env.ADMIN_DB.db.prepare('SELECT generation FROM rag_documents').get().generation,2);
});

test('document metadata recovery is owner-scoped and remains usable with flags off',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 c.env.RAG_ENABLED='false';c.env.RAG_AUTO_INDEX_ENABLED='false';
 const path='/api/rag/documents/document-a/state';
 const mine=await route(c.env,path,{},owner,'GET');assert.equal(mine.status,200);
 assert.equal(mine.body.sourceId,c.proof.sourceId);assert.equal(mine.body.generation,1);
 assert.ok(!('pages' in mine.body));assert.ok(!JSON.stringify(mine.body).includes('光合成'));
 const foreign=await route(c.env,path,{},other,'GET');assert.equal(foreign.body.state,'missing');
 assert.equal(foreign.body.sourceId,null);assert.equal(foreign.body.generation,0);
 const consent=await route(c.env,'/api/rag/consent',{},owner,'GET');assert.equal(consent.body.available,false);
 c.env.RATE_LIMIT_RAG_INDEX.limit=async()=>({success:false});assert.equal((await route(c.env,path,{},owner,'GET')).status,429);
});

test('device source manifest narrows every branch without broadening owner or explicit scope',async()=>{
 const c=await managed();await indexSource(c.env,c.key,c.source);
 const another=await prepareDocument(c.env,c.key,{...c.prepare,documentId:'another',requestId:'another'});
 await indexSource(c.env,c.key,{...c.source,sourceId:another.sourceId,control:another});
 const limited={...scope,rag:{scope:{kind:'library',sourceIds:[c.proof.sourceId]}}};
 const result=await retrieve(c.env,owner,limited);assert.equal(result.citations.length,1);assert.equal(result.citations[0].sourceId,c.proof.sourceId);
 assert.equal((await retrieve(c.env,other,limited)).context,'');
 for(const sourceIds of [[],['unregistered'],null,'all',Array(1001).fill(c.proof.sourceId)])
  assert.equal((await retrieve(c.env,owner,{...scope,rag:{scope:{kind:'library',sourceIds}}})).context,'');
 assert.equal((await retrieve(c.env,owner,{...scope,rag:{scope:{kind:'notebook',sourceId:another.sourceId,sourceIds:[c.proof.sourceId]}}})).context,'');
});
