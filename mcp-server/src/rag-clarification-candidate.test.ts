// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { buildClarificationCandidateRequest as build, parseClarificationCandidateResponse as parse } from '../scripts/rag-quality/clarification-candidate.ts';
import { clarificationInputBinding } from '../scripts/rag-quality/clarification-decision.ts';
const read = f => JSON.parse(fs.readFileSync(new URL('../scripts/rag-quality/' + f, import.meta.url), 'utf8'));
const inputs = read('clarification-inputs-v1.json').cases;
const oracle = read('clarification-oracle-v1.json').cases;
function sample(id = 'clarify-named-fee') {
  const input = inputs.find(c => c.id === id).input, o = oracle.find(c => c.id === id);
  const decision = { version: 1, inputHash: clarificationInputBinding(JSON.stringify(input)).inputHash, technicalState: o.technicalState,
    decisions: o.requirements.map((r,i) => ({ id: `d${i+1}`, requestLabel: r.requestLabel, requestRefs: ['q'], ...r.allowed[0], targetRefs: r.requiredTargetRefs })) };
  return { input: structuredClone(input), decision: structuredClone(decision) };
}
const response = value => ({ object: 'response', status: 'completed', model: 'gpt-6-luna', error: null, incomplete_details: null,
  usage: { input_tokens: 100, output_tokens: 60, total_tokens: 160, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 20 } },
  output: [{ type: 'reasoning', summary: [] }, { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: JSON.stringify(value), annotations: [] }] }] });
const run = s => parse(JSON.stringify(s.input), JSON.stringify(response(s.decision)));
test('Zod candidate request accepts input only and contains no local evaluation metadata', () => {
  for (const c of inputs) {
    const raw = JSON.stringify(c.input), b = build(raw), user = JSON.parse(b.input[1].content);
    assert.deepEqual(user, { inputHash: clarificationInputBinding(raw).inputHash, input: c.input });
    assert.equal(b.model, 'gpt-6-luna'); assert.equal(b.store, false); assert.equal(b.stream, false);
    assert.deepEqual(b.reasoning, { effort: 'medium' }); assert.equal(b.service_tier, 'default'); assert.equal(b.max_output_tokens, 4096);
    assert.equal(b.tools, undefined); assert.equal(b.previous_response_id, undefined);
    assert.deepEqual(b, build(raw));
    assert.throws(() => build(JSON.stringify(c)));
    assert.throws(() => build(raw, c.harness));
    for (const name of ['oracle', 'harness', 'review', 'matrix', 'rationale']) assert.equal(Object.hasOwn(user, name), false);
  }
  const text = fs.readFileSync(new URL('../scripts/rag-quality/clarification-candidate.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(text, /from\s+['"][^'"]*(?:oracle|semantic-review|fs|http)/);
});
test('wire schema is strict and input-bound, with only available target refs', () => {
  const s = sample('clarify-withheld-context'), schema = build(JSON.stringify(s.input)).text.format.schema;
  const ref = schema.properties.decisions.items.properties.targetRefs.items;
  const values = ref.enum ?? [ref.const];
  assert.deepEqual(values, ['q']); assert.equal(schema.additionalProperties, false);
  assert.deepEqual(schema.required, Object.keys(schema.properties));
  assert.equal(schema.properties.decisions.items.additionalProperties, false);
  assert.deepEqual(schema.properties.technicalState.enum, ['ok']);
});
test('28 semantic fixtures pass both Zod and frozen validator; technical fixtures are not model pass', () => {
  let count = 0;
  for (const c of inputs) {
    const s = sample(c.id);
    if (c.harness.technicalState !== 'ok') { assert.throws(() => run(s)); continue; }
    count++;
    const result = run(s);
    assert.deepEqual(result.decision, s.decision); assert.equal(result.semantics, 'pending');
    assert.equal(result.authorizationVerified, false); assert.equal(result.releaseAccepted, false);
  }
  assert.equal(count, 28);
});
test('candidate rejects shape/coercion, wrong hash, non-ok self report, and cross-field conflict', () => {
  for (const mutate of [
    s => s.decision.extra = true,
    s => s.decision.version = '1',
    s => s.decision.inputHash = '0'.repeat(64),
    s => { s.decision.technicalState = 'failed'; s.decision.decisions = []; },
    s => s.decision.decisions[0].nextAction = 'clarify_target',
    s => s.decision.decisions[0].targetRefs = ['c16'],
    s => s.decision.decisions[0].requestLabel = 'x'.repeat(257),
    s => s.decision.decisions[0].evidenceState = 'supported',
  ]) { const s = sample(); mutate(s); assert.throws(() => run(s), /invalid_clarification_candidate/); }
});
test('provider refusal, incomplete, wrong role/status, tools and multiple texts are not candidates', () => {
  for (const mutate of [
    r => r.status = 'incomplete',
    r => r.output[1].role = 'user',
    r => r.output[1].status = 'in_progress',
    r => r.output.push(structuredClone(r.output[1])),
    r => r.output[1].content.push(structuredClone(r.output[1].content[0])),
    r => r.output[1].content = [{ type: 'refusal', refusal: 'synthetic' }],
    r => r.output.push({ type: 'function_call', name: 'synthetic' }),
    r => r.output = [],
    r => r.output[1].content[0].text = '```json\n{}\n```',
  ]) {
    const s = sample(), r = response(s.decision); mutate(r);
    assert.throws(() => parse(JSON.stringify(s.input), JSON.stringify(r)), /invalid_clarification_candidate/);
  }
});
test('candidate rejects oversized data, wrong arity and does not expose payload in errors', () => {
  const s = sample(), input = JSON.stringify(s.input);
  for (const raw of [null, '{synthetic-sensitive-marker', ' '.repeat(262145)]) {
    assert.throws(() => parse(input, raw), { message: 'invalid_clarification_candidate' });
  }
  assert.throws(() => parse(input)); assert.throws(() => parse(input, '{}', {}));
  assert.throws(() => build('{}')); assert.throws(() => build(input, {}));
  const before = build(input); before.input[1].content = 'changed'; assert.notEqual(build(input).input[1].content, 'changed');
});
test('candidate rejects contradictory completed envelopes and invalid usage without hiding failures', () => {
  for (const mutate of [
    r => r.object = 'not_response', r => r.model = 'another_model', r => r.error = { code: 'synthetic' },
    r => r.incomplete_details = { reason: 'max_output_tokens' }, r => r.output[0].status = 'failed',
    r => r.output[0].status = 'in_progress', r => delete r.error, r => delete r.usage,
    r => r.usage.total_tokens++, r => r.usage.output_tokens_details.reasoning_tokens = 61,
    r => r.usage.input_tokens_details.cached_tokens = 101, r => r.usage.output_tokens = 4097,
    r => r.usage.input_tokens = -1, r => r.usage.input_tokens_details = { unknown: 1 },
    r => r.usage.input_tokens_details = { cached_tokens: 60, cache_write_tokens: 60 },
  ]) {
    const s = sample(), r = response(s.decision); mutate(r);
    assert.throws(() => parse(JSON.stringify(s.input), JSON.stringify(r)), /invalid_clarification_candidate/);
  }
  const result = run(sample());
  assert.deepEqual(result.usage, { input: 100, output: 60, total: 160, reasoning: 20, cached: 0, cacheWrite: null });
  assert.match(result.requestHash, /^[a-f0-9]{64}$/); assert.match(result.responseHash, /^[a-f0-9]{64}$/);
  assert.equal(result.dispatchVerified, false);
});
