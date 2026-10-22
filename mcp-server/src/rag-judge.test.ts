import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { retrieve } from './rag/retrieval.ts';
import { indexSource, accountKey } from './rag/storage.ts';
import { JUDGE, LIMITS } from './rag/limits.ts';
import { EMPTY_DETAILS } from './rag/contract.ts';
import { judgeMode, judgeRequest, parseProbability, judgeAction, bucketOf, judgeAnswerable } from './rag/judge.ts';
import { handleAI } from './ai.ts';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';

const reply = (p: number) => ({ answers: { answerable: { type: 'noul', noul: p } }, usage: { input_tokens: 100, output_tokens: 0 } });
const numbered = (...texts: string[]) => texts.map((text, i) => ({ pageNumber: i + 1, text }));
const TYPHOON = numbered('台風は熱帯の海上で発生する低気圧である。台風の発生数は夏から秋に多い。', '気温の単位は摂氏である。');
const QUERY = '台風とは何ですか。';

// `judge` is the judge's answer: a probability, or a function (to throw, hang or return something odd).
async function ask(opts: { mode?: string; judge?: number | ((input: any) => any); pages?: any[]; query?: string }) {
  const env: any = qualityEnvironment();
  await indexSource(env, await accountKey('synthetic-user'), qualitySource({ totalPages: (opts.pages ?? TYPHOON).length, pages: opts.pages ?? TYPHOON }));
  if (opts.mode !== undefined) env.RAG_JUDGE = opts.mode;
  const judgeCalls: any[] = [];
  const run = env.AI.run;
  env.AI.run = async (model: any, input: any) => {
    if (model !== JUDGE.model) return run(model, input);
    judgeCalls.push(input);
    return typeof opts.judge === 'function' ? opts.judge(input) : reply(opts.judge ?? 0.9);
  };
  const hit: any = await retrieve(env, { sub: 'synthetic-user' }, { query: opts.query ?? QUERY });
  return { hit, judgeCalls, env };
}

test('the judge settings are pinned and frozen', () => {
  assert.deepEqual({ ...JUDGE }, { model: '@cf/cloudflare/clef-flash', calls: 1, timeoutMs: 2000, minRemainingMs: 3000,
    excerptChars: 3000, totalChars: 9000, stopBelow: 0.25, partialBelow: 0.5 });
  assert.ok(Object.isFrozen(JUDGE));
  assert.ok(JUDGE.timeoutMs + 1000 <= JUDGE.minRemainingMs && JUDGE.minRemainingMs < LIMITS.retrievalTimeoutMs);
  assert.ok(EMPTY_DETAILS.includes('judged_unanswerable'));
});

test('the judge is off unless RAG_JUDGE says shadow or on, in every environment of wrangler.jsonc', () => {
  assert.equal(judgeMode({}), 'off');
  assert.equal(judgeMode({ RAG_JUDGE: 'ON ' }), 'on');
  assert.equal(judgeMode({ RAG_JUDGE: 'shadow' }), 'shadow');
  for (const odd of ['true', '1', 'enforce', '', undefined, null]) assert.equal(judgeMode({ RAG_JUDGE: odd }), 'off', String(odd));
  const config = readFileSync(join(import.meta.dirname, '..', 'wrangler.jsonc'), 'utf8');
  assert.equal((config.match(/"RAG_JUDGE"\s*:\s*"off"/g) ?? []).length, 2);
  assert.equal((config.match(/"RAG_JUDGE"/g) ?? []).length, 2);
});

test('the request carries the question and the excerpts only, cut to a bounded size', () => {
  const long = 'あ'.repeat(5000);
  const { body, truncated } = judgeRequest('質問', [long, long, long, long]);
  assert.equal(truncated, true);
  assert.deepEqual(Object.keys(body).sort(), ['model', 'questions', 'state']);
  assert.deepEqual(Object.keys(body.state).sort(), ['excerpts', 'question']);
  assert.equal(body.state.excerpts[0].length, JUDGE.excerptChars);
  assert.equal(body.state.excerpts.reduce((n: number, t: string) => n + t.length, 0), JUDGE.totalChars);
  assert.equal(body.questions.answerable.type, 'noul');
  assert.equal(judgeRequest('質問', ['短い抜粋']).truncated, false);
});

test('only a probability between 0 and 1 is accepted', () => {
  assert.equal(parseProbability(reply(0.42)), 0.42);
  assert.equal(parseProbability(reply(0)), 0);
  for (const bad of [null, {}, { answers: {} }, { answers: { answerable: { noul: '0.3' } } }, reply(1.2), reply(-0.1), reply(NaN)]) assert.equal(parseProbability(bad), null);
});

test('thresholds: a single subject is stopped, then demoted; a comparison is never stopped', () => {
  assert.equal(judgeAction(0.0, true), 'stop');
  assert.equal(judgeAction(0.249, true), 'stop');
  assert.equal(judgeAction(0.25, true), 'partial');
  assert.equal(judgeAction(0.499, true), 'partial');
  assert.equal(judgeAction(0.5, true), 'keep');
  assert.equal(judgeAction(0.0, false), 'partial');
  assert.equal(judgeAction(0.4, false), 'partial');
  assert.equal(judgeAction(0.9, false), 'keep');
  assert.equal(bucketOf(0.87), '0.8');
  assert.equal(bucketOf(0.05), '0.0');
});

test('a judge that does not answer in time, or fails, or is not there ends as an outcome code and keeps the evidence', async (t) => {
  const base = { question: '質問', excerpts: ['抜粋'], single: true, remainingMs: 9000 };
  const on = (ai: any) => ({ RAG_JUDGE: 'on', AI: ai });
  const failed = await judgeAnswerable(on({ run: async () => { throw new Error('boom'); } }), base);
  assert.deepEqual([failed.outcome, failed.action, failed.called], ['error', 'keep', true]);
  const odd = await judgeAnswerable(on({ run: async () => ({ answers: {} }) }), base);
  assert.deepEqual([odd.outcome, odd.action], ['error', 'keep']);
  assert.equal((await judgeAnswerable({ RAG_JUDGE: 'on' }, base)).outcome, 'skipped');
  assert.equal((await judgeAnswerable(on({ run: async () => reply(0) }), { ...base, remainingMs: JUDGE.minRemainingMs - 1 })).outcome, 'skipped');
  assert.equal((await judgeAnswerable(on({ run: async () => reply(0) }), { ...base, excerpts: [] })).outcome, 'skipped');
  assert.deepEqual([(await judgeAnswerable({ RAG_JUDGE: 'off', AI: { run: async () => { throw new Error('never'); } } }, base)).outcome], ['off']);
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const pending = judgeAnswerable(on({ run: () => new Promise(() => {}) }), base);
  t.mock.timers.tick(JUDGE.timeoutMs);
  const timedOut = await pending;
  assert.deepEqual([timedOut.outcome, timedOut.action, timedOut.called], ['timeout', 'keep', true]);
});

test('off (the default) never calls the judge and changes nothing', async () => {
  const { hit, judgeCalls } = await ask({ mode: undefined, judge: 0 });
  assert.equal(judgeCalls.length, 0);
  assert.equal(hit.status, 'grounded');
  assert.equal(hit.citations.length > 0, true);
  assert.equal(hit.judge.outcome, 'off');
  const explicit = await ask({ mode: 'off', judge: 0 });
  assert.equal(explicit.judgeCalls.length, 0);
});

test('shadow calls the judge once and only records what it said', async () => {
  const { hit, judgeCalls } = await ask({ mode: 'shadow', judge: 0.05 });
  assert.equal(judgeCalls.length, 1);
  assert.equal(hit.status, 'grounded');
  assert.ok(hit.citations.length > 0);
  assert.deepEqual([hit.judge.mode, hit.judge.outcome, hit.judge.bucket, hit.judge.action], ['shadow', 'ok', '0.0', 'stop']);
  assert.equal(judgeCalls[0].state.question, QUERY);
  assert.ok(judgeCalls[0].state.excerpts.length > 0);
});

test('on: a low probability stops a single-subject question, a middle one demotes it, a high one keeps it', async () => {
  const stopped = await ask({ mode: 'on', judge: 0.05 });
  assert.equal(stopped.hit.status, 'insufficient');
  assert.equal(stopped.hit.reason, 'insufficient');
  assert.equal(stopped.hit.detail, 'judged_unanswerable');
  assert.deepEqual(stopped.hit.citations, []);
  assert.equal(stopped.hit.context, '');
  assert.equal(stopped.hit.judge.action, 'stop');
  const doubtful = await ask({ mode: 'on', judge: 0.3 });
  assert.equal(doubtful.hit.status, 'partial');
  assert.ok(doubtful.hit.citations.length > 0);
  const answered = await ask({ mode: 'on', judge: 0.9 });
  assert.equal(answered.hit.status, 'grounded');
  assert.ok(answered.hit.citations.length > 0);
});

test('on: a comparison with a low probability is demoted to partial, never stopped', async () => {
  const pages = numbered('ポーラーロウは、冬季に寒帯前線の寒気側の海上に発生する低気圧である。', '上層寒冷低気圧は、対流圏では中心付近に寒気を持つことが特徴である。');
  const { hit } = await ask({ mode: 'on', judge: 0.02, pages, query: 'ポーラーロウと上層寒冷低気圧は、どこで発生し、どんな温度の特徴がありますか。' });
  assert.equal(hit.status, 'partial');
  assert.ok(hit.citations.length > 0);
  assert.equal(hit.judge.action, 'partial');
});

test('on: when the judge fails the evidence stays, whatever way it fails', async () => {
  for (const judge of [() => { throw new Error('unavailable'); }, () => ({}), () => ({ answers: { answerable: { noul: 7 } } }), () => null]) {
    const { hit } = await ask({ mode: 'on', judge });
    assert.equal(hit.status, 'grounded');
    assert.ok(hit.citations.length > 0);
    assert.equal(hit.judge.outcome, 'error');
  }
});

test('the judge is one more Workers AI call and is counted', async () => {
  const off = await ask({ mode: 'off' });
  const shadow = await ask({ mode: 'shadow', judge: 0.9 });
  assert.equal(shadow.hit.aiCalls, off.hit.aiCalls + 1);
  assert.equal(JUDGE.calls, 1);
});

test('the retrieval log line carries the judge outcome and bucket, and none of the question or document text', async () => {
  const original = globalThis.fetch;
  const log = console.log;
  const lines: string[] = [];
  globalThis.fetch = async () => new Response('data: {"type":"response.output_text.delta","delta":"x"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
  try {
    const environment: any = qualityEnvironment();
    Object.assign(environment, { OPENAI_LUNA_MODEL: 'gpt-test-luna', AI_MODERATION: 'off', OPENAI_API_KEY: 'test-placeholder', RAG_JUDGE: 'shadow',
      STUDIQUO_DATA: { async get() { return null; }, async put() {} },
      RATE_COUNTER: { getByName: () => ({ async bump() { return true; }, async take() { return { ok: true, windowEndsAt: 1 }; }, async give() {} }) } });
    await indexSource(environment, await accountKey('canonical-owner'), qualitySource({ totalPages: TYPHOON.length, pages: TYPHOON }));
    const run = environment.AI.run;
    environment.AI.run = async (model: any, input: any) => (model === JUDGE.model ? reply(0.62) : run(model, input));
    console.log = (line: any) => { lines.push(String(line)); };
    const pending: Promise<unknown>[] = [];
    const request = new Request('https://example.test/api/ai/chat', { method: 'POST', headers: { 'content-type': 'application/json', 'X-Studiquo-RAG-Consent': 'rag-openai-v1' },
      body: JSON.stringify({ messages: [{ role: 'user', text: QUERY }], rag: { scope: { kind: 'library' } } }) });
    const response = await handleAI(new URL(request.url), request, environment, 'test-device', { waitUntil: (p: Promise<unknown>) => pending.push(p) } as unknown as ExecutionContext, { sub: 'canonical-owner' }, 'standard');
    await response!.text(); await Promise.all(pending);
    console.log = log;
    const entry = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).find(e => e?.event === 'rag_retrieval');
    assert.ok(entry);
    assert.deepEqual(entry.judge, { mode: 'shadow', outcome: 'ok', bucket: '0.6', action: 'keep' });
    const text = lines.join('\n');
    for (const secret of ['台風とは', '熱帯の海上', '摂氏']) assert.ok(!text.includes(secret), secret);
  } finally { console.log = log; globalThis.fetch = original; }
});
