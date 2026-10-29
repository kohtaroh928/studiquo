// @ts-nocheck -- offline capture script, same style as mcp-server/scripts/rag-quality.
// Builds extra-cases/contexts-extra.json and manifest-extra.json from extra-cases/cases.json by running the
// real handleAI against a local synthetic D1/vector store with a mocked OpenAI endpoint. No network, no key.
import {readFileSync, writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {handleAI} from '../../mcp-server/src/ai.ts';
import {accountKey, indexSource} from '../../mcp-server/src/rag/storage.ts';
import {qualityEnvironment, qualitySource} from '../../mcp-server/src/rag-quality-fixture.ts';
import {sseEvents} from '../../mcp-server/scripts/rag-quality/final-answer-evaluate.ts';
import {loadPromptBaseline} from '../../mcp-server/scripts/rag-quality/prompt-baseline.ts';
import {ragAnswerPolicy as frozenPolicy} from '../../mcp-server/scripts/rag-quality/baselines/20261014-policy-v1/answer-policy.ts';

// `node capture-extra-cases.ts [extra|fresh]` reads <set>-cases/cases.json and writes contexts-<set>.json / manifest-<set>.json.
const setName = process.argv[2] === 'fresh' ? 'fresh' : 'extra';
const dir = path.join(fileURLToPath(new URL('./', import.meta.url)), `${setName}-cases`);
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const nonempty = s => typeof s === 'string' && s.trim().length > 0;

export function validateCases(cases) {
  const keys = new Set();
  if (!Array.isArray(cases) || !cases.length) throw Error('invalid_cases');
  for (const c of cases) {
    if (!new RegExp(`^(extra|fresh):[a-z][a-z0-9-]{0,40}$`).test(c.key) || keys.has(c.key) || !nonempty(c.question) ||
        !['grounded', 'partial', 'none'].includes(c.expectedStatus) ||
        !Array.isArray(c.pages) || !c.pages.length || c.pages.some((p, i) => p.pageNumber !== i + 1 || !nonempty(p.text)) ||
        (c.history ?? []).some(h => !['user', 'assistant'].includes(h.role) || !nonempty(h.text))) throw Error('invalid_cases');
    keys.add(c.key);
  }
  return cases;
}

export async function capture(cases) {
  const original = globalThis.fetch, rows = [];
  try {
    for (const c of cases) {
      const env = qualityEnvironment(), pending = [];
      const owner = 'synthetic-answer-owner', key = await accountKey(owner), sourceId = c.key.replace(':', '-');
      Object.assign(env, {OPENAI_API_KEY: 'synthetic-capture-key', OPENAI_LUNA_MODEL: 'gpt-6-luna', AI_MODERATION: 'off',
        RATE_COUNTER: {getByName: () => ({bump: async () => true, take: async () => ({ok: true, windowEndsAt: 1}), give: async () => {},
          reserve: async () => ({ok: true, windowEndsAt: 1}), release: async () => true})}});
      try {
        await indexSource(env, key, qualitySource({sourceId, title: '合成教材 追加ケース', pages: c.pages, totalPages: c.pages.length}));
        let body, calls = 0;
        globalThis.fetch = async (url, options) => {
          if (url !== 'https://api.openai.com/v1/responses' || ++calls !== 1) throw Error('unexpected_capture_request');
          body = JSON.parse(options.body);
          return new Response('data: {"type":"response.output_text.delta","delta":"synthetic capture"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
        };
        const request = new Request('https://example.test/api/ai/chat', {method: 'POST', headers: {'content-type': 'application/json',
          'X-Studiquo-AI-Consent': 'openai-v1', 'X-Studiquo-Age': 'adult', 'X-Studiquo-RAG-Consent': 'rag-openai-v1'},
          body: JSON.stringify({messages: [...(c.history ?? []), {role: 'user', text: c.question}], model: 'openai-luna',
            rag: {scope: {kind: 'notebook', sourceId}, answerStyle: 'source_only'}})});
        const response = await handleAI(new URL(request.url), request, env, 'synthetic-capture-device', {waitUntil: p => pending.push(p)}, {sub: owner}, 'standard');
        const events = sseEvents(await response.text()); await Promise.all(pending.splice(0));
        const status = events.find(e => e.ragStatus)?.ragStatus, citations = events.flatMap(e => e.citations ?? []);
        if (!response.ok || calls !== 1 || !body) throw Error('no_model_request:' + c.key + ':' + status);
        const policy = frozenPolicy(status, 'source_only');
        if (!body.instructions.endsWith(policy) || body.model !== 'gpt-6-luna' || body.store !== false || body.stream !== true ||
            body.max_output_tokens !== 8192 || body.tools !== undefined || body.previous_response_id !== undefined) throw Error('capture_mismatch:' + c.key);
        body.reasoning = {effort: 'medium'}; body.service_tier = 'default';
        if (Buffer.byteLength(JSON.stringify(body)) > 24576) throw Error('capture_size_limit:' + c.key);
        rows.push({key: c.key, status, body, baseInstructions: body.instructions.slice(0, -policy.length), citations});
      } finally {globalThis.fetch = original; await Promise.allSettled(pending); env.ADMIN_DB.db.close();}
    }
  } finally {globalThis.fetch = original;}
  return rows;
}

export function writeCaseSet(outDir, contexts, suffix = setName) {
  const {manifest} = loadPromptBaseline();
  writeFileSync(path.join(outDir, `contexts-${suffix}.json`), JSON.stringify(contexts, null, 1) + '\n');
  writeFileSync(path.join(outDir, `manifest-${suffix}.json`), JSON.stringify({version: 1, syntheticOnly: true, baselineId: manifest.id,
    caseKeys: contexts.map(r => r.key), statuses: Object.fromEntries(contexts.map(r => [r.key, r.status])), contextsHash: hash(contexts)}, null, 1) + '\n');
  return hash(contexts);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const cases = validateCases(JSON.parse(readFileSync(path.join(dir, 'cases.json'), 'utf8')));
    const contexts = await capture(cases);
    const contextsHash = writeCaseSet(dir, contexts);
    // The status is whatever production decides; a difference from the author's expectation is reported, not hidden.
    const differs = contexts.filter((r, i) => r.status !== cases[i].expectedStatus).map((r, i) => r.key + ':' + r.status);
    console.log(JSON.stringify({cases: contexts.length, contextsHash, statusDiffersFromExpected: differs}));
  } catch (error) {
    console.error('capture_extra_cases_failed: ' + String(error.message).slice(0, 120));
    process.exitCode = 1;
  }
}
