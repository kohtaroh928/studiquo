import test from 'node:test';
import assert from 'node:assert/strict';
import { structuredOutputJSONSchema as schema, parseStructuredOutput as parse, MAX_STRUCTURED_OUTPUT_BYTES } from './ai-output-validation.js';
import { handleAI } from './ai.js';

const examples = {
  rubric: { criteria: [{ name: 'synthetic', maxPoints: 100, requirement: 'synthetic' }] },
  grade: { score: 80, maxScore: 100, verdict: 'synthetic', criteria: [{ name: 'synthetic', earnedPoints: 80, maxPoints: 100, comment: 'synthetic' }], issues: [{ step: 1, kindRawValue: 'presentation', excerpt: 'synthetic', explanation: 'synthetic', suggestion: 'synthetic' }] },
  review: { isStudyRelevant: true, explanationMarkdown: 'synthetic', quiz: [{ question: 'synthetic', answer: 'synthetic' }] },
};
test('Zod retains all valid existing response fields without mutation', () => {
  for (const [name, value] of Object.entries(examples)) assert.deepEqual(parse(name, JSON.stringify(value)), value);
  assert.deepEqual(parse('review', '{"isStudyRelevant":false,"explanationMarkdown":"","quiz":[]}'), { isStudyRelevant: false, explanationMarkdown: '', quiz: [] });
});
test('Zod rejects missing, extra and nested extra fields, invalid enum and coercion', () => {
  for (const [name, example] of Object.entries(examples)) {
    for (const value of [null, [], {}, { ...example, extra: true }]) assert.throws(() => parse(name, JSON.stringify(value)), /invalid_structured_output/);
    const missing = structuredClone(example); delete missing[Object.keys(missing)[0]];
    assert.throws(() => parse(name, JSON.stringify(missing)));
  }
  const bad = structuredClone(examples.grade); bad.issues[0].kindRawValue = 'invented';
  assert.throws(() => parse('grade', JSON.stringify(bad)));
  bad.issues[0].kindRawValue = 'presentation'; bad.criteria[0].earnedPoints = '80';
  assert.throws(() => parse('grade', JSON.stringify(bad)));
  assert.throws(() => parse('review', JSON.stringify({ ...examples.review, quiz: [{ ...examples.review.quiz[0], extra: 'not silently removed' }] })));
  assert.throws(() => parse('grade', JSON.stringify({ ...examples.grade, score: 1.5 })));
});
test('Zod errors never echo raw content and byte limits do not truncate multibyte input', () => {
  const raw = JSON.stringify({ ...examples.review, extra: 'synthetic-sensitive-marker' });
  try { parse('review', raw); assert.fail(); } catch (e) { assert.equal(e.message, 'invalid_structured_output'); assert.equal(e.cause, undefined); }
  assert.throws(() => parse('review', JSON.stringify({ ...examples.review, explanationMarkdown: 'あ'.repeat(MAX_STRUCTURED_OUTPUT_BYTES / 2) })));
  for (const raw of ['{', '```json\n{}\n```', undefined]) assert.throws(() => parse('review', raw));
  assert.throws(() => parse('unknown', '{}')); assert.throws(() => schema('unknown'));
});
test('Zod wire preserves existing public shape, integer type and enum without new range constraints', () => {
  const r = schema('rubric'), g = schema('grade'), v = schema('review');
  assert.deepEqual(r.required, ['criteria']); assert.deepEqual(g.required, ['score', 'maxScore', 'verdict', 'criteria', 'issues']);
  assert.deepEqual(v.required, ['isStudyRelevant', 'explanationMarkdown', 'quiz']);
  assert.deepEqual(g.properties.score, { type: 'integer' });
  assert.deepEqual(g.properties.issues.items.properties.kindRawValue.enum, ['logical_gap', 'counterexample', 'definition_error', 'calculation_error', 'unjustified_assumption', 'presentation']);
  function check(s) { if (s.type === 'object') { assert.equal(s.additionalProperties, false); assert.deepEqual(s.required, Object.keys(s.properties)); Object.values(s.properties).forEach(check); } if (s.items) check(s.items); }
  [r,g,v].forEach(check);
  v.properties.quiz.items.properties.question.type = 'number';
  assert.equal(schema('review').properties.quiz.items.properties.question.type, 'string');
});

async function run(path, result, { refusal = false, complete = true, splitBytes = false, malformed = false } = {}) {
  const original = globalThis.fetch;
  let refunds = 0, calls = 0;
  const reserved = [], returned = [];
  const binding = { getByName: name => ({ async take(_limit, _window, amount) { reserved.push({name, amount}); return { ok: true, windowEndsAt: 1 }; }, async give(amount) { refunds++; returned.push({name, amount}); } }) };
  globalThis.fetch = async url => {
    if (String(url).includes('/moderations')) return Response.json({ results: [{ flagged: false }] });
    calls++;
    const events = [{ type: 'response.output_text.delta', delta: result }];
    if (refusal) events.push({ type: 'response.refusal.delta', delta: 'synthetic refusal' });
    if (complete) events.push({ type: 'response.completed', response: { status: 'completed' } });
    const text = (malformed ? 'data: {broken\n\n' : '') + events.map(e => `data: ${JSON.stringify(e)}\n\n`).join('');
    if (!splitBytes) return new Response(text);
    const bytes = new TextEncoder().encode(text);
    return new Response(new ReadableStream({ start(controller) {
      for (let i = 0; i < bytes.length; i += 3) controller.enqueue(bytes.slice(i, i + 3));
      controller.close();
    } }));
  };
  try {
    const payloads = { rubric: { question: 'synthetic' }, grade: { answerText: 'synthetic', criteria: [{ name: 'synthetic', maxPoints: 100, requirement: 'synthetic' }] }, review: { question: 'synthetic' } };
    const env = { OPENAI_API_KEY: 'synthetic', OPENAI_LUNA_MODEL: 'synthetic', RATE_COUNTER: binding };
    const promises = [], ctx = { waitUntil(p) { promises.push(p); } };
    const request = new Request(`https://example.test/api/ai/${path}`, { method: 'POST', body: JSON.stringify(payloads[path]) });
    const response = await handleAI(new URL(request.url), request, env, 'synthetic-device', ctx, { sub: 'synthetic-account' }, 'standard');
    const text = await response.text(); await Promise.all(promises);
    return { text, refunds, calls, reserved, returned };
  } finally { globalThis.fetch = original; }
}
test('all three live structured routes withhold wrong shape and refund the credit reservation once', async () => {
  for (const name of Object.keys(examples)) {
    const good = await run(name, JSON.stringify(examples[name]));
    assert.match(good.text, /"result":/); assert.equal(good.refunds, 0); assert.equal(good.calls, 1);
    const bad = await run(name, JSON.stringify({ ...examples[name], unexpected: true }));
    assert.match(bad.text, /"error":/); assert.doesNotMatch(bad.text, /"result":/); assert.equal(bad.calls, 1);
    // Every account/global allowance is returned exactly once, with its reserved amount.
    assert.equal(bad.refunds, bad.reserved.length);
    assert.deepEqual(bad.returned, bad.reserved);
  }
});
test('valid JSON is not delivered after a refusal, incomplete response or output size overflow', async () => {
  for (const options of [{ refusal: true }, { complete: false }, {}]) {
    const raw = Object.keys(options).length ? JSON.stringify(examples.review) : JSON.stringify({ ...examples.review, explanationMarkdown: 'x'.repeat(MAX_STRUCTURED_OUTPUT_BYTES + 1) });
    const result = await run('review', raw, options);
    assert.match(result.text, /"error":/); assert.doesNotMatch(result.text, /"result":/); assert.equal(result.refunds, result.reserved.length); assert.deepEqual(result.returned, result.reserved); assert.equal(result.calls, 1);
  }
});
test('SSE boundaries and multibyte Japanese can span chunks, while malformed events remain failures', async () => {
  const value = { ...examples.review, explanationMarkdown: '合成テスト：電圧と抵抗。' };
  const good = await run('review', JSON.stringify(value), { splitBytes: true });
  const result = good.text.split('\n').filter(line => line.startsWith('data:')).map(line => JSON.parse(line.slice(5))).find(e => e.result);
  assert.deepEqual(result.result, value); assert.equal(good.refunds, 0);
  const bad = await run('review', JSON.stringify(value), { splitBytes: true, malformed: true });
  assert.match(bad.text, /"error":/); assert.doesNotMatch(bad.text, /"result":/);
  assert.deepEqual(bad.returned, bad.reserved); assert.equal(bad.calls, 1);
});
