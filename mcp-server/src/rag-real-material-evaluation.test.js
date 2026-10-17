import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { indexSource, accountKey } from './rag/storage.js';
import { retrieve } from './rag/retrieval.js';
import { join } from 'node:path';
import { loadManifest, evaluateMaterials, createEvaluationEnvironment, remoteRunAI, hash } from '../scripts/rag-quality/real-material-evaluate.mjs';
const fakeAI = async (model, input) => model.includes('reranker') ? { response: input.contexts.map((_, id) => ({ id, score: 1 - id / 100 })) } : { data: input.text.map(() => Array(1024).fill(.1)) };
function fixture(totalPages = 1) {
  const root = mkdtempSync(join(tmpdir(), 'rag-material-'));
  const pages = Array.from({ length: totalPages }, (_, i) => ({ pageNumber: i + 1, text: '光合成は植物が光を使って養分を作るしくみ。' }));
  writeFileSync(join(root, 'pages.json'), JSON.stringify(pages));
  const data = { sources: [{ sourceId: 'source-a', title: '私有教材名', kind: 'pdf', sourceHash: 'a'.repeat(64), totalPages, pagesFile: 'pages.json', folderId: 'folder-a' }],
    questions: [{ id: 'case-a', query: '光合成のしくみを説明して', expected: 'supported', expectedEvidence: [[{ sourceId: 'source-a', pageNumber: 1 }]], scope: { type: 'currentPage', sourceId: 'source-a', pageNumber: 1 } }] };
  const save = () => writeFileSync(join(root, 'manifest.json'), JSON.stringify(data)); save();
  return { root, data, save, load: () => loadManifest(join(root, 'manifest.json')), close: () => rmSync(root, { recursive: true, force: true }) };
}
test('100 pages use five-page batches, retain every page, and reindex without inference', async () => {
  const f = fixture(100); let count = 0;
  try {
    const report = await evaluateMaterials(f.load(), { runAI: async (...args) => { count++; return fakeAI(...args); } });
    assert.equal(report.status, 'complete'); assert.equal(report.pageCount, 100); assert.equal(report.sources[0].idempotent, true);
    assert.equal(report.sources[0].uploadBatches, 20); assert.equal(report.sources[0].embeddingCalls, 100); assert.equal(count, 102);
    assert.equal(report.results[0].citationValid, true); assert.equal(report.results[0].evidenceRecall, 1);
    const signals = report.results[0].candidateSignals;
    assert.ok(signals.length);
    for (const signal of signals) {
      assert.deepEqual(Object.keys(signal).sort(), ['accepted', 'chunkHash', 'keywordRank', 'lexicalCoverage', 'pageNumber', 'rrfRank', 'sourceHash', 'vectorRank', 'vectorScore'].sort());
      assert.equal(signal.sourceHash, hash('source-a')); assert.equal(signal.pageNumber, 1);
      assert.equal(typeof signal.accepted, 'boolean');
      assert.ok(Number.isFinite(signal.lexicalCoverage) && signal.lexicalCoverage >= 0 && signal.lexicalCoverage <= 1);
      assert.ok(signal.vectorScore === null || Number.isFinite(signal.vectorScore));
      assert.ok(Number.isInteger(signal.rrfRank) && signal.rrfRank >= 1);
      for (const field of ['keywordRank', 'vectorRank']) assert.ok(signal[field] === null || Number.isInteger(signal[field]) && signal[field] >= 1);
    }
    const serialized = JSON.stringify(report); for (const secret of ['光合成', '私有教材名', 'source-a', 'case-a', 'folder-a']) assert.equal(serialized.includes(secret), false);
  } finally { f.close(); }
});
test('duplicate text across sources has explicit ambiguous provenance and correct scoped citations', async () => {
  const f = fixture();
  try {
    f.data.sources.push({ ...f.data.sources[0], sourceId: 'source-b', folderId: 'folder-b' });
    f.data.questions[0].scope = { type: 'library' };
    f.data.questions.push({ ...f.data.questions[0], id: 'folder-case', scope: { type: 'folder', folderId: 'folder-b' }, expectedEvidence: [[{ sourceId: 'source-b', pageNumber: 1 }]] });
    f.save(); const report = await evaluateMaterials(f.load(), { runAI: fakeAI });
    assert.equal(report.status, 'complete'); assert.ok(report.results.every(r => r.citationValid));
    const ambiguous = report.results[0].stages.rerankInput;
    assert.ok(ambiguous.length > 0); assert.ok(ambiguous.every(row => row.ambiguous && row.candidates.length === 2));
    assert.deepEqual(new Set(ambiguous[0].candidates.map(c => c.sourceHash)), new Set([hash('source-a'), hash('source-b')]));
    assert.ok(report.results[0].stages.rerankOutput.every(row => row.candidates.length === 2 && row.ambiguous && Number.isFinite(row.score)));
    assert.equal(report.results[1].evidenceRecall, 1); assert.ok(report.results[1].stages.final.every(c => c.sourceHash === hash('source-b')));
  } finally { f.close(); }
});
test('manifest rejects path escape, duplicate pages, tampered page digest and unknown gold source with sanitized error', () => {
  const f = fixture();
  try {
    f.data.sources[0].pagesFile = '../secret-pages.json'; f.save(); assert.throws(f.load, /^Error: invalid_evaluation_manifest$/);
    f.data.sources[0].pagesFile = 'pages.json'; f.data.sources[0].pagesHash = 'f'.repeat(64); f.save(); assert.throws(f.load, /^Error: invalid_evaluation_manifest$/);
    delete f.data.sources[0].pagesHash; f.data.questions[0].expectedEvidence[0][0].sourceId = 'other'; f.save(); assert.throws(f.load, /^Error: invalid_evaluation_manifest$/);
    f.data.questions[0].expectedEvidence[0][0].sourceId = 'source-a'; f.data.sources[0].totalPages = 2; writeFileSync(join(f.root, 'pages.json'), JSON.stringify([{ pageNumber: 1, text: 'x' }, { pageNumber: 1, text: 'y' }])); f.save(); assert.throws(f.load, /^Error: invalid_evaluation_manifest$/);
  } finally { f.close(); }
});
test('anchor must exist on its golden page, and any manifest edit changes the freeze hash', () => {
  const f = fixture();
  try {
    const first = f.load().manifestHash;
    f.data.questions[0].expectedEvidence[0][0].anchor = '植物が光'; f.save();
    assert.notEqual(f.load().manifestHash, first);
    f.data.questions[0].expectedEvidence[0][0].anchor = '存在しない本文'; f.save();
    assert.throws(f.load, /^Error: invalid_evaluation_manifest$/);
  } finally { f.close(); }
});
test('notebook scope and other account never contribute citations or measured provenance', async () => {
  const rig = createEvaluationEnvironment({ runAI: fakeAI });
  try {
    const source = { sourceId: 'private-source', title: '光合成資料', kind: 'notebook', sourceHash: 'a'.repeat(64), totalPages: 1, pages: [{ pageNumber: 1, text: '光合成は植物が光を使って養分を作るしくみ。' }] };
    const mine = { sub: 'owner-one' }; const other = { sub: 'owner-two' }; const key = await accountKey(mine.sub);
    await indexSource(rig.env, key, source); await indexSource(rig.env, await accountKey(other.sub), source);
    await indexSource(rig.env, key, { ...source, sourceId: 'other-notebook' });
    const trace = { accountKey: key, scope: { type: 'notebook', sourceId: 'private-source' }, vector: [], keyword: [] }; rig.setTrace(trace);
    const hit = await retrieve(rig.env, mine, { query: '光合成のしくみを説明して', scope: { type: 'notebook', sourceId: 'private-source' } });
    await rig.drain(); assert.ok(hit.citations.length); assert.ok(hit.citations.every(c => c.sourceId === 'private-source'));
    assert.ok(trace.vector.flat().every(c => c.sourceHash === hash('private-source')));
    assert.ok(trace.keyword.flat().every(c => c.sourceHash === hash('private-source')));
    assert.ok(trace.rerankInput.every(c => !c.ambiguous && c.candidates.length === 1));
  } finally { rig.close(); }
});
test('budget blocks calls before network and failures never retain provider details', async () => {
  const rig = createEvaluationEnvironment({ maxCalls: 1, runAI: async () => { throw Error('private-provider-key-and-text'); } });
  try {
    await assert.rejects(rig.env.AI.run('@cf/baai/bge-m3', { text: ['private'] }), /^Error: evaluation_inference_failed$/);
    await assert.rejects(rig.env.AI.run('@cf/baai/bge-m3', {}), /^Error: evaluation_budget_exhausted$/);
    await rig.drain(); assert.equal(rig.calls.length, 1); assert.equal(JSON.stringify(rig.calls).includes('private'), false);
  } finally { rig.close(); }
});
test('budget exhausted inside production fallback makes the measurement explicitly incomplete', async () => {
  const f = fixture();
  try {
    const report = await evaluateMaterials(f.load(), { runAI: fakeAI, maxCalls: 1 });
    assert.equal(report.status, 'failed'); assert.equal(report.budgetExhausted, true); assert.equal(report.calls.length, 1);
  } finally { f.close(); }
});
test('remote client whitelists fixed origin/models, rejects redirect/error/oversize and sanitizes errors', async () => {
  let calls = 0;
  const run = remoteRunAI({ account: 'a'.repeat(32), token: 'fake-token', fetchImpl: async (url, options) => {
    calls++; assert.equal(new URL(url).origin, 'https://api.cloudflare.com'); assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify({ success: true, result: { data: [[1]] } }));
  } });
  await assert.rejects(run('evil-model', {}), /^Error: evaluation_inference_failed$/); assert.equal(calls, 0);
  assert.deepEqual(await run('@cf/baai/bge-m3', {}), { data: [[1]] });
  const fail = remoteRunAI({ account: 'a'.repeat(32), token: 'fake-token', fetchImpl: async () => { throw Error('fake-token private-body'); } });
  await assert.rejects(fail('@cf/baai/bge-m3', {}), /^Error: evaluation_inference_failed$/);
  const large = remoteRunAI({ account: 'a'.repeat(32), token: 'fake-token', fetchImpl: async () => new Response('x'.repeat(8 * 1024 * 1024 + 1)) });
  await assert.rejects(large('@cf/baai/bge-m3', {}), /^Error: evaluation_inference_failed$/);
});
test('correct golden page without the returned anchor has page recall but no strict evidence recall', async () => {
  const f = fixture();
  try {
    const anchor = 'この末尾の事実だけが質問の根拠';
    writeFileSync(join(f.root, 'pages.json'), JSON.stringify([{ pageNumber: 1, text: '光合成は植物が光を使って養分を作るしくみ。'.repeat(500) + '\n' + '末尾範囲には別の話題が記載されています。'.repeat(300) + anchor }]));
    f.data.questions[0].expectedEvidence[0][0].anchor = anchor; f.save();
    const report = await evaluateMaterials(f.load(), { runAI: async (model, input) => {
      if (model.includes('reranker')) return fakeAI(model, input);
      return { data: input.text.map(text => text.includes('末尾範囲') || text.includes(anchor) ? Array.from({ length: 1024 }, (_, i) => i === 0 ? 1 : 0) : Array(1024).fill(.1)) };
    } });
    assert.equal(report.status, 'complete'); assert.equal(report.results[0].pageRecall, 1); assert.equal(report.results[0].evidenceRecall, 0);
    assert.equal(JSON.stringify(report).includes(anchor), false);
  } finally { f.close(); }
});
test('late reranker completion is drained, separated from user-visible retrieval time', async () => {
  const f = fixture(); let completed = false;
  try {
    const report = await evaluateMaterials(f.load(), { runAI: async (model, input) => {
      if (model.includes('reranker')) { await new Promise(resolve => setTimeout(resolve, 2200)); completed = true; }
      return fakeAI(model, input);
    } });
    assert.equal(completed, true); assert.equal(report.status, 'complete'); assert.equal(report.results[0].stages.rerankCompleted, true); assert.equal(report.results[0].stages.rerankCompletedWithin2s, false);
    assert.ok(report.results[0].drainMs > 50); assert.ok(report.results[0].elapsedMs < 2200);
  } finally { f.close(); }
});

test('embedding outage is excluded from negative quality rather than counted as rejection', async () => {
 const f=fixture();
 try {
  const m=f.load();m.questions=[{id:'missing-evidence',query:'別の質問の価格',expected:'no_evidence',expectedEvidence:[]}];
  let embedded=0;
  const report=await evaluateMaterials(m,{runAI:async(model,input)=>{
   if(model.includes('bge-m3') && ++embedded>m.pageCount)throw Error('private-upstream-details');
   return fakeAI(model,input);
  }});
  assert.equal(report.status,'partial');assert.equal(report.executionFailures,1);
  assert.equal(report.results[0].qualityEligible,false);assert.equal(report.results[0].noEvidenceAccepted,null);
  assert.equal(report.results[0].executionFailure,'embedding_failed');
  assert.equal(JSON.stringify(report).includes('private-upstream-details'),false);
 }finally{f.close();}
});

test('malformed HTTP-success embedding cannot count as correct negative evidence', async () => {
 for(const malformed of [{}, {data:[[1]]}, {data:[Array(1024).fill(NaN)]}]) {
  const f=fixture();
  try {
   const m=f.load();m.questions=[{id:'missing-evidence',query:'別の質問の価格',expected:'no_evidence',expectedEvidence:[]}];let n=0;
   const report=await evaluateMaterials(m,{runAI:async(model,input)=>{
    if(model.includes('bge-m3') && ++n>m.pageCount)return malformed;
    return fakeAI(model,input);
   }});
   assert.equal(report.results[0].qualityEligible,false);assert.equal(report.results[0].noEvidenceAccepted,null);
   assert.equal(report.status,'partial');
  }finally{f.close();}
 }
});
test('raw RRF fuses keyword and vector ranks while progress contains counts only', async () => {
  const f = fixture(); const progress = [];
  try {
    f.data.sources.push({ ...f.data.sources[0], sourceId: 'source-b' });
    writeFileSync(join(f.root, 'unrelated.json'), JSON.stringify([{ pageNumber: 1, text: '地層は長い時間をかけて積み重なります。' }]));
    f.data.sources.push({ ...f.data.sources[0], sourceId: 'source-c', pagesFile: 'unrelated.json' });
    f.data.questions[0].scope = { type: 'library' }; f.save();
    const report = await evaluateMaterials(f.load(), { runAI: fakeAI, onProgress: event => progress.push(event) });
    const stage = report.results[0].stages;
    assert.equal(stage.rawRRFTop120.length, 3);
    assert.deepEqual(new Set(stage.rawRRFTop120.slice(0, 2).map(r => r.sourceHash)), new Set([hash('source-a'), hash('source-b')]));
    assert.equal(stage.rawRRFTop120[2].sourceHash, hash('source-c'));
    assert.ok(stage.rerankInputMeaning.includes('eligible'));
    assert.equal(progress.length, 4); assert.equal(progress.at(-1).completedQuestions, 1);
    for (const event of progress) assert.ok(Object.keys(event).every(key => ['phase', 'sourceNumber', 'completedPages', 'totalPages', 'calls', 'completedQuestions', 'totalQuestions'].includes(key)));
    assert.equal(JSON.stringify(report).includes('privateVectorRows'), false); assert.equal(JSON.stringify(report).includes('私有教材名'), false);
  } finally { f.close(); }
});
test('remote usage is bounded header metadata and never retains response vectors', async () => {
  const runAI = remoteRunAI({ account: 'a'.repeat(32), token: 'fake-token', fetchImpl: async () => new Response(JSON.stringify({ success: true, result: { data: [Array(1024).fill(.1)] } }), { headers: { 'cf-ai-neurons': '7.5' } }) });
  const rig = createEvaluationEnvironment({ runAI });
  try {
    await rig.env.AI.run('@cf/baai/bge-m3', { text: ['private'] }); await rig.drain();
    assert.deepEqual(rig.calls[0].usage, { neurons: 7.5, httpStatus: 200 });
    assert.equal(JSON.stringify(rig.calls).includes('private'), false); assert.equal(JSON.stringify(rig.calls).includes('data'), false);
  } finally { rig.close(); }
});
