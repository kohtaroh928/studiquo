// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { queryPlan } from './rag/query.ts';
import { retrieve } from './rag/retrieval.ts';
import { indexSource, accountKey } from './rag/storage.ts';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';

test('canonical question is shared by embedding and reranking; original question retained', async () => {
  const env = qualityEnvironment();
  await indexSource(env, await accountKey('synthetic-user'), qualitySource());
  const plan = queryPlan('これを説明して', '光合成とは？');
  assert.equal(plan.originalQuery, 'これを説明して');
  assert.ok(plan.canonicalQuery.includes('光合成'));
  const result = await retrieve(env, { sub: 'synthetic-user' }, { query: 'これを説明して', previousQuestion: '光合成とは？' });
  assert.equal(result.citations.length, 1);
  assert.equal(env.calls.at(-1).input.query, plan.canonicalQuery);
  assert.ok(env.calls.some(c => c.input.text?.includes(plan.canonicalQuery)));
  assert.equal(queryPlan('光合成を説明して', '地震').canonicalQuery, '光合成を説明して');
});

test('natural followups are rewritten only when referent is unresolved; explicit topics retained', () => {
  for (const query of ['これのしくみを説明して', 'それはなぜ？', 'さっきの式を詳しく', 'この二つの違いは？']) {
    const plan = queryPlan(query, '光合成とは？');
    assert.equal(plan.ambiguous, true, query);
    assert.equal(plan.needsClarification, false);
    assert.ok(plan.canonicalQuery.includes('光合成'));
  }
  for (const query of ['この資料の光合成を説明して', 'その植物の呼吸を説明して', '細胞とは何か']) {
    assert.equal(queryPlan(query, '地震').canonicalQuery, query);
    assert.equal(queryPlan(query, '地震').ambiguous, false);
  }
  assert.equal(queryPlan('それはなぜ？', 'もっと詳しく').needsClarification, true);
  assert.equal(queryPlan('それはなぜ？', '').needsClarification, true);
  assert.ok(queryPlan('それはなぜ？', '植物'.repeat(1000)).canonicalQuery.length < 650);
});

test('ambiguous question without usable history does not retrieve or guess a subject', async () => {
  const env = qualityEnvironment();
  const result = await retrieve(env, { sub: 'synthetic-user' }, { query: 'これのしくみを説明して' });
  assert.equal(result.status, 'clarification');
  assert.equal(result.context, '');
  assert.equal(result.citations.length, 0);
  assert.equal(env.calls.length, 0);
});

import { fuseRanks } from './rag/ranking.ts';
test('rank fusion retains strong RRF evidence despite reversed model ranking', () => {
  const candidates = Array.from({ length: 15 }, (_, i) => ({ chunk_id: `c-${i}`, rrf: 1/(61+i) }));
  const reversed = candidates.map((_, id) => ({ id, score: id/15 }));
  const fused = fuseRanks(candidates, reversed);
  assert.equal(fused.length, 15);
  assert.ok(fused.slice(0, 5).some(c => c.chunk_id === 'c-0'));
  assert.ok(fused.slice(0, 5).some(c => c.chunk_id === 'c-1'));
  assert.notDeepEqual(fused.map(c=>c.chunk_id), [...candidates].reverse().map(c=>c.chunk_id));
  for (const invalid of [undefined, reversed.slice(0, 5), [...reversed.slice(1), reversed[1]], reversed.map(r=>({...r,score:NaN})), reversed.map(r=>({...r,id:99}))]) {
    assert.deepEqual(fuseRanks(candidates, invalid), candidates);
  }
});

import { selectDiverse } from './rag/ranking.ts';
test('comparison separates subjects and shared aspect without splitting explanatory suffixes', () => {
  for (const question of ['光合成と呼吸の違いは？', '光合成と呼吸のしくみを比較して', '光合成および呼吸の共通点と違い']) {
    const plan = queryPlan(question);
    assert.deepEqual(plan.coverageGroups, ['光合成', '呼吸']);
    assert.equal(plan.queries.length, 3);
    assert.ok(plan.queries[1].includes('光合成'));
    assert.ok(plan.queries[2].includes('呼吸'));
  }
  assert.equal(queryPlan('光合成と呼吸と消化の違い').queries.length, 3);
  assert.deepEqual(queryPlan('植物とは何か、動物とはどう違うか').coverageGroups, []);
});
test('both comparison subjects survive Top15 and Top5; same-page overlaps are deduplicated', () => {
  const rows = Array.from({ length: 20 }, (_, i) => ({ chunk_id: `a-${i}`, source_id: 'a', page_number: i+1, text: '光合成の説明' }));
  const second = { chunk_id: 'b', source_id: 'b', page_number: 1, text: '呼吸の説明' };
  const first = selectDiverse([...rows, second], ['光合成','呼吸'], 15);
  assert.ok(first.some(x=>x.chunk_id==='b'));
  const last = selectDiverse(first, ['光合成','呼吸'], 5);
  assert.ok(last.some(x=>x.chunk_id==='b'));
  assert.equal(selectDiverse([rows[0],{...rows[0],chunk_id:'overlap'},second],[],5).length,2);
  assert.ok(!selectDiverse([...rows,second],['光合成','呼吸'],5,c=>c.source_id==='a').some(x=>x.chunk_id==='b'));
});

import { relevanceEvidence, importantTokens, importantText } from './rag/relevance.ts';
test('evidence gate combines semantic and lexical signals and permits semantic paraphrases', () => {
  const weak = {text:'植物の光合成',title:'理科',vectorScore:0.2,vectorRank:1};
  assert.equal(relevanceEvidence(weak,'会社の株価').accepted,false);
  assert.equal(relevanceEvidence({...weak,vectorScore:0.75},'光を使って養分をつくる方法').accepted,true);
  assert.equal(relevanceEvidence({...weak,vectorScore:undefined},'光合成を説明して').accepted,true);
  assert.equal(relevanceEvidence({...weak,vectorScore:NaN},'株価').accepted,false);
  assert.ok(!importantTokens('この資料の光合成を説明してください').includes('説明'));
});
test('insufficient evidence has no reference; partial comparison does not invent other subject', async () => {
  const env = qualityEnvironment();await indexSource(env,await accountKey('synthetic-user'),qualitySource());
  env.RAG_VECTORIZE.query=async()=>({matches:[...env.vectors.values()].map(v=>({id:v.id,score:0.6}))});
  const absent = await retrieve(env,{sub:'synthetic-user'},{query:'暗号通貨の相場'});
  assert.equal(absent.status,undefined);assert.equal(absent.citations.length,0);assert.equal(absent.context,'');
  const partial = await retrieve(env,{sub:'synthetic-user'},{query:'光合成と量子色力学の違い'});
  assert.equal(partial.status,'partial');assert.equal(partial.citations.length,1);
  assert.equal(partial.citations[0].sourceId,'quality-source');
});

import { contextualChildren, tokenCount } from './rag/chunking.ts';
import { deleteSource } from './rag/storage.ts';
import { readFileSync } from 'node:fs';
test('context-aware child preserves raw text, page headings and <=500 token boundaries', () => {
  const page = '# 光合成\n\n重要なしくみ\n'+('植物は光から養分を作ります。\n').repeat(90);
  const children = contextualChildren(page,'理科の教材');
  assert.ok(children.length>2);
  assert.ok(children.every(c=>tokenCount(c.text)<=500));
  assert.ok(children.every(c=>c.headingContext.includes('光合成')));
  assert.ok(children.every(c=>JSON.parse(c.embeddingText).title==='理科の教材'));
  assert.ok(children.every(c=>JSON.parse(c.embeddingText).text===c.text));
});
test('same v2 input skips embedding; title/heading changes invalidate input hash; folder move copies it', async () => {
  const env=qualityEnvironment(),key=await accountKey('synthetic-user');
  const source=qualitySource();await indexSource(env,key,source);
  const count=()=>env.calls.filter(c=>c.model.endsWith('bge-m3')).length;
  const before=count();await indexSource(env,key,source);assert.equal(count(),before);
  await indexSource(env,key,{...source,title:'理科：光合成'});assert.ok(count()>before);
  const row=env.ADMIN_DB.db.prepare('SELECT * FROM rag_chunks').get();
  assert.equal(row.index_version,2);assert.notEqual(row.chunk_hash,row.embedding_hash);
  const after=count();await indexSource(env,key,{...source,title:'理科：光合成',folderId:'folder-2'});assert.equal(count(),after);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT embedding_hash FROM rag_chunks').get().embedding_hash,row.embedding_hash);
  await deleteSource(env,key,source.sourceId);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT context_hash FROM rag_sources').get().context_hash,'');
});
test('0006-only index is rejected before mutation; legacy retrieval/deletion works, v2 upgrade reembeds', async () => {
  const env=qualityEnvironment({legacy:true}),key=await accountKey('synthetic-user');
  await assert.rejects(indexSource(env,key,qualitySource()),/index_upgrade_required/);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_accounts').get().n,0);
  env.ADMIN_DB.db.exec(readFileSync(new URL('../migrations/0021_rag_context.sql',import.meta.url),'utf8'));
  await indexSource(env,key,qualitySource());
  env.ADMIN_DB.db.exec("UPDATE rag_pages SET index_version=1,context_hash=''; UPDATE rag_chunks SET index_version=1,embedding_hash='';");
  const before=env.calls.length;await indexSource(env,key,qualitySource());
  assert.ok(env.calls.length>before);
  assert.equal(env.ADMIN_DB.db.prepare('SELECT index_version FROM rag_chunks').get().index_version,2);
});
test('title change cannot publish mixed old/new page context during batch upgrade', async () => {
  const env=qualityEnvironment(),key=await accountKey('synthetic-user');
  const source=qualitySource({totalPages:2,pages:[{pageNumber:1,text:'光合成の説明'},{pageNumber:2,text:'呼吸の説明'}]});
  await indexSource(env,key,source);
  await indexSource(env,key,{...source,title:'新版教材',pages:source.pages.slice(0,1)});
  assert.equal(env.ADMIN_DB.db.prepare('SELECT complete FROM rag_sources').get().complete,0);
  await indexSource(env,key,{...source,title:'新版教材',pages:source.pages.slice(1)});
  assert.equal(env.ADMIN_DB.db.prepare('SELECT complete FROM rag_sources').get().complete,1);
});

test('common document title cannot count as evidence for both comparison subjects', async () => {
  const env=qualityEnvironment();await indexSource(env,await accountKey('synthetic-user'),qualitySource({title:'光合成と呼吸の教材'}));
  const result=await retrieve(env,{sub:'synthetic-user'},{query:'光合成と呼吸の違い'});
  assert.equal(result.status,'partial');assert.equal(result.citations.length,1);
});
test('comparison coverage is computed from actually returned context after concurrent deletion', async () => {
  const env=qualityEnvironment();await indexSource(env,await accountKey('synthetic-user'),qualitySource({totalPages:2,pages:[{pageNumber:1,text:'光合成は光から養分を作る。'},{pageNumber:2,text:'呼吸は養分を分解する。'}]}));
  const original=env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare=sql=>{
    const statement=original(sql);if(!sql.includes('c.ordinal BETWEEN'))return statement;
    return {bind(...args){const bound=statement.bind(...args);if(args[2]===2)return{...bound,all:async()=>({results:[]})};return bound;}};
  };
  const result=await retrieve(env,{sub:'synthetic-user'},{query:'光合成と呼吸の違い'});
  assert.equal(result.status,'partial');assert.deepEqual(result.citations.map(c=>c.pageNumber),[1]);
});

test('explicit current-page scope supplies the referent without broadening to other pages/users', async () => {
  const env=qualityEnvironment();await indexSource(env,await accountKey('synthetic-user'),qualitySource({totalPages:2,pages:[{pageNumber:1,text:'光合成は養分を作る。'},{pageNumber:2,text:'呼吸は養分を分解する。'}]}));
  const payload={query:'これを説明して',scope:{type:'currentPage',sourceId:'quality-source',pageNumber:2}};
  const hit=await retrieve(env,{sub:'synthetic-user'},payload);
  assert.equal(hit.status,'grounded');assert.deepEqual(hit.citations.map(c=>c.pageNumber),[2]);
  assert.ok(!hit.context.includes('光合成'));
  const other=await retrieve(env,{sub:'other-user'},payload);
  assert.equal(other.citations.length,0);
  assert.equal((await retrieve(env,{sub:'synthetic-user'},{query:'これを説明して'})).status,'clarification');
});

import { handleRAG } from './rag/index.ts';
test('HTTP schema preflight precedes account reopening on migration-pending environments', async () => {
  const env=qualityEnvironment({legacy:true}),key=await accountKey('synthetic-user');
  env.RATE_LIMIT_RAG_INDEX={limit:async()=>({success:true})};
  env.ADMIN_DB.db.prepare('INSERT INTO rag_accounts(account_key,deleted) VALUES(?,1)').run(key);
  const req=new Request('https://example.test/api/rag/index',{method:'POST',body:JSON.stringify(qualitySource())});
  const response=await handleRAG(new URL(req.url),req,env,{sub:'synthetic-user',issuedAt:Math.floor(Date.now()/1000)});
  assert.equal(response.status,503);assert.equal((await response.json()).error,'index_upgrade_required');
  assert.equal(env.ADMIN_DB.db.prepare('SELECT deleted FROM rag_accounts').get().deleted,1);
});
test('old 0006-only saved chunks remain readable and erasable without the new migration', async () => {
  const env=qualityEnvironment({legacy:true}),key=await accountKey('synthetic-user');
  env.ADMIN_DB.db.prepare('INSERT INTO rag_accounts(account_key) VALUES(?)').run(key);
  env.ADMIN_DB.db.prepare("INSERT INTO rag_sources(account_key,source_id,title,kind,source_hash,total_pages,complete) VALUES(?,'legacy','旧資料','notebook',?,1,1)").run(key,'a'.repeat(64));
  env.ADMIN_DB.db.prepare("INSERT INTO rag_chunks(chunk_id,account_key,source_id,page_number,ordinal,page_hash,chunk_hash,text,search_text,ready) VALUES('legacy-chunk',?,'legacy',1,0,'old','old','光合成の説明','光合 合成',1)").run(key);
  env.vectors.set('legacy-chunk',{id:'legacy-chunk',values:Array(1024).fill(0.1),metadata:{accountKey:key,sourceId:'legacy',folderId:'',pageNumber:1}});
  const hit=await retrieve(env,{sub:'synthetic-user'},{query:'光合成'});
  assert.equal(hit.citations.length,1);
  await deleteSource(env,key,'legacy');
  assert.equal(env.vectors.size,0);assert.equal(env.ADMIN_DB.db.prepare('SELECT count(*) AS n FROM rag_chunks_fts').get().n,0);
});

test('comparison evidence is eligible per subject even when whole-query overlap is diluted', async () => {
  const env=qualityEnvironment();await indexSource(env,await accountKey('synthetic-user'),qualitySource({totalPages:2,pages:[{pageNumber:1,text:'光の屈折は境界で進む向きが変わる現象。'},{pageNumber:2,text:'音は振動が媒質を伝わる現象。'}]}));
  env.RAG_VECTORIZE.query=async()=>({matches:[...env.vectors.values()].map(v=>({id:v.id,score:0.4}))});
  const result=await retrieve(env,{sub:'synthetic-user'},{query:'光の屈折と音の定義を比較して'});
  assert.equal(result.status,'grounded');assert.deepEqual([...new Set(result.citations.map(c=>c.pageNumber))].sort(),[1,2]);
});

test('request-word cleanup does not destroy subject compounds', () => {
  for (const term of ['説明責任','比較演算子','ページング','内容証明','資料科学']) {
    assert.ok(importantTokens(term+'とは？').length>0);
    assert.ok(importantText(term+'とは？').includes(term),term);
  }
});
