// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';
import { accountKey, indexSource, deleteSource, deleteAccountRAG } from './rag/storage.ts';
import { handleRAG } from './rag/index.ts';
const session = { sub: 'readiness-synthetic-owner' };
async function fixture(pages = 1) {
  const env = qualityEnvironment();
  env.RATE_LIMIT_RAG_INDEX = { limit: async () => ({ success: true }) };
  const key = await accountKey(session.sub);
  for (let i = 0; i < pages; i += 5) await indexSource(env, key, qualitySource({ kind: 'pdf', totalPages: pages,
    pages: Array.from({length: Math.min(5, pages - i)}, (_, j) => ({pageNumber: i+j+1, text: `Synthetic text page ${i+j+1}.`})) }));
  return { env, key };
}
async function status(env, owner = session, id = 'quality-source') {
  const url = new URL(`https://example.invalid/api/rag/sources/${id}/readiness`);
  const response = await handleRAG(url, new Request(url), env, owner);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  return { code: response.status, body: await response.json() };
}
test('100-page registration is not ready until get and filtered query are visible', async () => {
  const { env, key } = await fixture(100);
  const get = env.RAG_VECTORIZE.getByIds;
  const query = env.RAG_VECTORIZE.query;
  env.RAG_VECTORIZE.getByIds = async () => [];
  assert.equal((await status(env)).body.reason, 'vector_pending');
  const getSizes = [];
  env.RAG_VECTORIZE.getByIds = async ids => {
    assert.ok(ids.length <= 20, 'Live Vectorize lookup has a 20-ID maximum');
    getSizes.push(ids.length);
    return get(ids);
  };
  env.RAG_VECTORIZE.query = async () => ({matches: []});
  assert.equal((await status(env)).body.reason, 'query_pending');
  env.RAG_VECTORIZE.query = async (values, options) => {
    assert.deepEqual(options.filter, { accountKey: key, sourceId: 'quality-source', folderId: '', pageNumber: options.filter.pageNumber });
    assert.ok([1, 51, 100].includes(options.filter.pageNumber));
    return query(values, options);
  };
  const result = await status(env);
  assert.deepEqual(result.body, {state: 'ready', sourceHash: 'a'.repeat(64)});
  assert.equal(env.calls.length, 100, 'Readiness never invokes an AI model');
  assert.ok(getSizes.length >= 5 && getSizes.every(n => n <= 20));
});
test('readiness never reads foreign vectors and rejects missing authentication', async () => {
  const {env} = await fixture();
  env.RAG_VECTORIZE.getByIds = async () => { throw new Error('Must not be called'); };
  assert.deepEqual((await status(env, {sub: 'other-synthetic-owner'})).body, {state: 'missing'});
  assert.deepEqual((await status(env, session, 'absent')).body, {state: 'missing'});
  assert.equal((await status(env, null)).code, 401);
});
for (const property of ['accountKey', 'sourceId', 'folderId', 'pageNumber']) {
  test(`readiness rejects vector metadata mismatch: ${property}`, async () => {
    const {env} = await fixture();
    const v = [...env.vectors.values()][0];
    v.metadata[property] = property === 'pageNumber' ? 2 : 'wrong-synthetic';
    assert.equal((await status(env)).body.state, 'waiting');
  });
}
test('query returning a foreign or obsolete chunk never confirms readiness', async () => {
  const {env} = await fixture();
  env.RAG_VECTORIZE.query = async () => ({matches: [{id: 'foreign-synthetic'}]});
  assert.equal((await status(env)).body.state, 'waiting');
});
test('incomplete upload and active lease never confirm readiness', async () => {
  const {env} = await fixture();
  env.ADMIN_DB.db.exec('UPDATE rag_sources SET complete=0');
  assert.equal((await status(env)).body.reason, 'upload_incomplete');
  env.ADMIN_DB.db.exec(`UPDATE rag_sources SET complete=1,lease_until=${Date.now()+60000}`);
  assert.equal((await status(env)).body.reason, 'upload_incomplete');
});
for (const mode of ['delete', 'account-delete', 'edit', 'move']) {
  test(`readiness revalidates snapshot after await: ${mode}`, async () => {
    const {env, key} = await fixture();
    const query = env.RAG_VECTORIZE.query;
    env.RAG_VECTORIZE.query = async (...args) => {
      const result = await query(...args);
      if (mode === 'delete') await deleteSource(env, key, 'quality-source');
      if (mode === 'account-delete') await deleteAccountRAG(env, session.sub);
      if (mode === 'edit') env.ADMIN_DB.db.exec("UPDATE rag_sources SET context_hash='changed-synthetic'");
      if (mode === 'move') env.ADMIN_DB.db.exec("UPDATE rag_sources SET folder_id='moved-synthetic'");
      return result;
    };
    assert.notEqual((await status(env)).body.state, 'ready');
  });
}
test('disabled and rate limits skip expensive work; external failure is sanitized', async () => {
  const {env} = await fixture();
  env.RAG_ENABLED = 'false';
  assert.deepEqual((await status(env)).body, {state: 'disabled'});
  env.RAG_ENABLED = 'true';
  env.RATE_LIMIT_RAG_INDEX.limit = async () => ({success: false});
  assert.equal((await status(env)).code, 429);
  env.RATE_LIMIT_RAG_INDEX.limit = async () => ({success: true});
  env.RAG_VECTORIZE.getByIds = async () => { throw new Error('Synthetic sensitive details'); };
  assert.deepEqual((await status(env)).body, {error: 'rag_unavailable'});
});
test('empty source and bounded check never claim searchable', async () => {
  const {env, key} = await fixture();
  await indexSource(env, key, qualitySource({kind: 'pdf', sourceHash: 'b'.repeat(64), pages: [{pageNumber: 1, text: ''}]}));
  assert.equal((await status(env)).body.state, 'empty');
  // All rows are owner-scoped synthetic metadata; no model calls for the bound test.
  const insert = env.ADMIN_DB.db.prepare('INSERT INTO rag_chunks(chunk_id,account_key,source_id,page_number,ordinal,page_hash,chunk_hash,text,search_text,ready) VALUES(?,?,?,1,0,?,?,?, ?,1)');
  for (let i=0; i<1001; i++) insert.run(`synthetic-${i}`, key, 'quality-source', 'a', 'a', '', '');
  assert.equal((await status(env)).body.reason, 'check_limit');
});

test('100-page folder moves obey ID lookup bounds and reuse embeddings', async () => {
  const {env, key} = await fixture(100);
  const get = env.RAG_VECTORIZE.getByIds;
  env.RAG_VECTORIZE.getByIds = async ids => {
    assert.ok(ids.length <= 20);
    return get(ids);
  };
  const before = env.calls.length;
  await indexSource(env, key, qualitySource({kind: 'pdf', folderId: 'synthetic-folder', totalPages: 100,
    pages: [{pageNumber: 1, text: 'Synthetic text page 1.'}]}));
  assert.equal(env.calls.length, before);
  assert.equal((await status(env)).body.state, 'ready');
});
