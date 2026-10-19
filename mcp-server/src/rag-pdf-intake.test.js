import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {qualityEnvironment} from './rag-quality-fixture.js';
import {accountKey,deleteAccountRAG} from './rag/storage.js';
import {updateConsent,prepareDocument,invalidateDocument} from './rag/control.js';
import {updateRawPDFConsent} from './rag/pdf-authorization.js';
import {prepareRawPDFIntake,prepareLimitedRawPDFIntake,requireRawPDFIntakeAuthorization,cancelRawPDFIntake,verifyRawPDFIntakeBytes} from './rag/pdf-intake.js';
const session={sub:'synthetic-intake-owner'};
const bytes=new TextEncoder().encode('%PDF-synthetic-content');
const digest=async v=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',v)),b=>b.toString(16).padStart(2,'0')).join('');
const rejection=(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.message,code);return true;});
const cancellation=p=>({documentId:p.documentId,intakeId:p.intakeId,generation:p.generation});
async function setup({migrate=true}={}) {
 const e=qualityEnvironment(); e.AI_PROVIDER_APPROVED=e.RAG_AUTO_INDEX_ENABLED=e.RAG_PDF_PROCESSING_ENABLED='true';
 e.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0010_rag_raw_pdf_consent.sql',import.meta.url),'utf8'));
 if(migrate)e.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0011_rag_pdf_intakes.sql',import.meta.url),'utf8'));
 const key=await accountKey(session.sub);
 await updateConsent(e,key,{enabled:true,expectedEpoch:0});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:0,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 let now=100000;
 const options={clock:()=>now};
 const payload={documentId:'new-document',requestId:'request-a',expectedGeneration:0,
   pdfSha256:await digest(bytes),byteLength:bytes.length,consentEpoch:1,rawPDFConsentEpoch:1};
 return {e,key,payload,options,setTime:v=>{now=v;}};
}

test('new intake needs no text hash/document/source row and checks exact raw bytes',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 assert.equal(p.generation,1);assert.equal(p.expiresAt,700000);assert.ok(Object.isFrozen(p));
 const actual=await verifyRawPDFIntakeBytes(e,session,p,bytes,options);
 assert.deepEqual(actual.bytes,bytes);assert.notEqual(actual.bytes,bytes);assert.deepEqual(actual.authorization,p);
 for(const table of ['rag_documents','rag_sources','rag_chunks'])assert.equal(e.ADMIN_DB.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n,0);
 const columns=e.ADMIN_DB.db.prepare('PRAGMA table_info(rag_pdf_intakes)').all().map(c=>c.name);
 assert.equal(columns.some(n=>['text','title','body','pdf_bytes'].includes(n)),false);
});

test('strict retry returns original ID and deadline; changed retry is rejected',async()=>{
 const {e,payload,options,setTime}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);setTime(200000);
 assert.deepEqual(await prepareRawPDFIntake(e,session,payload,options),p);
 for(const change of [{pdfSha256:'b'.repeat(64)},{byteLength:bytes.length+1},{consentEpoch:2},{rawPDFConsentEpoch:2}])
  await rejection(()=>prepareRawPDFIntake(e,session,{...payload,...change},options),'pdf_intake_conflict');
});

test('replacement advances generation and rejects old prepare/auth/cancel',async()=>{
 const {e,payload,options}=await setup();const a=await prepareRawPDFIntake(e,session,payload,options);
 const b=await prepareRawPDFIntake(e,session,{...payload,expectedGeneration:1,requestId:'request-b'},options);
 assert.equal(b.generation,2);assert.notEqual(b.intakeId,a.intakeId);
 await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_conflict');
 await rejection(()=>requireRawPDFIntakeAuthorization(e,session,a,options),'pdf_intake_not_authorized');
 await rejection(()=>cancelRawPDFIntake(e,session,cancellation(a)),'pdf_intake_not_authorized');
 await requireRawPDFIntakeAuthorization(e,session,b,options);
});

test('cancellation is idempotent with flags off and clears raw identifying metadata',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 e.RAG_ENABLED='false';await cancelRawPDFIntake(e,session,cancellation(p));await cancelRawPDFIntake(e,session,cancellation(p));e.RAG_ENABLED='true';
 const row=e.ADMIN_DB.db.prepare('SELECT * FROM rag_pdf_intakes').get();assert.equal(row.pdf_sha256,null);assert.equal(row.byte_length,null);
 await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
 await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_conflict');
 const next=await prepareRawPDFIntake(e,session,{...payload,expectedGeneration:1,requestId:'new-request'},options);assert.equal(next.generation,2);
});

test('expiration boundary rejects verification and retry without deadline refresh',async()=>{
 const {e,payload,options,setTime}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);setTime(p.expiresAt);
 await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
 await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_conflict');
 await rejection(()=>verifyRawPDFIntakeBytes(e,session,p,bytes,options),'pdf_intake_not_authorized');
});

test('raw consent ABA invalidates old intake and clears digest via trigger',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});
 await updateRawPDFConsent(e,session,{enabled:true,expectedEpoch:2,consentEpoch:1,consentVersion:'raw-pdf-docling-v1'});
 assert.equal(e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_intakes').get().state,'cancelled');
 await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
});

test('parent RAG consent and account deletion trigger invalidation through raw consent',async()=>{
 for(const remove of [false,true]) {
  const {e,key,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
  if(remove)await deleteAccountRAG(e,session.sub);else await updateConsent(e,key,{enabled:false,expectedEpoch:1});
  const row=e.ADMIN_DB.db.prepare('SELECT state,pdf_sha256 FROM rag_pdf_intakes').get();assert.equal(row.state,'cancelled');assert.equal(row.pdf_sha256,null);
  await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
 }
});

test('account tombstone alone and direct account removal cannot resurrect pending intake',async()=>{
 for(const sql of ['UPDATE rag_accounts SET deleted=1 WHERE account_key=?','DELETE FROM rag_accounts WHERE account_key=?']){
  const {e,key,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
  e.ADMIN_DB.db.prepare(sql).run(key);
  assert.equal(e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_intakes').get().state,'cancelled');
  e.ADMIN_DB.db.prepare('INSERT INTO rag_accounts(account_key,deleted) VALUES(?,0) ON CONFLICT(account_key) DO UPDATE SET deleted=0').run(key);
  await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
 }
});

test('existing document registration or tombstone blocks new intake and invalidates old',async()=>{
 for(const existingFirst of [true,false]){
  const {e,key,payload,options}=await setup();
  const p=existingFirst?null:await prepareRawPDFIntake(e,session,payload,options);
  await invalidateDocument(e,key,payload.documentId,{state:'deleted',expectedGeneration:0,consentEpoch:1});
  await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_conflict');
  if(p){await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
   e.ADMIN_DB.db.prepare('DELETE FROM rag_documents').run();await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');}
 }
});

test('other owner, forged proof, and client-supplied owner never authorize',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);const other={sub:'synthetic-other'};
 await rejection(()=>requireRawPDFIntakeAuthorization(e,other,p,options),'pdf_intake_not_authorized');
 await rejection(()=>cancelRawPDFIntake(e,other,cancellation(p)),'pdf_intake_not_authorized');
 for(const change of [{pdfSha256:'b'.repeat(64)},{byteLength:bytes.length+1},{generation:2},{expiresAt:p.expiresAt+1},{documentId:'absent'}])
  await rejection(()=>requireRawPDFIntakeAuthorization(e,session,{...p,...change},options),'pdf_intake_not_authorized');
 await rejection(()=>prepareRawPDFIntake(e,session,{...payload,accountKey:'forged'},options),'invalid_pdf_intake');
 await rejection(()=>requireRawPDFIntakeAuthorization(e,null,p,options),'pdf_intake_unauthorized');
});

test('wrong digest, length, signature, and nonbytes cannot pass identity verification',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 const altered=bytes.slice();altered[altered.length-1]^=1;
 for(const b of [altered,bytes.slice(1),new Uint8Array(bytes.length),new ArrayBuffer(bytes.length),null])
  await rejection(()=>verifyRawPDFIntakeBytes(e,session,p,b,options),'pdf_intake_bytes_mismatch');
});

test('bytes and proof are copied before await so caller cannot replace verification data',async()=>{
 const {e,payload,options}=await setup();const p={...await prepareRawPDFIntake(e,session,payload,options)},input=bytes.slice();
 const pending=verifyRawPDFIntakeBytes(e,session,p,input,options);input.fill(0);p.pdfSha256='b'.repeat(64);
 assert.deepEqual((await pending).bytes,bytes);
});

test('cancellation or consent revocation during verification prevents bytes return',async()=>{
 for(const revoke of [false,true]) {
  const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
  let reads=0;const prepare=e.ADMIN_DB.prepare.bind(e.ADMIN_DB);
  e.ADMIN_DB.prepare=sql=>{const s=prepare(sql);return {bind(...args){const bound=s.bind(...args);
   if(sql.includes('SELECT * FROM rag_pdf_intakes WHERE account_key=? AND document_id=? AND intake_id=?')){
    const first=bound.first;bound.first=async()=>{const row=await first();if(++reads===1){
     if(revoke)await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});else await cancelRawPDFIntake(e,session,cancellation(p));
    }return row;};}return bound;}};};
  await rejection(()=>verifyRawPDFIntakeBytes(e,session,p,bytes,options),'pdf_intake_not_authorized');
 }
});

test('missing schema or missing trigger fails closed and DB faults stay fixed',async()=>{
 const {e,payload,options}=await setup({migrate:false});await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_upgrade_required');
 const full=await setup();full.e.ADMIN_DB.db.exec('DROP TRIGGER rag_pdf_intakes_document_inserted');
 await rejection(()=>prepareRawPDFIntake(full.e,session,full.payload,full.options),'pdf_intake_upgrade_required');
 full.e.ADMIN_DB.prepare=()=>{throw Error('private SQL detail');};
 await rejection(()=>prepareRawPDFIntake(full.e,session,full.payload,full.options),'pdf_intake_unavailable');
});

test('concurrent requests with the same expected generation cannot both replace',async()=>{
 const {e,payload,options}=await setup();
 const results=await Promise.allSettled([prepareRawPDFIntake(e,session,payload,options),prepareRawPDFIntake(e,session,{...payload,requestId:'request-b'},options)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.equal(results.find(r=>r.status==='rejected').reason.message,'pdf_intake_conflict');
});

test('simultaneous identical retries converge to one intake',async()=>{
 const {e,payload,options}=await setup();const [a,b]=await Promise.all([prepareRawPDFIntake(e,session,payload,options),prepareRawPDFIntake(e,session,payload,options)]);
 assert.deepEqual(a,b);assert.equal(e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,1);
});

test('current write authorization beats revocation after initial retry lookup',async()=>{
 const {e,payload,options}=await setup();const original=e.ADMIN_DB.prepare.bind(e.ADMIN_DB);
 e.ADMIN_DB.prepare=sql=>{const s=original(sql);return {bind(...args){const bound=s.bind(...args);
  if(sql.startsWith('INSERT INTO rag_pdf_intakes')){const run=bound.run;bound.run=async()=>{await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});return run();};}return bound;}};};
 await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_conflict');
 assert.equal(e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,0);
});

test('invalid payload, server clock and disabled flags never reserve',async()=>{
 const {e,payload,options}=await setup();
 for(const change of [{expectedGeneration:-1},{expectedGeneration:Number.MAX_SAFE_INTEGER},{byteLength:4},
  {byteLength:10485761},{pdfSha256:'bad'},{documentId:'a/b'},{expiresAt:99999},{rawPDFConsentEpoch:NaN}])
  await rejection(()=>prepareRawPDFIntake(e,session,{...payload,...change},options),'invalid_pdf_intake');
 for(const clock of [()=>NaN,()=>-1,()=>Number.MAX_SAFE_INTEGER])
  await rejection(()=>prepareRawPDFIntake(e,session,payload,{clock}),'invalid_pdf_intake_clock');
 for(const flag of ['AI_PROVIDER_APPROVED','RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED']){
  e[flag]=false;await rejection(()=>prepareRawPDFIntake(e,session,payload,options),'pdf_intake_disabled');e[flag]='true';
 }
 assert.equal(e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,0);
});

test('raw binding field changes and raw consent deletion invalidate without epoch change',async()=>{
 for(const sql of ['UPDATE rag_raw_pdf_consents SET rag_consent_epoch=2 WHERE account_key=?',
  'DELETE FROM rag_raw_pdf_consents WHERE account_key=?']){
  const {e,key,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
  e.ADMIN_DB.db.prepare(sql).run(key);
  assert.equal(e.ADMIN_DB.db.prepare('SELECT state FROM rag_pdf_intakes').get().state,'cancelled');
  await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_not_authorized');
 }
});

test('trigger invalidation rolls back with parent transaction failure',async()=>{
 const {e,key,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 await assert.rejects(e.ADMIN_DB.batch([
  e.ADMIN_DB.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').bind(key),
  e.ADMIN_DB.prepare('INSERT INTO no_such_table VALUES(1)').bind(),
 ]));
 await requireRawPDFIntakeAuthorization(e,session,p,options);
});

test('SQL identity faults after schema lookup never escape the fixed error boundary',async()=>{
 const {e,payload,options}=await setup();const p=await prepareRawPDFIntake(e,session,payload,options);
 const original=e.ADMIN_DB.prepare.bind(e.ADMIN_DB);
 e.ADMIN_DB.prepare=sql=>{if(!sql.includes('sqlite_master'))throw Error('private query body');return original(sql);};
 await rejection(()=>requireRawPDFIntakeAuthorization(e,session,p,options),'pdf_intake_unavailable');
});


test('bounded intake enforces row/pending caps atomically and permits same-document replacement',async()=>{
 const {e,payload,options}=await setup(),cap={ownerRows:1,globalRows:1,ownerPending:1,globalPending:1};
 const a=await prepareLimitedRawPDFIntake(e,session,payload,cap,options);
 await rejection(()=>prepareLimitedRawPDFIntake(e,session,{...payload,documentId:'other'},cap,options),'pdf_intake_conflict');
 await cancelRawPDFIntake(e,session,cancellation(a));
 const b=await prepareLimitedRawPDFIntake(e,session,{...payload,requestId:'replacement',expectedGeneration:1},cap,options);
 assert.equal(b.generation,2);assert.equal(e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_pdf_intakes').get().n,1);
});

test('pending cap and retained-row cap have separate meanings',async()=>{
 const {e,payload,options,setTime}=await setup(),cap={ownerRows:2,globalRows:2,ownerPending:1,globalPending:1};
 const a=await prepareLimitedRawPDFIntake(e,session,payload,cap,options);
 await rejection(()=>prepareLimitedRawPDFIntake(e,session,{...payload,documentId:'two'},cap,options),'pdf_intake_conflict');
 setTime(a.expiresAt);await prepareLimitedRawPDFIntake(e,session,{...payload,documentId:'two'},cap,options);
 setTime(a.expiresAt+600000);
 await rejection(()=>prepareLimitedRawPDFIntake(e,session,{...payload,documentId:'three'},cap,options),'pdf_intake_conflict');
});

test('parallel bounded intake cannot exceed global capacity; limits are mandatory',async()=>{
 const {e,payload,options}=await setup(),cap={ownerRows:1,globalRows:1,ownerPending:1,globalPending:1};
 const results=await Promise.allSettled([prepareLimitedRawPDFIntake(e,session,payload,cap,options),
  prepareLimitedRawPDFIntake(e,session,{...payload,documentId:'two'},cap,options)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 for(const bad of [undefined,null,{}, {...cap,ownerRows:0},{...cap,globalRows:0}])
  await rejection(()=>prepareLimitedRawPDFIntake(e,session,payload,bad,options),'pdf_intake_limits_required');
});
