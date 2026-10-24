// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { qualityEnvironment } from './rag-quality-fixture.ts';
import { controlAvailable, readControl, updateConsent, prepareDocument, invalidateDocument, invalidateSourceControl, invalidateAccountControl, cleanupPending } from './rag/control.ts';
async function env() {
 const e=qualityEnvironment();
 if (!e.ADMIN_DB.db.prepare("SELECT name FROM sqlite_master WHERE name='rag_controls'").get()) e.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0022_rag_control.sql',import.meta.url),'utf8'));
 e.RAG_AUTO_INDEX_ENABLED='true'; await updateConsent(e,'owner',{enabled:true,expectedEpoch:0}); return e;
}
const req=(p={})=>({documentId:'document-a',requestId:'request-a',expectedGeneration:0,consentEpoch:1,sourceHash:'a'.repeat(64),title:'Synthetic document',folderId:'folder-a',totalPages:100,...p});
function source(e,id,key='owner'){e.ADMIN_DB.db.prepare("INSERT INTO rag_sources(account_key,source_id,title,kind,source_hash,total_pages,complete,lease,lease_until) VALUES(?,?,'Synthetic','pdf',?,100,1,'inflight',9999999999999)").run(key,id,'a'.repeat(64));}
test('consent CAS persists managed mode and rejects stale revocation',async()=>{
 const e=await env(); await assert.rejects(updateConsent(e,'owner',{enabled:false,expectedEpoch:0}),/control_conflict/);
 assert.deepEqual({...await readControl(e.ADMIN_DB,'owner')},{epoch:1,enabled:1});
 await updateConsent(e,'owner',{enabled:false,expectedEpoch:1}); assert.deepEqual({...await readControl(e.ADMIN_DB,'owner')},{epoch:2,enabled:0});
});
test('100 page registration is idempotent and replacement uses a fresh generation',async()=>{
 const e=await env(); const a=await prepareDocument(e,'owner',req()); source(e,a.sourceId);
 assert.deepEqual(await prepareDocument(e,'owner',req()),a);
 await assert.rejects(prepareDocument(e,'owner',req({title:'changed'})),/control_conflict/);
 const b=await prepareDocument(e,'owner',req({requestId:'request-b',expectedGeneration:1})); assert.notEqual(a.sourceId,b.sourceId); assert.equal(b.generation,2);
 assert.deepEqual((await cleanupPending(e,'owner')).map(r=>({...r})),[{source_id:a.sourceId}]);
 const old=e.ADMIN_DB.db.prepare('SELECT * FROM rag_sources WHERE source_id=?').get(a.sourceId); assert.equal(old.deleted,1); assert.equal(old.lease,'inflight');
 await assert.rejects(prepareDocument(e,'owner',req({requestId:'old-request'})),/control_conflict/);
});
test('lock blocks uploads; explicit restore advances generation',async()=>{
 const e=await env(); const a=await prepareDocument(e,'owner',req()); source(e,a.sourceId);
 await invalidateDocument(e,'owner','document-a',{state:'locked',expectedGeneration:1,consentEpoch:1});
 await assert.rejects(prepareDocument(e,'owner',req({expectedGeneration:2})),/control_conflict/);
 await invalidateDocument(e,'owner','document-a',{state:'eligible',expectedGeneration:2,consentEpoch:1});
 const b=await prepareDocument(e,'owner',req({expectedGeneration:3,requestId:'restored'})); assert.equal(b.generation,4); assert.notEqual(b.sourceId,a.sourceId);
});
test('unknown exclusions and deleted tombstones block delayed uploads',async()=>{
 const e=await env(); await invalidateDocument(e,'owner','document-a',{state:'excluded',expectedGeneration:0,consentEpoch:1});
 await assert.rejects(prepareDocument(e,'owner',req()),/control_conflict/);
 await invalidateDocument(e,'owner','unknown',{state:'deleted',expectedGeneration:0,consentEpoch:1});
 await assert.rejects(invalidateDocument(e,'owner','unknown',{state:'eligible',expectedGeneration:1,consentEpoch:1}),/control_conflict/);
});
test('revocation remains available with all RAG flags disabled',async()=>{
 const e=await env(); const a=await prepareDocument(e,'owner',req()); source(e,a.sourceId); e.RAG_ENABLED='false';e.RAG_AUTO_INDEX_ENABLED='false';
 await updateConsent(e,'owner',{enabled:false,expectedEpoch:1});
 await assert.rejects(prepareDocument(e,'owner',req({expectedGeneration:1})),/control_conflict/);
 await assert.rejects(updateConsent(e,'owner',{enabled:true,expectedEpoch:2}),/rag_auto_disabled/);
 assert.equal(e.ADMIN_DB.db.prepare('SELECT deleted FROM rag_sources WHERE source_id=?').get(a.sourceId).deleted,1);
});
test('account isolation applies to registry, invalidation and cleanup',async()=>{
 const e=await env();const a=await prepareDocument(e,'owner',req());source(e,a.sourceId);
 await updateConsent(e,'other',{enabled:true,expectedEpoch:0});await invalidateSourceControl(e,'other',a.sourceId);
 assert.equal(e.ADMIN_DB.db.prepare('SELECT state FROM rag_documents WHERE account_key=?').get('owner').state,'eligible');
 assert.deepEqual(await cleanupPending(e,'other'),[]);
 await assert.rejects(invalidateDocument(e,'other','document-a',{state:'deleted',expectedGeneration:1,consentEpoch:1}),/control_conflict/);
});
test('source deletion is terminal and clears registry metadata',async()=>{
 const e=await env();const a=await prepareDocument(e,'owner',req());source(e,a.sourceId);await invalidateSourceControl(e,'owner',a.sourceId);
 const d=e.ADMIN_DB.db.prepare('SELECT * FROM rag_documents').get();assert.equal(d.title,'');assert.equal(d.source_hash,'');
 await assert.rejects(invalidateDocument(e,'owner','document-a',{state:'eligible',expectedGeneration:2,consentEpoch:1}),/control_conflict/);
});
test('account deletion invalidates epochs and strips metadata',async()=>{
 const e=await env();const a=await prepareDocument(e,'owner',req());source(e,a.sourceId);
 e.ADMIN_DB.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run('owner');await invalidateAccountControl(e,'owner');
 const d=e.ADMIN_DB.db.prepare('SELECT * FROM rag_documents').get();assert.equal(d.title,'');assert.equal(d.source_hash,'');assert.equal(d.folder_id,null);assert.equal(d.state,'deleted');
 assert.deepEqual({...await readControl(e.ADMIN_DB,'owner')},{epoch:2,enabled:0});await assert.rejects(updateConsent(e,'owner',{enabled:true,expectedEpoch:2}),/account_deleted/);
});
test('schema absence differs from database outage',async()=>{
 assert.equal(await controlAvailable({prepare:()=>({bind:()=>({all:async()=>({results:[]})})})}),false);
 await assert.rejects(controlAvailable({prepare(){throw new Error('db unavailable');}}),/db unavailable/);
});
test('initial consent invalidates legacy rows only for the canonical owner',async()=>{
 const e=qualityEnvironment();
 if (!e.ADMIN_DB.db.prepare("SELECT name FROM sqlite_master WHERE name='rag_controls'").get()) e.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0022_rag_control.sql',import.meta.url),'utf8'));
 e.RAG_AUTO_INDEX_ENABLED='true';source(e,'legacy');source(e,'foreign','other');
 await updateConsent(e,'owner',{enabled:true,expectedEpoch:0});
 assert.equal(e.ADMIN_DB.db.prepare('SELECT deleted FROM rag_sources WHERE source_id=?').get('legacy').deleted,1);
 assert.equal(e.ADMIN_DB.db.prepare('SELECT deleted FROM rag_sources WHERE source_id=?').get('foreign').deleted,0);
 assert.deepEqual((await cleanupPending(e,'owner')).map(r=>({...r})),[{source_id:'legacy'}]);
});
test('failed stale block leaves winner searchable and does not queue deletion',async()=>{
 const e=await env();const a=await prepareDocument(e,'owner',req());source(e,a.sourceId);
 await assert.rejects(invalidateDocument(e,'owner','document-a',{state:'locked',expectedGeneration:0,consentEpoch:1}),/control_conflict/);
 assert.equal(e.ADMIN_DB.db.prepare('SELECT deleted FROM rag_sources WHERE source_id=?').get(a.sourceId).deleted,0);
 assert.deepEqual(await cleanupPending(e,'owner'),[]);
});
test('control rejects unbounded or malformed client values',async()=>{
 const e=await env();for(const p of [{requestId:''},{expectedGeneration:-1},{totalPages:10001},{documentId:'a/b'},{consentEpoch:0},{title:'x'.repeat(301)}]){
 await assert.rejects(prepareDocument(e,'owner',req(p)),/invalid_control|control_conflict/);
 }
});
