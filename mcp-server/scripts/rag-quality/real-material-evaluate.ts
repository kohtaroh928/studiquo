// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, resolve, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { qualityEnvironment } from '../../src/rag-quality-fixture.ts';
import { accountKey, indexSource } from '../../src/rag/storage.ts';
import { retrieve } from '../../src/rag/retrieval.ts';
import { rrf, scopeFilter, validId, queryPlan } from '../../src/rag/query.ts';
const USAGE = Symbol('boundedEvaluationUsage');
import { relevanceEvidence } from '../../src/rag/relevance.ts';
import { JUDGE } from '../../src/rag/limits.ts';
export const MODELS = ['@cf/baai/bge-m3', '@cf/baai/bge-reranker-base'];
// The answerability judge is called only when RAG_JUDGE is shadow or on (set by judgeMode below).
const ALLOWED_MODELS = [...MODELS, JUDGE.model];
export const hash = (value: any) => createHash('sha256').update(value).digest('hex');
const invalid = () => { throw Error('invalid_evaluation_manifest'); };
function boundedJSON(path: any, limit: any) {
  const bytes = readFileSync(path); if (bytes.length > limit) invalid();
  try { return { bytes, data: JSON.parse(bytes.toString('utf8')) }; } catch { invalid(); }
}
// Input text stays private; only its digest and bounded identifiers leave this module.
export function loadManifest(path: any) {
  try {
    const root = dirname(realpathSync(path));
    const { bytes, data } = boundedJSON(path, 2 * 1024 * 1024);
    if (!Array.isArray(data.sources) || !data.sources.length || data.sources.length > 100 ||
        !Array.isArray(data.questions) || !data.questions.length || data.questions.length > 100) invalid();
    const seen = new Set(); let pageCount = 0;
    const sources = data.sources.map((source: any) => {
      if (!validId(source.sourceId) || seen.has(source.sourceId) || !['pdf', 'notebook'].includes(source.kind) ||
          typeof source.title !== 'string' || source.title.length > 300 || !/^[a-f0-9]{64}$/i.test(source.sourceHash ?? '') ||
          !Number.isInteger(source.totalPages) || source.totalPages < 1 || source.totalPages > 1000 ||
          (source.folderId != null && !validId(source.folderId)) || typeof source.pagesFile !== 'string') invalid();
      seen.add(source.sourceId); pageCount += source.totalPages; if (pageCount > 1000) invalid();
      const pagePath = realpathSync(resolve(root, source.pagesFile));
      const rel = relative(root, pagePath); if (rel.startsWith('..') || isAbsolute(rel)) invalid();
      const parsed = boundedJSON(pagePath, 32 * 1024 * 1024);
      if (source.pagesHash && source.pagesHash !== hash(parsed!.bytes)) invalid();
      const pages = parsed!.data; if (!Array.isArray(pages) || pages.length !== source.totalPages) invalid();
      const numbers = new Set();
      for (const p of pages) {
        if (!Number.isInteger(p.pageNumber) || p.pageNumber < 1 || p.pageNumber > source.totalPages || numbers.has(p.pageNumber) ||
            typeof p.text !== 'string' || p.text.length > 100000) invalid();
        numbers.add(p.pageNumber);
      }
      return { sourceId: source.sourceId, title: source.title, kind: source.kind, sourceHash: source.sourceHash,
        totalPages: source.totalPages, folderId: source.folderId ?? null, pages, pagesHash: hash(parsed!.bytes) };
    });
    const ids = new Set();
    for (const q of data.questions) {
      if (!validId(q.id) || ids.has(q.id) || typeof q.query !== 'string' || !q.query.trim() || q.query.length > 4000 ||
          (q.previousQuestion != null && (typeof q.previousQuestion !== 'string' || q.previousQuestion.length > 4000)) ||
          !['supported', 'no_evidence'].includes(q.expected) || !Array.isArray(q.expectedEvidence)) invalid();
      ids.add(q.id); scopeFilter(q.scope ?? { type: 'library' });
      if ((q.expected === 'supported') !== (q.expectedEvidence.length > 0) || q.expectedEvidence.length > 20) invalid();
      for (const group of q.expectedEvidence) {
        if (!Array.isArray(group) || !group.length || group.length > 20) invalid();
        for (const e of group) {
          const source = sources.find((s: any) => s.sourceId === e.sourceId);
          if (!source || !Number.isInteger(e.pageNumber) || e.pageNumber < 1 || e.pageNumber > source.totalPages) invalid();
          if (e.anchor != null && (typeof e.anchor !== 'string' || !e.anchor.trim() || e.anchor.length > 1000 || !source.pages.find((p: any) => p.pageNumber === e.pageNumber)?.text.includes(e.anchor))) invalid();
        }
      }
    }
    return { sources, questions: data.questions, manifestHash: hash(bytes), pageCount };
  } catch { invalid(); }
}
const cosine = (a: any, b: any) => {
  const norm = Math.sqrt(a.reduce((s: any, x: any) => s + x * x, 0) * b.reduce((s: any, x: any) => s + x * x, 0));
  return norm ? a.reduce((s: any, x: any, i: any) => s + x * b[i], 0) / norm : 0;
};
const provenance = (row: any) => ({ sourceHash: hash(row.source_id), pageNumber: row.page_number, chunkHash: hash(row.chunk_id) });
export function createEvaluationEnvironment({ runAI, maxCalls = 500, judgeMode }: any = {}) {
  if (typeof runAI !== 'function' || !Number.isInteger(maxCalls) || maxCalls < 1 || maxCalls > 500) throw Error('invalid_evaluation_options');
  const env = qualityEnvironment(); const db = env.ADMIN_DB.db;
  if (judgeMode === 'shadow' || judgeMode === 'on') env.RAG_JUDGE = judgeMode;
  const calls: any[] = []; const pending = new Set(); const vectorTraces = new WeakMap(); let trace: any = null; let budgetExhausted = false;
  const prepare = env.ADMIN_DB.prepare;
  env.ADMIN_DB.prepare = sql => ({ bind(...args) {
    const stmt = prepare(sql).bind(...args); const owner = trace;
    return { ...stmt, async all() {
      const out = await stmt.all(); if (owner && sql.includes('bm25(')) { owner.keyword.push(out.results.map(provenance));
        (owner.privateKeywordRows ??= []).push(out.results.map((r,i)=>({...r,keywordRank:i+1}))); } return out;
    } };
  } });
  env.AI.run = async (model, input) => {
    if (!ALLOWED_MODELS.includes(model) || (model === JUDGE.model && !env.RAG_JUDGE)) throw Error('evaluation_invalid_model');
    if (calls.length >= maxCalls) { budgetExhausted = true; throw Error('evaluation_budget_exhausted'); }
    const owner = trace; const entry = { model, phase: owner ? 'search' : 'index', status: 'pending' }; calls.push(entry);
    if (owner && model === MODELS[1]) {
      owner.rerankInput = input.contexts.map((c: any) => {
        let candidate; try { candidate = JSON.parse(c.text); } catch { return { ambiguous: true, candidates: [] }; }
        // Duplicate text is represented by every matching owner-scoped row, never LIMIT 1.
        const scoped = scopeFilter(owner.scope ?? { type: 'library' });
        const matches = db.prepare('SELECT c.* FROM rag_chunks c JOIN rag_sources s ON s.source_id=c.source_id AND s.account_key=c.account_key WHERE c.account_key=? AND c.ready=1 AND s.deleted=0 AND s.complete=1 AND c.text=? AND s.title=? AND COALESCE(c.heading_context,\'\')=?' + scoped.sql)
          .all(owner.accountKey, candidate.text, candidate.title, candidate.headings ?? '', ...scoped.args);
        return { ambiguous: matches.length !== 1, candidates: matches.map(provenance) };
      });
    }
    const start = performance.now();
    const task = Promise.resolve().then(() => runAI(model, input)).then(result => {
      if (model === MODELS[0] && (!Array.isArray(result?.data) || !Array.isArray(input.text) || result.data.length !== input.text.length ||
          result.data.some((v: any) => !Array.isArray(v) || v.length !== 1024 || v.some(x => !Number.isFinite(x))))) {
        entry.status = 'failed'; throw Error('evaluation_invalid_embedding');
      }
      entry.status = 'success';
      if (result?.[USAGE]) entry.usage = { ...result[USAGE] };
      if (owner && model === MODELS[0]) for (const v of result?.data ?? []) vectorTraces.set(v, owner);
      if (owner && model === JUDGE.model) owner.judgeProbability = result?.answers?.answerable?.noul ?? null;
      if (owner && model === MODELS[1]) {
        owner.rerankCompleted = true;
        owner.rerankCompletedWithin2s = performance.now() - start < 2000;
        owner.rerankOutput = (Array.isArray(result?.response) ? result.response : [])
          .filter((row: any) => Number.isInteger(row.id) && row.id >= 0 && row.id < owner.rerankInput.length && Number.isFinite(row.score))
          .map((row: any) => ({ inputIndex: row.id, score: row.score, ...owner.rerankInput[row.id] }));
      }
      return result;
    }, () => { entry.status = 'failed'; throw Error('evaluation_inference_failed'); })
      .finally(() => { entry.elapsedMs = Math.round(performance.now() - start); pending.delete(task); });
    pending.add(task); return task;
  };
  env.RAG_VECTORIZE.query = async (v, options) => {
    if (typeof options.filter?.accountKey !== 'string') throw Error('unscoped_vector_query');
    const matches = [...env.vectors.values()].filter(row => Object.entries(options.filter).every(([k, x]) => row.metadata[k] === x))
      .map(row => ({ id: row.id, score: cosine(v, row.values) })).sort((a, b) => b.score - a.score || a.id.localeCompare(b.id)).slice(0, options.topK);
    const owner = vectorTraces.get(v);
    if (owner) {
      const rows = matches.map((m,i) => {const row=db.prepare('SELECT c.*,s.title FROM rag_chunks c JOIN rag_sources s ON s.source_id=c.source_id AND s.account_key=c.account_key WHERE c.chunk_id=? AND c.account_key=?').get(m.id,options.filter.accountKey);return row ? {...row,vectorRank:i+1,vectorScore:m.score}:null;}).filter(Boolean);
      owner.vector.push(rows.map(provenance)); (owner.privateVectorRows ??= []).push(rows);
    }
    return { matches };
  };
  return { env, calls, get budgetExhausted() { return budgetExhausted; }, setTrace(value: any) { trace = value; }, async drain() {
    for (;;) {
      while (pending.size) await Promise.allSettled([...pending]);
      // Let the production timeout race's surviving continuation finish DB hydration.
      await new Promise(resolve => setImmediate(resolve));
      if (!pending.size) break;
    }
  }, close() { db.close(); } };
}
function allowed(citation: any, scope: any, source: any) {
  const type = scope.type ?? scope.kind;
  if (type === 'library') return true;
  if (type === 'folder') return source.folderId === scope.folderId;
  if (type === 'notebook') return citation.sourceId === (scope.sourceId ?? scope.notebookId);
  return citation.sourceId === (scope.sourceId ?? scope.notebookId) && citation.pageNumber === scope.pageNumber;
}
export async function evaluateMaterials(manifest: any, options: any) {
  const rig = createEvaluationEnvironment(options); const { env, calls } = rig;
  const progress = (value: any) => { if (typeof options?.onProgress === 'function') options.onProgress(Object.freeze(value)); };
  const session = { sub: 'private-material-evaluation' }; const key = await accountKey(session.sub);
  const report = { manifestHash: manifest.manifestHash, pageCount: manifest.pageCount,
    backend: 'local SQLite FTS5 and in-memory cosine vector search; real or injected Workers AI',
    sources: [], results: [], calls, status: 'complete' };
  try {
    for (const source of manifest.sources) {
      const { pages, pagesHash, ...base } = source; const before = calls.length;
      for (let i = 0; i < pages.length; i += 5) {
        await indexSource(env, key, { ...base, pages: pages.slice(i, i + 5) });
        progress({ phase: 'index', sourceNumber: report.sources.length + 1, completedPages: Math.min(i + 5, pages.length), totalPages: pages.length, calls: calls.length });
      }
      const embeddedCalls = calls.length - before; const repeatStart = calls.length;
      for (let i = 0; i < pages.length; i += 5) await indexSource(env, key, { ...base, pages: pages.slice(i, i + 5) });
      report.sources.push({ sourceHash: hash(source.sourceId), contentHash: source.sourceHash, pagesHash,
        pages: pages.length, uploadBatches: Math.ceil(pages.length / 5), embeddingCalls: embeddedCalls, idempotent: calls.length === repeatStart });
    }
    for (const q of manifest.questions) {
      const trace = { accountKey: key, scope: q.scope ?? { type: 'library' }, vector: [], keyword: [], rerankInput: [], rerankOutput: [], rerankCompleted: false, rerankCompletedWithin2s: null };
      rig.setTrace(trace); const callStart = calls.length; const started = performance.now();
      const hit = await retrieve(env, session, { query: q.query, previousQuestion: q.previousQuestion, scope: q.scope ?? { type: 'library' } });
      const elapsedMs = Math.round(performance.now() - started); const drainStart = performance.now();
      await rig.drain(); const drainMs = Math.round(performance.now() - drainStart); rig.setTrace(null);
      const searchCalls = calls.slice(callStart);
      const embeddingFailure = searchCalls.some(c => c.model === MODELS[0] && c.status !== 'success');
      const deadlineSuspected = elapsedMs >= 9950; // Conservative exclusion near production's 10s deadline.
      const qualityEligible = !embeddingFailure && !deadlineSuspected;
      const citations = hit.citations ?? []; const final = citations.map((c: any) => ({ sourceHash: hash(c.sourceId), pageNumber: c.pageNumber, chunkHash: hash(c.chunkId) }));
      const valid = citations.every((c: any) => {
        const row = env.ADMIN_DB.db.prepare('SELECT * FROM rag_chunks WHERE account_key=? AND source_id=? AND chunk_id=?').get(key, c.sourceId, c.chunkId);
        const source = manifest.sources.find((s: any) => s.sourceId === c.sourceId);
        return row?.page_number === c.pageNumber && source && allowed(c, q.scope ?? { type: 'library' }, source);
      });
      let references = [];
      try {
        const jsonStart = hit.context?.indexOf('\n') ?? -1;
        const parsed = jsonStart >= 0 ? JSON.parse(hit.context.slice(jsonStart + 1)) : null;
        if (Array.isArray(parsed?.untrustedReferences)) references = parsed.untrustedReferences;
      } catch { /* A missing or malformed evidence envelope cannot establish support. */ }
      const pageRecall = q.expectedEvidence.length ? q.expectedEvidence.filter((group: any) => group.some((e: any) => citations.some((c: any) => c.sourceId === e.sourceId && c.pageNumber === e.pageNumber))).length / q.expectedEvidence.length : null;
      const evidenceRecall = q.expectedEvidence.length ? q.expectedEvidence.filter((group: any) => group.some((e: any) =>
        references.some((r: any) => r.citation?.sourceId === e.sourceId && r.citation?.pageNumber === e.pageNumber &&
          typeof r.text === 'string' && (e.anchor ? r.text.includes(e.anchor) : citations.some((c: any) => c.chunkId === r.citation.chunkId)))))
        .length / q.expectedEvidence.length : null;
      const canonical = queryPlan(q.query,q.previousQuestion??'').canonicalQuery;
      // Canonical relevance only; comparison-group eligibility is applied separately by retrieve.
      const candidateSignals = rrf([...(trace.privateVectorRows??[]),...(trace.privateKeywordRows??[])],120).map((c,i)=>({
        ...provenance(c),rrfRank:i+1,vectorRank:Number.isFinite(c.vectorRank)?c.vectorRank:null,keywordRank:Number.isFinite(c.keywordRank)?c.keywordRank:null,
        ...relevanceEvidence(c,canonical)
      }));
      report.results.push({ caseHash: hash(q.id), status: hit.status ?? 'fallback', expected: q.expected,
        judge: hit.judge && hit.judge.mode !== 'off' ? { ...hit.judge, probability: trace.judgeProbability ?? null } : null,
        citationValid: valid, qualityEligible, executionFailure: embeddingFailure ? 'embedding_failed' : deadlineSuspected ? 'deadline_suspected' : null,
        rerankerFallback: searchCalls.some(c => c.model === MODELS[1] && (c.status !== 'success' || c.elapsedMs >= 2000)),
        pageRecall, evidenceRecall, noEvidenceAccepted: qualityEligible && q.expected === 'no_evidence' ? citations.length === 0 : null,
        elapsedMs, drainMs, candidateSignals, stages: { rawRRFTop120: rrf([...(trace.privateVectorRows ?? []), ...(trace.privateKeywordRows ?? [])], 120).map(provenance),
          rerankInputMeaning: 'actual eligible diverse RRF15; ambiguous text retains all matching provenance', vector: trace.vector, keyword: trace.keyword, rerankInput: trace.rerankInput, rerankOutput: trace.rerankOutput, rerankCompleted: trace.rerankCompleted, rerankCompletedWithin2s: trace.rerankCompletedWithin2s, final } });
      progress({ phase: 'search', completedQuestions: report.results.length, totalQuestions: manifest.questions.length, calls: calls.length });
    }
  } catch { report.status = 'failed'; report.error = 'evaluation_failed'; }
  finally { await rig.drain(); report.executionFailures = report.results.filter(r => !r.qualityEligible).length;
    if (report.status === 'complete' && report.executionFailures) report.status = 'partial';
    report.budgetExhausted = rig.budgetExhausted; if (rig.budgetExhausted) { report.status = 'failed'; report.error = 'evaluation_budget_exhausted'; } rig.close(); }
  return report;
}
export function remoteRunAI({ account, token, fetchImpl = fetch }: any) {
  if (!/^[a-f0-9]{32}$/i.test(account ?? '') || typeof token !== 'string' || !token) throw Error('cloudflare_auth_unavailable');
  return async (model: any, input: any) => {
    try {
      if (!ALLOWED_MODELS.includes(model)) throw Error('invalid_model');
      const res = await fetchImpl(`https://api.cloudflare.com/client/v4/accounts/${account}/ai/run/${model}`, {
        method: 'POST', redirect: 'error', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(input), signal: AbortSignal.timeout(45000),
      });
      if (!res.ok || !res.body) throw Error('inference_failed');
      const reader = res.body.getReader(); let size = 0; const chunks = [];
      try { for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.length;
        if (size > 8 * 1024 * 1024) throw Error('response_limit'); chunks.push(value); } }
      finally { await reader.cancel().catch(() => {}); }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (body.success !== true || !body.result) throw Error('inference_failed');
      const rawNeurons = res.headers.get('cf-ai-neurons');
      const neurons = rawNeurons !== null && Number.isFinite(Number(rawNeurons)) && Number(rawNeurons) >= 0 ? Number(rawNeurons) : null;
      if (body.result && typeof body.result === 'object') Object.defineProperty(body.result, USAGE, { value: { neurons, httpStatus: res.status } });
      return body.result;
    } catch { throw Error('evaluation_inference_failed'); }
  };
}
export async function main(argv = process.argv.slice(2)) {
  if (process.env.STUDIQUO_RAG_REAL_MATERIAL_REMOTE !== 'true') throw Error('remote_evaluation_opt_in_required');
  if (argv.length !== 2) throw Error('manifest_and_output_required');
  const manifest = loadManifest(argv[0]); const account = process.env.CLOUDFLARE_ACCOUNT_ID;
  let token = process.env.CLOUDFLARE_API_TOKEN;
  if (!token) {
    try { token = readFileSync(process.env.STUDIQUO_CF_AUTH_FILE ?? `${homedir()}/.wrangler/config/default.toml`, 'utf8').match(/^oauth_token\s*=\s*"([^"]+)"/m)?.[1]; }
    catch { throw Error('cloudflare_auth_unavailable'); }
  }
  const onProgress = process.env.STUDIQUO_RAG_REAL_MATERIAL_PROGRESS === 'true' ? (value: any) => process.stdout.write(JSON.stringify(value) + '\n') : undefined;
  const report = await evaluateMaterials(manifest, { runAI: remoteRunAI({ account, token }), onProgress, judgeMode: process.env.STUDIQUO_RAG_JUDGE_MODE });
  writeFileSync(argv[1], JSON.stringify(report, null, 2), { mode: 0o600 });
  if (report.status !== 'complete') process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { process.stderr.write('Real-material evaluation failed. No input or provider details are logged.\n'); process.exitCode = 1; });
}
