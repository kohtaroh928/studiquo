import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// The live evaluation scripts spend money, so nobody runs them in CI. A syntax-valid but broken script
// (a `ReferenceError` in main) went unnoticed once. This runs each main() to the end with a stubbed
// OpenAI endpoint: no network, no cost.
const SSE = [
  { type: 'response.output_text.delta', delta: 'テストの回答です。' },
  { type: 'response.completed', response: { status: 'completed', model: 'gpt-6-luna', usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } } },
].map((e) => `data: ${JSON.stringify(e)}\n\n`).join('');

async function runMain(file, { out, failWith } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'live-smoke-'));
  const target = out ?? path.join(dir, 'out.json');
  const saved = { fetch: globalThis.fetch, argv: process.argv, key: process.env.OPENAI_API_KEY, samples: process.env.SAMPLES, log: console.log, error: console.error };
  const urls = [];
  globalThis.fetch = async (url) => {
    urls.push(String(url));
    if (failWith) return new Response('no', { status: failWith });
    if (String(url) !== 'https://api.openai.com/v1/responses') throw Error('unexpected_network');
    return new Response(SSE, { headers: { 'content-type': 'text/event-stream' } });
  };
  process.argv = [process.argv[0], file, target];
  process.env.OPENAI_API_KEY = 'sk-test-' + 'a'.repeat(24);
  process.env.SAMPLES = '1';
  console.log = () => {}; console.error = () => {};
  try {
    const { main } = await import(`../scripts/rag-quality/${file}?smoke=${Math.random()}`);
    let error = null;
    try { await main(); } catch (e) { error = e; }
    return { error, urls, target, written: fs.existsSync(target) ? JSON.parse(fs.readFileSync(target, 'utf8')) : null };
  } finally {
    Object.assign(globalThis, { fetch: saved.fetch });
    process.argv = saved.argv; console.log = saved.log; console.error = saved.error;
    for (const [k, v] of [['OPENAI_API_KEY', saved.key], ['SAMPLES', saved.samples]]) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

for (const file of ['injection-live.mjs', 'grounding-live.mjs', 'latency-live.mjs']) {
  test(`${file}: main runs to the end against a stubbed endpoint and writes its result`, async () => {
    const r = await runMain(file);
    assert.equal(r.error, null, String(r.error?.stack ?? r.error));
    assert.ok(r.written && Array.isArray(r.written.rows) && r.written.rows.length > 0);
    assert.ok(r.urls.length > 0 && r.urls.every((u) => u === 'https://api.openai.com/v1/responses'));
    assert.ok(!JSON.stringify(r.written).includes('sk-test-'));
  });
}

test('latency-live: an existing result file is never overwritten', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'live-smoke-'));
  const existing = path.join(dir, 'taken.json');
  fs.writeFileSync(existing, '{}');
  try {
    const r = await runMain('latency-live.mjs', { out: existing });
    assert.equal(r.error?.code, 'EEXIST');
    assert.equal(fs.readFileSync(existing, 'utf8'), '{}');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
