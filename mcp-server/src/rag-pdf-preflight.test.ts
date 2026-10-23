// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import { rawPDFPreflightRejection, readRawPDFBytesLimited, MAX_RAW_PDF_BYTES } from './rag/pdf-preflight.ts';
import { aiPrivacyHeadersRejection } from './ai-privacy.ts';

const env = { AI_PROVIDER_APPROVED: 'true', RAG_ENABLED: 'true', RAG_AUTO_INDEX_ENABLED: 'true', RAG_PDF_PROCESSING_ENABLED: 'true' };
const base = { 'X-Studiquo-AI-Consent': 'openai-v1', 'X-Studiquo-Age': 'adult', 'X-Studiquo-RAG-Consent': 'rag-openai-v1', 'X-Studiquo-Raw-PDF-Consent': 'raw-pdf-docling-v1', 'Content-Type': 'application/pdf' };
const bytes = new TextEncoder().encode('%PDF-synthetic');
function request(body = bytes, overrides = {}, options = {}) {
  return new Request('https://example.test/internal', { method: 'POST', headers: { ...base, ...overrides }, body, duplex: 'half', ...options });
}
async function error(result, code, status) {
  assert.ok(result instanceof Response);
  assert.equal(result.status, status);
  assert.deepEqual(await result.json(), { error: code });
}
function stream(values, cancellation = () => {}) {
  return new ReadableStream({ pull(c) { values.length ? c.enqueue(values.shift()) : c.close(); }, cancel: cancellation }, { highWaterMark: 0 });
}

test('header-only AI checks preserve errors without needing a request or body', () => {
  assert.equal(aiPrivacyHeadersRejection(new Headers(base), env), null);
  for (const [name, status] of [['X-Studiquo-AI-Consent', 403], ['X-Studiquo-Age', 403]]) {
    const headers = new Headers(base); headers.delete(name);
    assert.equal(aiPrivacyHeadersRejection(headers, env).status, status);
  }
});

test('every flag and consent fails closed before accessing the body', async () => {
  for (const key of Object.keys(env)) {
    for (const value of [undefined, false, true, 'false']) {
      let accessed = false;
      const req = { headers: new Headers(base), get body() { accessed = true; throw Error('secret'); } };
      assert.ok(await readRawPDFBytesLimited(req, { ...env, [key]: value }) instanceof Response);
      assert.equal(accessed, false);
    }
  }
  for (const key of Object.keys(base).filter(x => x.startsWith('X-'))) {
    const headers = new Headers(base); headers.delete(key);
    const req = { headers, get body() { throw Error('must not access'); } };
    assert.equal((await readRawPDFBytesLimited(req, env)).status, 403);
  }
});

test('format, encoding, and declared sizes reject malformed metadata', async () => {
  for (const value of ['text/plain', 'application/pdf; charset=utf-8', ''])
    assert.equal(rawPDFPreflightRejection(new Headers({ ...base, 'Content-Type': value }), env).status, 415);
  for (const value of ['gzip', 'br', 'identity, gzip', ''])
    assert.equal(rawPDFPreflightRejection(new Headers({ ...base, 'Content-Encoding': value }), env).status, 415);
  for (const value of ['', '4', '-5', '+5', '5.0', '5e1', '5, 5', '9007199254740992'])
    assert.equal(rawPDFPreflightRejection(new Headers({ ...base, 'Content-Length': value }), env).status, 400);
  assert.equal(rawPDFPreflightRejection(new Headers({ ...base, 'Content-Length': String(MAX_RAW_PDF_BYTES + 1) }), env).status, 413);
  assert.equal(rawPDFPreflightRejection(new Headers({ ...base, 'Content-Encoding': 'identity' }), env), null);
});

test('signature can cross every chunk boundary; no declared length is required', async () => {
  const result = await readRawPDFBytesLimited(request(stream([...bytes].map(x => Uint8Array.of(x)))), env);
  assert.deepEqual(result, bytes);
  assert.deepEqual(await readRawPDFBytesLimited(request(bytes.subarray(0, 5), { 'Content-Length': '5' }), env), bytes.subarray(0, 5));
});

test('10 MiB accepted, larger actual stream rejected regardless of declared length', async () => {
  const max = new Uint8Array(MAX_RAW_PDF_BYTES); max.set(bytes);
  assert.deepEqual(await readRawPDFBytesLimited(request(max), env), max);
  await error(await readRawPDFBytesLimited(request(stream([max, Uint8Array.of(0)])), env), 'pdf_too_large', 413);
  await error(await readRawPDFBytesLimited(request(bytes, { 'Content-Length': '5' }), env), 'invalid_pdf_length', 400);
  await error(await readRawPDFBytesLimited(request(bytes, { 'Content-Length': '100' }), env), 'invalid_pdf_length', 400);
});

test('bad signature cancels immediately and does not expose source errors', async () => {
  let cancelled = 0;
  const body = stream([Uint8Array.of(0)], () => { cancelled++; return Promise.reject(Error('private source')); });
  await error(await readRawPDFBytesLimited(request(body), env), 'invalid_pdf_signature', 400);
  assert.equal(cancelled, 1);
  await error(await readRawPDFBytesLimited(request(new ReadableStream({ pull() { throw Error('private detail'); } })), env), 'invalid_pdf_body', 400);
  await error(await readRawPDFBytesLimited(request(stream(['not bytes'])), env), 'invalid_pdf_body', 400);
});

test('missing, empty, locked, and already used body fail cleanly', async () => {
  await error(await readRawPDFBytesLimited(request(null), env), 'invalid_pdf_body', 400);
  await error(await readRawPDFBytesLimited(request(new Uint8Array()), env), 'invalid_pdf_length', 400);
  const used = request(); await used.arrayBuffer();
  await error(await readRawPDFBytesLimited(used, env), 'invalid_pdf_body', 400);
  const locked = request(); const reader = locked.body.getReader();
  await error(await readRawPDFBytesLimited(locked, env), 'invalid_pdf_body', 400); reader.releaseLock();
});

test('stalled reads and stalled cancellation terminate at the receive deadline', async () => {
  let cancelled = 0;
  const body = new ReadableStream({ pull() { return new Promise(() => {}); }, cancel() { cancelled++; return new Promise(() => {}); } }, { highWaterMark: 0 });
  await error(await readRawPDFBytesLimited(request(body), env, { timeoutMs: 15 }), 'pdf_receive_timeout', 408);
  assert.equal(cancelled, 1);
});

test('request and caller abort work before and during a pending read', async () => {
  for (const caller of [false, true]) {
    const controller = new AbortController(); controller.abort();
    const req = request(bytes, {}, caller ? {} : { signal: controller.signal });
    await error(await readRawPDFBytesLimited(req, env, caller ? { signal: controller.signal } : {}), 'pdf_receive_aborted', 408);
  }
  const controller = new AbortController(); let cancelled = 0;
  const req = request(new ReadableStream({ pull() { controller.abort(); return new Promise(() => {}); }, cancel() { cancelled++; } }, { highWaterMark: 0 }));
  await error(await readRawPDFBytesLimited(req, env, { signal: controller.signal }), 'pdf_receive_aborted', 408);
  assert.equal(cancelled, 1);
});

test('continuous empty chunks cannot evade absolute deadline', async () => {
  const body = new ReadableStream({ pull(c) { c.enqueue(new Uint8Array()); } }, { highWaterMark: 0 });
  await error(await readRawPDFBytesLimited(request(body), env, { timeoutMs: 15 }), 'pdf_receive_timeout', 408);
});

test('concurrent reads isolate cancellation and bytes', async () => {
  const controller = new AbortController(); controller.abort();
  const [a, b] = await Promise.all([
    readRawPDFBytesLimited(request(), env, { signal: controller.signal }),
    readRawPDFBytesLimited(request(), env),
  ]);
  assert.equal(a.status, 408); assert.deepEqual(b, bytes);
});

test('trusted deadline may only shorten cap; wrong methods never read', async () => {
  for (const timeoutMs of [0, -1, NaN, Infinity, 10_001])
    await error(await readRawPDFBytesLimited(request(), env, { timeoutMs }), 'invalid_pdf_deadline', 400);
  await error(await readRawPDFBytesLimited({ headers: new Headers(base), method: 'GET', get body() { throw Error('do not read'); } }, env), 'invalid_pdf_method', 405);
});


test('tiny chunk flood is bounded even if the receive timer cannot run', async () => {
  let cancelled = false;
  const body = new ReadableStream({ pull(c) { c.enqueue(new Uint8Array()); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
  await error(await readRawPDFBytesLimited(request(body), env), 'pdf_stream_limit', 413);
  assert.equal(cancelled, true);
});
