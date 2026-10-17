import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { searchTokens, searchText, matchQuery, INDEX_FORMAT_VERSION } from './rag/chunking.js';
import { relevanceEvidence } from './rag/relevance.js';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.js';
import { indexSource, accountKey } from './rag/storage.js';
import { retrieve } from './rag/index.js';

test('mixed-script queries retain whole words and Japanese bigrams', () => {
 assert.deepEqual(searchTokens('ABCの概要'), ['abc','の概','概要']);
 assert.deepEqual(searchTokens('日本ABCの概要'), ['日本','abc','の概','概要']);
 assert.deepEqual(searchTokens('ＡＢＣ１２３の設定'), ['abc123','の設','設定']);
 assert.deepEqual(searchTokens('Примерの説明'), ['пример','の説','説明']);
 assert.deepEqual(searchTokens('αβの意味'), ['αβ','の意','意味']);
 for (const value of ['ABC123','日本語','Пример','مرحبا']) assert.ok(searchTokens(value).length);
});

test('FTS v2 writes and index version remain unchanged byte-for-byte', () => {
 assert.equal(INDEX_FORMAT_VERSION, 2);
 assert.equal(searchText('ABCの概要'), 'ab bc cの の概 概要');
 assert.equal(searchText('日本ABCの概要'), '日本 ab bc cの の概 概要');
 assert.equal(searchText('ＡＢＣ１２３の設定'), 'ab bc c1 12 23 3の の設 設定');
 assert.equal(searchText('日本語 ABC123'), '日本 本語 abc123');
});

test('query aliases find both old mixed-run FTS and old standalone-word FTS', () => {
 const db = new DatabaseSync(':memory:');
 try {
  db.exec('CREATE VIRTUAL TABLE fixture USING fts5(terms)');
  db.prepare('INSERT INTO fixture(rowid,terms) VALUES (?,?)').run(1, 'ab bc cの の概 概要');
  db.prepare('INSERT INTO fixture(rowid,terms) VALUES (?,?)').run(2, 'abc');
  assert.deepEqual(db.prepare('SELECT rowid FROM fixture WHERE fixture MATCH ? ORDER BY rowid').all(matchQuery('ABCの概要')).map(r=>r.rowid), [1,2]);
  assert.deepEqual(db.prepare('SELECT rowid FROM fixture WHERE fixture MATCH ? ORDER BY rowid').all(matchQuery('ABC')).map(r=>r.rowid), [2]);
 } finally { db.close(); }
});

test('compatibility query is quoted, deduplicated and bounded', () => {
 const query=matchQuery('ABCの概要 " OR * -(x)');
 assert.ok(query.includes('"abc"') && query.includes('"ab"'));
 assert.ok(query.split(' OR ').every(t=>/^"[\p{L}\p{N}]+"$/u.test(t)));
 assert.equal(new Set(query.split(' OR ')).size, query.split(' OR ').length);
 assert.equal(matchQuery(Array.from({length:100},(_,i)=>`ABC${i}の概要`).join(' ')).split(' OR ').length,64);
 assert.equal(matchQuery('" * ()'), '');
});

test('canonical relevance recovers mixed-script subject without lowering gates', () => {
 const candidate={text:'ABC\n各局は独立して動作する。'};
 assert.equal(relevanceEvidence(candidate,'ABCでは各局がどのように動作しますか').accepted,true);
 assert.equal(relevanceEvidence(candidate,'XYZでは各局がどのように動作しますか').accepted,false);
 assert.equal(relevanceEvidence(candidate,'ABCでは各局がどのように動作しますか').vectorScore,null);
});

test('existing indexed source remains idempotent and searchable after query correction', async () => {
 const env=qualityEnvironment();
 try {
  const key=await accountKey('synthetic-mixed-owner');
  const source=qualitySource({pages:[{pageNumber:1,text:'ABC\n各局は独立して動作する。'}]});
  await indexSource(env,key,source);
  const before=env.calls.filter(c=>!c.model.includes('reranker')).length;
  const id=env.ADMIN_DB.db.prepare('SELECT chunk_id FROM rag_chunks').get().chunk_id;
  await indexSource(env,key,source);
  assert.equal(env.calls.filter(c=>!c.model.includes('reranker')).length,before);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT chunk_id FROM rag_chunks').get().chunk_id,id);
  env.RAG_VECTORIZE.query=async()=>({matches:[]});
  const result=await retrieve(env,{sub:'synthetic-mixed-owner'},{query:'ABCでは各局がどのように動作しますか',rag:{scope:{kind:'notebook',sourceId:source.sourceId}}});
  assert.ok(result.citations.some(c=>c.pageNumber===1 && c.chunkId===id));
  const other=await retrieve(env,{sub:'synthetic-other-owner'},{query:'ABCでは各局がどのように動作しますか',rag:{scope:{kind:'library'}}});
  assert.equal(other.citations.length,0);
 } finally { env.ADMIN_DB.db.close(); }
});
