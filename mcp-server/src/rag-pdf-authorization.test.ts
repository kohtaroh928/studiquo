// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { qualityEnvironment } from './rag-quality-fixture.ts';
import { accountKey, deleteAccountRAG } from './rag/storage.ts';
import { updateConsent, prepareDocument, invalidateDocument, invalidateSourceControl } from './rag/control.ts';
import { readRawPDFConsent, updateRawPDFConsent, requireRawPDFDocumentAuthorization } from './rag/pdf-authorization.ts';
const session = { sub: 'synthetic-owner' };
const version = 'raw-pdf-docling-v1';
const grant = (changes = {}) => ({ enabled: true, expectedEpoch: 0, consentEpoch: 1, consentVersion: version, ...changes });
const reg = changes => ({ documentId:'doc-a', requestId:'request-a', expectedGeneration:0, consentEpoch:1,
  sourceHash:'a'.repeat(64), title:'Synthetic', totalPages:2, ...changes });
async function setup({ migrated = true } = {}) {
  const e = qualityEnvironment();
  e.AI_PROVIDER_APPROVED = e.RAG_AUTO_INDEX_ENABLED = e.RAG_PDF_PROCESSING_ENABLED = 'true';
  if (migrated) e.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0010_rag_raw_pdf_consent.sql',import.meta.url),'utf8'));
  const key = await accountKey(session.sub);
  await updateConsent(e, key, { enabled:true, expectedEpoch:0 });
  const d = await prepareDocument(e, key, reg());
  const proof = { documentId:d.documentId, sourceId:d.sourceId, generation:d.generation,
    consentEpoch:1, rawPDFConsentEpoch:1, sourceHash:'a'.repeat(64) };
  return { e, key, proof };
}
const reject = (fn, code) => assert.rejects(fn, error => { assert.equal(error.message,code); return true; });

test('migration is additive, consent is default denied, separate from text RAG', async () => {
  const { e, key, proof } = await setup();
  assert.deepEqual(await readRawPDFConsent(e,session), {enabled:false, rawPDFConsentEpoch:0, consentEpoch:null});
  await reject(() => requireRawPDFDocumentAuthorization(e,session,proof), 'raw_pdf_not_authorized');
  assert.deepEqual(await updateRawPDFConsent(e,session,grant()), {enabled:true, rawPDFConsentEpoch:1, consentEpoch:1});
  const authorized = await requireRawPDFDocumentAuthorization(e,session,proof);
  assert.equal(authorized.accountKey,key); assert.ok(Object.isFrozen(authorized));
  // prepareDocument reserves source ID without an indexed source; parsing must precede index.
  assert.equal(e.ADMIN_DB.db.prepare('SELECT COUNT(*) AS n FROM rag_sources').get().n,0);
  await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});
  assert.equal(e.ADMIN_DB.db.prepare('SELECT enabled FROM rag_controls WHERE account_key=?').get(key).enabled,1);
  assert.equal(e.ADMIN_DB.db.prepare('SELECT state FROM rag_documents WHERE account_key=?').get(key).state,'eligible');
});

test('raw revocation and regrant never resurrect old epochs (ABA)', async () => {
  const {e,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});
  await updateRawPDFConsent(e,session,grant({expectedEpoch:2}));
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
  assert.equal((await requireRawPDFDocumentAuthorization(e,session,{...proof,rawPDFConsentEpoch:3})).rawPDFConsentEpoch,3);
  await reject(()=>updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1}),'raw_pdf_consent_conflict');
});

test('parent RAG consent transaction revokes raw consent and does not auto regrant', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  await updateConsent(e,key,{enabled:false,expectedEpoch:1});
  assert.deepEqual(await readRawPDFConsent(e,session), {enabled:false,rawPDFConsentEpoch:2,consentEpoch:null});
  await updateConsent(e,key,{enabled:true,expectedEpoch:2});
  assert.deepEqual(await readRawPDFConsent(e,session), {enabled:false,rawPDFConsentEpoch:3,consentEpoch:null});
  await reject(()=>updateRawPDFConsent(e,session,grant({expectedEpoch:3})), 'raw_pdf_consent_conflict');
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
});

test('account tombstone alone invalidates raw consent before cleanup and fresh reopen', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  e.ADMIN_DB.db.prepare('UPDATE rag_accounts SET deleted=1 WHERE account_key=?').run(key);
  assert.deepEqual(await readRawPDFConsent(e,session),{enabled:false,rawPDFConsentEpoch:2,consentEpoch:null});
  e.ADMIN_DB.db.prepare('UPDATE rag_accounts SET deleted=0 WHERE account_key=?').run(key);
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
  assert.equal((await readRawPDFConsent(e,session)).enabled,false);
});

test('existing account deletion invalidates raw consent without changing old deletion API', async () => {
  const {e,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  await deleteAccountRAG(e,session.sub);
  assert.equal((await readRawPDFConsent(e,session)).enabled,false);
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
});

test('canonical owner prevents cross-account read, grant, and document access', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  const other={sub:'synthetic-other'}; const otherKey=await accountKey(other.sub);
  await updateConsent(e,otherKey,{enabled:true,expectedEpoch:0});
  await updateRawPDFConsent(e,other,grant());
  await reject(()=>requireRawPDFDocumentAuthorization(e,other,proof),'raw_pdf_not_authorized');
  await reject(()=>updateRawPDFConsent(e,session,grant({accountKey:otherKey})),'invalid_raw_pdf_consent');
  assert.equal(e.ADMIN_DB.db.prepare('SELECT enabled FROM rag_raw_pdf_consents WHERE account_key=?').get(key).enabled,1);
  for (const invalid of [null,{}, {sub:''}, {sub:123}, {sub:'a'.repeat(513)}])
    await reject(()=>readRawPDFConsent(e,invalid),'raw_pdf_unauthorized');
});

test('all lock/exclude/trash/delete transitions reject previous document proof', async () => {
  for (const state of ['locked','excluded','trashed','deleted']) {
    const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
    await invalidateDocument(e,key,'doc-a',{state,expectedGeneration:1,consentEpoch:1});
    await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
  }
});

test('replacement, restored document and deleted source cannot reuse old proof', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  const d=await prepareDocument(e,key,reg({expectedGeneration:1,requestId:'request-b'}));
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
  const current={...proof,sourceId:d.sourceId,generation:d.generation};
  await requireRawPDFDocumentAuthorization(e,session,current);
  await invalidateDocument(e,key,'doc-a',{state:'locked',expectedGeneration:2,consentEpoch:1});
  await invalidateDocument(e,key,'doc-a',{state:'eligible',expectedGeneration:3,consentEpoch:1});
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,current),'raw_pdf_not_authorized');
  const restored=await prepareDocument(e,key,reg({expectedGeneration:4,requestId:'request-c'}));
  await invalidateSourceControl(e,key,restored.sourceId);
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,{...proof,sourceId:restored.sourceId,generation:restored.generation}),'raw_pdf_not_authorized');
});

test('proof binds every snapshot field, with uniform absent/foreign denial', async () => {
  const {e,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  for (const change of [{sourceHash:'b'.repeat(64)},{sourceId:'missing'},{documentId:'missing'},
    {generation:0},{consentEpoch:0},{rawPDFConsentEpoch:0}])
    await reject(()=>requireRawPDFDocumentAuthorization(e,session,{...proof,...change}),'raw_pdf_not_authorized');
  for (const change of [{accountKey:'forged'},{rawPDFConsentEpoch:-1},{generation:1.1},{documentId:'a/b'},{sourceHash:'bad'}])
    await reject(()=>requireRawPDFDocumentAuthorization(e,session,{...proof,...change}),'invalid_raw_pdf_proof');
});

test('flags never prevent revocation but prevent both grant and authorization', async () => {
  for (const flag of ['RAG_ENABLED','RAG_AUTO_INDEX_ENABLED','RAG_PDF_PROCESSING_ENABLED','AI_PROVIDER_APPROVED']) {
    const {e,proof}=await setup(); await updateRawPDFConsent(e,session,grant()); e[flag]='false';
    await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_disabled');
    await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:1});
    await reject(()=>updateRawPDFConsent(e,session,grant({expectedEpoch:2})),'raw_pdf_disabled');
  }
});

test('missing or partial schema fails closed; old text RAG still functions', async () => {
  const {e,key,proof}=await setup({migrated:false});
  for(const fn of [()=>readRawPDFConsent(e,session),()=>updateRawPDFConsent(e,session,grant()),()=>requireRawPDFDocumentAuthorization(e,session,proof)])
    await reject(fn,'raw_pdf_upgrade_required');
  await updateConsent(e,key,{enabled:false,expectedEpoch:1});
  const full=await setup(); full.e.ADMIN_DB.db.exec('DROP TRIGGER rag_raw_pdf_account_deleted');
  await reject(()=>updateRawPDFConsent(full.e,session,grant()),'raw_pdf_upgrade_required');
});

test('same epoch concurrent CAS permits only one winner', async () => {
  const {e}=await setup(); const batch=e.ADMIN_DB.batch.bind(e.ADMIN_DB); let tail=Promise.resolve();
  // D1 serializes transactions. Serialize the SQLite fixture batches to model that boundary.
  e.ADMIN_DB.batch=statements=>{const p=tail.then(()=>batch(statements));tail=p.catch(()=>{});return p;};
  const results=await Promise.allSettled([updateRawPDFConsent(e,session,grant()),updateRawPDFConsent(e,session,grant())]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal(results.find(r=>r.status==='rejected').reason.message,'raw_pdf_consent_conflict');
});

test('transaction failure rolls parent and raw revocation back together', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  await assert.rejects(e.ADMIN_DB.batch([
    e.ADMIN_DB.prepare('UPDATE rag_controls SET epoch=epoch+1,enabled=0 WHERE account_key=?').bind(key),
    e.ADMIN_DB.prepare('INSERT INTO absent_table VALUES(1)').bind(),
  ]));
  await requireRawPDFDocumentAuthorization(e,session,proof);
});

test('parent control deletion/recreation and epoch exhaustion cannot revive consent', async () => {
  const {e,key,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  e.ADMIN_DB.db.prepare('DELETE FROM rag_controls WHERE account_key=?').run(key);
  await updateConsent(e,key,{enabled:true,expectedEpoch:0});
  await reject(()=>requireRawPDFDocumentAuthorization(e,session,proof),'raw_pdf_not_authorized');
  e.ADMIN_DB.db.prepare('UPDATE rag_raw_pdf_consents SET epoch=? WHERE account_key=?').run(Number.MAX_SAFE_INTEGER,key);
  await reject(()=>updateRawPDFConsent(e,session,grant({expectedEpoch:Number.MAX_SAFE_INTEGER})),'raw_pdf_epoch_exhausted');
  await updateRawPDFConsent(e,session,{enabled:false,expectedEpoch:Number.MAX_SAFE_INTEGER});
  await updateConsent(e,key,{enabled:false,expectedEpoch:1});
  assert.equal((await readRawPDFConsent(e,session)).rawPDFConsentEpoch,Number.MAX_SAFE_INTEGER);
});

test('database faults are fixed errors, not SQL or internal exception details', async () => {
  const e={ADMIN_DB:{prepare(){throw Error('secret database path');}}};
  await reject(()=>readRawPDFConsent(e,session),'raw_pdf_unavailable');
});

test('proof is copied before async checks to prevent mutable caller races', async () => {
  const {e,proof}=await setup(); await updateRawPDFConsent(e,session,grant());
  const pending=requireRawPDFDocumentAuthorization(e,session,proof); proof.documentId='changed';
  assert.equal((await pending).documentId,'doc-a');
});

test('parent revocation or account deletion between precheck and CAS defeats grant', async () => {
  for (const deleted of [false,true]) {
    const {e,key}=await setup(); const batch=e.ADMIN_DB.batch.bind(e.ADMIN_DB);
    e.ADMIN_DB.batch=async statements=>{
      e.ADMIN_DB.db.prepare(deleted
        ? 'UPDATE rag_accounts SET deleted=1 WHERE account_key=?'
        : 'UPDATE rag_controls SET enabled=0,epoch=epoch+1 WHERE account_key=?').run(key);
      return batch(statements);
    };
    await reject(()=>updateRawPDFConsent(e,session,grant()),'raw_pdf_consent_conflict');
    assert.equal((await readRawPDFConsent(e,session)).enabled,false);
  }
});

test('invalid consent values and unknown versions never grant permission', async () => {
  const {e}=await setup();
  for(const payload of [null,[],{},grant({enabled:1}),grant({expectedEpoch:-1}),
    grant({expectedEpoch:1.5}),grant({consentEpoch:NaN}),grant({consentVersion:'old'}),grant({owner:'forged'})])
    await reject(()=>updateRawPDFConsent(e,session,payload),'invalid_raw_pdf_consent');
  for(const value of [undefined,true,false,'false']) {
    e.RAG_PDF_PROCESSING_ENABLED=value;
    await reject(()=>updateRawPDFConsent(e,session,grant()),'raw_pdf_disabled');
  }
  assert.equal((await readRawPDFConsent(e,session)).enabled,false);
});
