import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {buildPlan, run, readStream, reserveUSD} from './run-luna.mjs';

const sse = (...events) => new Response(events.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join(''), {status: 200});
const ok = text => sse({type: 'response.output_text.delta', delta: text.slice(0, 2)}, {type: 'response.output_text.delta', delta: text.slice(2)},
  {type: 'response.completed', response: {model: 'gpt-6-luna', usage: {input_tokens: 10, output_tokens: 5}}});
const KEY = 'placeholder-not-a-key';

test('plan has one shared baseline per case/style plus each candidate, bodies unchanged', () => {
  const plan = buildPlan(['example', 'requirement-coverage-v1']);
  assert.equal(plan.requests.length, 36);
  assert.equal(new Set(plan.requests.map(r => r.id)).size, 36);
  const firsts = new Set();
  for (let i = 0; i < 36; i += 3) firsts.add(plan.requests[i].variant);
  assert.equal(firsts.size, 3);
  for (const r of plan.requests) {
    assert.equal(r.body.model, 'gpt-6-luna');
    assert.equal(r.body.max_output_tokens, 8192);
    assert.equal(r.body.store, false);
  }
});

test('stream parser keeps text/usage and rejects failures', async () => {
  assert.deepEqual(await readStream(ok('こんにちは')), {text: 'こんにちは', model: 'gpt-6-luna', usage: {input_tokens: 10, output_tokens: 5}});
  await assert.rejects(readStream(sse({type: 'response.failed'})), /stream_failed/);
  await assert.rejects(readStream(sse({type: 'response.output_text.delta', delta: 'x'})), /stream_incomplete/);
  await assert.rejects(readStream(new Response('', {status: 429})), /http_429/);
});

test('run sends each body once, saves private answers, stops at limits and resumes without resending', async () => {
  const outputRoot = mkdtempSync(path.join(tmpdir(), 'rag-run-'));
  const sent = [];
  const fetchImpl = async (url, init) => {sent.push(JSON.parse(init.body)); assert.equal(init.headers.authorization, 'Bearer ' + KEY); return ok('回答' + sent.length);};
  const opts = {runName: 'trial', candidates: ['example'], maxCalls: 24, budgetUSD: 1, apiKey: KEY, fetchImpl, outputRoot};
  const plan = buildPlan(['example']);
  const first = await run({...opts, maxCalls: 24, budgetUSD: reserveUSD(plan.requests[0].body) * 3.5});
  assert.equal(first.stopped, 'limit');
  assert.equal(sent.length, 3);
  await assert.rejects(run({...opts, resume: true, budgetUSD: 2}), /plan_changed/);
  await assert.rejects(run(opts), /EEXIST/);
  const dir = path.join(outputRoot, 'trial');
  assert.equal(statSync(path.join(dir, 'answers.json')).mode & 0o777, 0o600);
  assert.ok(!readFileSync(path.join(dir, 'metrics.json'), 'utf8').includes('回答'));
  const full = await run({...opts, runName: 'full'});
  assert.deepEqual([full.stopped, full.calls, sent.length], ['done', 24, 27]);
  const again = await run({...opts, runName: 'full', resume: true});
  assert.deepEqual([again.stopped, again.calls, sent.length], ['done', 24, 27]);
  const answers = JSON.parse(readFileSync(path.join(outputRoot, 'full', 'answers.json'), 'utf8'));
  assert.equal(Object.keys(answers.variants.baseline).length + Object.keys(answers.variants['example-completeness-v1']).length, 24);
});

test('a failure stops the run, is not retried, and blocks resume; an unresolved send also blocks', async () => {
  const outputRoot = mkdtempSync(path.join(tmpdir(), 'rag-run-'));
  let n = 0;
  const fetchImpl = async () => (++n === 2 ? new Response('secret echo', {status: 500}) : ok('ok'));
  const opts = {runName: 'trial', candidates: ['example'], maxCalls: 24, budgetUSD: 1, apiKey: KEY, fetchImpl, outputRoot};
  assert.deepEqual((await run(opts)).code, 'http_500');
  assert.equal(n, 2);
  await assert.rejects(run({...opts, resume: true}), /previous_failure/);
  const journal = path.join(outputRoot, 'trial', 'journal.ndjson');
  assert.ok(!readFileSync(journal, 'utf8').includes('secret echo'));
  writeFileSync(journal, JSON.stringify({id: 'x', state: 'reserved', reservedUSD: 0.01}) + '\n');
  await assert.rejects(run({...opts, resume: true}), /unresolved_send/);
  await assert.rejects(run({...opts, runName: 'other', apiKey: ''}), /missing_key/);
});
