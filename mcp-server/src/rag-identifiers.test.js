import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {identifierAliases, identifierQuery} from './rag/identifiers.js';
import {matchQuery, searchText, INDEX_FORMAT_VERSION} from './rag/chunking.js';
import {importantTokens, relevanceEvidence} from './rag/relevance.js';
import {queryPlan} from './rag/query.js';
import {detailRequirements} from './rag/answerability.js';
import {qualityEnvironment, qualitySource} from './rag-quality-fixture.js';
import {accountKey,indexSource} from './rag/storage.js';
import {retrieve} from './rag/index.js';

test('spaced and joined identifiers share one exact lexical requirement',()=>{
 for(const [a,b] of [['ABC12','ABC 12'],['ABC12.3','ABC 12.3'],['ABC12.3D','ABC 12.3D'],['ＡＢＣ１２','abc\t12']]) {
  assert.deepEqual(importantTokens(a),importantTokens(b));
  for(const [query,text] of [[a,b],[b,a]])assert.equal(relevanceEvidence({text},query).accepted,true);
 }
 assert.deepEqual(identifierQuery('ABC 12.3の特徴').identities,['abc12.3']);
});
test('different number, decimal, suffix and leading zero stay distinct',()=>{
 for(const [a,b] of [['ABC12','ABC13'],['ABC12.3','ABC12.4'],['ABC12.3D','ABC12.3C'],['ABC012','ABC12'],['ABC12.3','ABC123']]) {
  assert.notDeepEqual(importantTokens(a),importantTokens(b));
  assert.equal(relevanceEvidence({text:b},a).accepted,false);
 }
});
test('identifier evidence does not invent standalone number or prefix matches',()=>{
 assert.equal(relevanceEvidence({text:'ABC12'},'12').accepted,false);
 assert.equal(relevanceEvidence({text:'ABC12'},'ABC').accepted,false);
});
test('no joins across lines or money/time/unit conditions',()=>{
 assert.deepEqual(identifierAliases('ABC\n12'),[]);
 for(const text of ['USD 100','GHz 2','ABC 2026年','ABC 100円','ABC 20秒','ABC 2026-10-09','ABC 20°C','ABC 12/13'])assert.deepEqual(identifierAliases(text),[]);
 assert.ok(importantTokens('ABCの2026年の価格を教えて').includes('2026'));
 const query='ABCの2026年の価格を教えて';assert.equal(queryPlan(query).canonicalQuery,query);assert.ok(detailRequirements(query).facets.includes('price'));
});
test('old spaced and joined FTS terms work with both query forms without rewriting stored rows',()=>{
 const db=new DatabaseSync(':memory:');try{
  db.exec('CREATE VIRTUAL TABLE fixture USING fts5(terms)');
  db.prepare('INSERT INTO fixture(rowid,terms) VALUES (?,?)').run(1,'abc 12 3');
  db.prepare('INSERT INTO fixture(rowid,terms) VALUES (?,?)').run(2,'abc12 3');
  for(const query of ['ABC12.3','ABC 12.3'])assert.deepEqual(db.prepare('SELECT rowid FROM fixture WHERE fixture MATCH ? ORDER BY rowid').all(matchQuery(query)).map(x=>x.rowid),[1,2]);
  assert.equal(searchText('ABC 12.3'),'abc 12 3');assert.equal(searchText('ABC12.3'),'abc12 3');assert.equal(INDEX_FORMAT_VERSION,2);
  assert.ok(matchQuery('ABC12.3 " OR *').split(' OR ').every(t=>/^"[\p{L}\p{N}]+"$/u.test(t)));
 }finally{db.close();}
});
test('keyword-only identifier retrieval keeps scope and idempotency with old saved terms',async()=>{
 const env=qualityEnvironment();try{
  const key=await accountKey('synthetic-identifier-owner');
  const source=qualitySource({pages:[{pageNumber:1,text:'ABC 12.3\n合成規格の説明。'}]});
  await indexSource(env,key,source);const before=env.calls.length;
  const row=env.ADMIN_DB.db.prepare('SELECT chunk_id,search_text FROM rag_chunks').get();
  await indexSource(env,key,source);assert.equal(env.calls.length,before);assert.deepEqual(env.ADMIN_DB.db.prepare('SELECT chunk_id,search_text FROM rag_chunks').get(),row);
  env.RAG_VECTORIZE.query=async()=>({matches:[]});
  const request={query:'ABC12.3についてもっと詳しく',rag:{scope:{kind:'notebook',sourceId:source.sourceId}}};
  const hit=await retrieve(env,{sub:'synthetic-identifier-owner'},request);assert.ok(hit.citations.some(c=>c.chunkId===row.chunk_id && c.pageNumber===1));
  const wrong=await retrieve(env,{sub:'synthetic-identifier-owner'},{...request,query:'ABC12.4についてもっと詳しく'});assert.equal(wrong.citations.length,0);
  const outside=await retrieve(env,{sub:'synthetic-other-owner'},request);assert.equal(outside.citations.length,0);
 }finally{env.ADMIN_DB.db.close();}
});

test('concrete fact linking recognizes identifier whitespace without borrowing another price',async()=>{
 const {assessReference,detailRequirements}=await import('./rag/answerability.js');
 const correct=detailRequirements('ABC12.3の価格を教えて');
 assert.equal(assessReference('ABC 12.3 の価格は37円です。',correct).accepted,true);
 assert.equal(assessReference('ABC12.3の価格は37円です。',detailRequirements('ABC 12.3の価格を教えて')).accepted,true);
 for(const id of ['ABC12.4','ABC012.3','ABC12.3D'])assert.equal(assessReference('ABC 12.3 の価格は37円です。',detailRequirements(`${id}の価格を教えて`)).accepted,false);
 assert.equal(assessReference('ABC 12.3 の特徴をABC 12.4と比較し、価格は37円です。',correct).accepted,false);
 assert.equal(assessReference('ABC 12.3 の2025年の価格は37円です。',detailRequirements('ABC12.3の2026年の価格を教えて')).accepted,false);
});

test('actual supplied evidence retains original spelling and structural citation after detail linking',async()=>{
 const env=qualityEnvironment();try{
  const key=await accountKey('synthetic-identifier-detail-owner');
  const text='ABC 12.3 の価格は37円です。';
  const source=qualitySource({pages:[{pageNumber:1,text}]});await indexSource(env,key,source);
  const response=await retrieve(env,{sub:'synthetic-identifier-detail-owner'},{query:'ABC12.3の価格を教えて',scope:{kind:'notebook',sourceId:source.sourceId}});
  assert.equal(response.status,'grounded');assert.ok(response.context.includes(text));assert.equal(response.citations[0].pageNumber,1);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT text FROM rag_chunks').get().text,text);
  const wrong=await retrieve(env,{sub:'synthetic-identifier-detail-owner'},{query:'ABC12.4の価格を教えて',scope:{kind:'notebook',sourceId:source.sourceId}});
  assert.equal(wrong.status,'insufficient');assert.equal(wrong.context,'');assert.deepEqual(wrong.citations,[]);
 }finally{env.ADMIN_DB.db.close();}
});
