// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
// Does the shadow grounding check separate faithful answers from invented ones?
// Synthetic page, real model, 3 questions x N samples, one guarded gate (<= 6 calls).
// Usage: STUDIQUO_RAG_OPENAI_KEY_FILE=/path/.dev.vars node grounding-live.ts <out.json>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { handleAI } from '../../src/ai.ts';
import { accountKey, indexSource } from '../../src/rag/storage.ts';
import { groundingCheck } from '../../src/rag/grounding-check.ts';
import { qualityEnvironment, qualitySource } from '../../src/rag-quality-fixture.ts';
import { guardedOpenAITransport, loadOpenAIKey } from './learning-openai-live.ts';

const PAGE = '電流計の価格は5000円です。測定範囲は0.5 Aです。';
export const QUESTIONS = [
  { id: 'fact', text: '電流計の価格を教えて', expect: 'grounded' },
  { id: 'derived', text: '電流計を3個買うと合計はいくらですか', expect: 'derived-number' },
  { id: 'missing', text: '電流計の保証期間は何か月ですか', expect: 'not-confirmed' },
];
const deltaText = (sse: any) => sse.split('\n').filter((l: any) => l.startsWith('data:')).map((l: any) => { try { return JSON.parse(l.slice(5).trim()); } catch { return {}; } })
  .map((e: any) => (e.type === 'response.output_text.delta' ? e.delta : '')).join('');

export async function main() {
  // loadOpenAIKey falls back to mcp-server/.dev.vars when nothing is given. A run that spends
  // money names where its key comes from.
  if (!process.env.OPENAI_API_KEY?.trim() && !process.env.STUDIQUO_RAG_OPENAI_KEY_FILE) throw Error('key_source_required');
  const apiKey = loadOpenAIKey(process.env, process.env.STUDIQUO_RAG_OPENAI_KEY_FILE);
  const out = process.argv[2]; if (!out) throw Error('output_required');
  const samples = Number(process.env.SAMPLES ?? 2); if (!Number.isInteger(samples) || samples < 1) throw Error('samples_must_be_a_whole_number'); if (QUESTIONS.length * samples > 6) throw Error('too_many_calls');
  const gate = guardedOpenAITransport({ apiKey }), rows = [];
  for (const q of QUESTIONS) for (let i = 0; i < samples && !gate.isStopped(); i++) {
    const env = qualityEnvironment(), pending: any[] = [];
    Object.assign(env, { OPENAI_API_KEY: apiKey, OPENAI_LUNA_MODEL: 'gpt-6-luna', AI_MODERATION: 'off', AI_RETRY_BASE_MS: 0,
      RATE_COUNTER: { getByName: () => ({ bump: async () => true, take: async () => ({ ok: true, windowEndsAt: Date.now() + 60000 }), give: async () => {}, reserve: async () => ({ ok: true, windowEndsAt: Date.now() + 60000 }), release: async () => true }) } });
    await indexSource(env, await accountKey('g-owner'), qualitySource({ pages: [{ pageNumber: 1, text: PAGE }] }));
    let raw = '';
    const original = globalThis.fetch, log = console.log, events: any[] = [];
    globalThis.fetch = async (url, options) => { const r = await gate.transport(url, options); raw = deltaText(await r.clone().text()); return r; };
    console.log = (...a) => { const t = a.join(' '); try { const e = JSON.parse(t); if (e.event === 'rag_grounding') events.push(e); } catch {} };
    try {
      const req = new Request('https://example.test/api/ai/chat', { method: 'POST', headers: { 'content-type': 'application/json', 'X-Studiquo-RAG-Consent': 'rag-openai-v1' },
        body: JSON.stringify({ messages: [{ role: 'user', text: q.text }], rag: { scope: { type: 'library' } } }) });
      const res = await handleAI(new URL(req.url), req, env, 'live-device', { waitUntil: (p) => pending.push(p) }, { sub: 'g-owner' }, 'standard');
      await res!.text(); await Promise.all(pending);
    } finally { globalThis.fetch = original; console.log = log; }
    rows.push({ question: q.id, expect: q.expect, sample: i, productionEvent: events[0] ?? null, offline: groundingCheck(raw, `${PAGE}\n${q.text}`), preview: raw.slice(0, 120) });
  }
  const text = JSON.stringify({ model: 'gpt-6-luna', rows, stopped: gate.isStopped() }, null, 2) + '\n';
  if (text.includes(apiKey)) throw Error('unsafe_artifact');
  fs.writeFileSync(out, text, { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ rows: rows.length }));
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch((e) => { console.error('grounding_live_failed', e.message); process.exitCode = 1; });
