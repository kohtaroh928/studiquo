// How long does a student wait for a reply that is held until it is complete?
// Production handleAI path, synthetic data, real model. The OpenAI stream is passed through
// (not buffered) so the time of the first token and of the last one are both seen.
// A replies that are held show their first text when the model finishes; a streamed reply
// shows it at the first token. The difference is the extra wait the hold costs.
// Cost bound: MAX_CALLS requests in total, one at a time; the first failure stops the run.
// Usage: STUDIQUO_RAG_OPENAI_KEY_FILE=/path/.dev.vars SAMPLES=2 node latency-live.mjs <out.json>
import fs from 'node:fs';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { handleAI } from '../../src/ai.js';
import { accountKey, indexSource } from '../../src/rag/storage.js';
import { qualityEnvironment, qualitySource } from '../../src/rag-quality-fixture.js';
import { loadOpenAIKey } from './learning-openai-live.mjs';

const MAX_CALLS = 14;
const PHOTOSYNTHESIS = [
  '光合成は、植物が光のエネルギーを使って、水と二酸化炭素から有機物を作るしくみです。',
  '葉の細胞にある葉緑体で行われ、葉緑体に含まれる葉緑素(クロロフィル)が光を吸収します。',
  '光合成は大きく、光が必要な反応(明反応)と、光を直接は必要としない反応(暗反応、カルビン・ベンソン回路)の二つに分けられます。',
  '明反応では、光エネルギーで水が分解されて酸素が出ます。このときATPとNADPHが作られます。',
  '暗反応では、ATPとNADPHのエネルギーを使って二酸化炭素が固定され、糖(グルコースなど)が作られます。',
  '光合成の速さは、光の強さ、二酸化炭素の濃度、温度によって変わります。',
].join('\n\n');
const NOTE = PHOTOSYNTHESIS + '\n\n呼吸は、有機物を分解してエネルギー(ATP)を取り出す反応で、細胞のミトコンドリアで行われます。';

export const CASES = [
  { id: 'rag-short', kind: 'rag', question: '光合成が行われる場所はどこですか', style: 'source_only' },
  { id: 'rag-long', kind: 'rag', question: '光合成のしくみを、明反応と暗反応に分けて、初心者向けに順を追って詳しく説明して', style: 'explain' },
  { id: 'note-short', kind: 'note', question: 'このノートの要点を一文で教えて' },
  { id: 'note-long', kind: 'note', question: 'このノートの内容を、見出しをつけて詳しく解説して' },
  { id: 'plain-long', kind: 'plain', question: '光合成のしくみを、明反応と暗反応に分けて、初心者向けに順を追って詳しく説明して' },
];

const sseEvents = (text) => text.split('\n').filter((l) => l.startsWith('data:')).map((l) => { try { return JSON.parse(l.slice(5).trim()); } catch { return {}; } });

async function runOne({ apiKey, testCase, calls }) {
  const env = qualityEnvironment(), pending = [];
  Object.assign(env, { OPENAI_API_KEY: apiKey, OPENAI_LUNA_MODEL: 'gpt-6-luna', AI_MODERATION: 'off', AI_RETRY_BASE_MS: 0,
    RATE_COUNTER: { getByName: () => ({ bump: async () => true, take: async () => ({ ok: true, windowEndsAt: Date.now() + 60000 }), give: async () => {} }) } });
  if (testCase.kind === 'rag') await indexSource(env, await accountKey('lat-owner'), qualitySource({ pages: [{ pageNumber: 1, text: PHOTOSYNTHESIS }] }));
  const t0 = performance.now();
  const upstream = { firstToken: null, done: null, chars: 0 };
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    if (calls.n >= MAX_CALLS) throw Error('call_limit');
    const body = JSON.parse(options.body);
    if (url !== 'https://api.openai.com/v1/responses' || body.store !== false || body.model !== 'gpt-6-luna' || body.tools !== undefined) throw Error('unexpected_request');
    calls.n++;
    const response = await original(url, { ...options, redirect: 'error', headers: { ...options.headers, authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(120000) });
    if (!response.ok) { calls.failed = response.status; return response; }
    const reader = response.body.getReader(), decoder = new TextDecoder();
    return new Response(new ReadableStream({
      async pull(controller) {
        const { done, value } = await reader.read();
        if (done) { upstream.done ??= performance.now() - t0; controller.close(); return; }
        const text = decoder.decode(value, { stream: true });
        for (const e of sseEvents(text)) if (e.type === 'response.output_text.delta') { upstream.firstToken ??= performance.now() - t0; upstream.chars += (e.delta ?? '').length; }
        controller.enqueue(value);
      },
    }), { status: response.status, headers: response.headers });
  };
  try {
    const request = { messages: [{ role: 'user', text: testCase.question }] };
    if (testCase.kind === 'rag') request.rag = { scope: { type: 'library' }, answerStyle: testCase.style };
    if (testCase.kind === 'note') request.noteContext = NOTE;
    const req = new Request('https://example.test/api/ai/chat', { method: 'POST', headers: { 'content-type': 'application/json', 'X-Studiquo-RAG-Consent': 'rag-openai-v1' }, body: JSON.stringify(request) });
    const response = await handleAI(new URL(req.url), req, env, 'lat-device', { waitUntil: (p) => pending.push(p) }, { sub: 'lat-owner' }, 'standard');
    const reader = response.body.getReader(), decoder = new TextDecoder();
    const client = { firstText: null, last: null, textEvents: 0, keepalives: 0, textChars: 0, bytes: 0 };
    let buffer = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const now = performance.now() - t0;
      const chunk = decoder.decode(value, { stream: true });
      client.bytes += value.length;
      buffer += chunk;
      const lines = buffer.split('\n'); buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (line.startsWith(':')) client.keepalives++;
        if (!line.startsWith('data:')) continue;
        const e = (() => { try { return JSON.parse(line.slice(5).trim()); } catch { return {}; } })();
        if (typeof e.text === 'string' && e.text) { client.firstText ??= now; client.last = now; client.textEvents++; client.textChars += e.text.length; }
      }
    }
    await Promise.all(pending);
    return { id: testCase.id, kind: testCase.kind, upstream: round(upstream), client: round(client), totalMs: Math.round(performance.now() - t0) };
  } finally { globalThis.fetch = original; }
}
const round = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, typeof v === 'number' && !Number.isInteger(v) ? Math.round(v) : v]));

export async function main() {
  const apiKey = loadOpenAIKey(process.env, process.env.STUDIQUO_RAG_OPENAI_KEY_FILE);
  const out = process.argv[2]; if (!out) throw Error('output_required');
  const samples = Number(process.env.SAMPLES ?? 2);
  if (CASES.length * samples > MAX_CALLS) throw Error('too_many_calls');
  const calls = { n: 0, failed: null }, rows = [];
  for (const testCase of CASES) for (let i = 0; i < samples; i++) {
    if (calls.failed) break;
    rows.push({ sample: i, ...(await runOne({ apiKey, testCase, calls })) });
    console.log(JSON.stringify({ progress: rows.length }));
  }
  const text = JSON.stringify({ model: 'gpt-6-luna', samples, calls: calls.n, failedStatus: calls.failed, rows }, null, 2) + '\n';
  if (text.includes(apiKey)) throw Error('unsafe_artifact');
  fs.writeFileSync(out, text, { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ rows: rows.length, calls: calls.n }));
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch((e) => { console.error('latency_live_failed', e.message); process.exitCode = 1; });
