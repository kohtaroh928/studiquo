import { aiPrivacyHeadersRejection } from '../ai-privacy.js';
import { json } from '../http.js';

export const RAW_PDF_CONSENT_VERSION = 'raw-pdf-docling-v1';
export const MAX_RAW_PDF_BYTES = 10 * 1024 * 1024;
const RECEIVE_TIMEOUT_MS = 10_000;
const MAX_READ_OPERATIONS = 65_536;
const MAGIC = [37, 80, 68, 70, 45]; // %PDF-
const failure = (code, status = 400) => json({ error: code }, status);

function declaredLength(headers) {
  const value = headers.get('Content-Length');
  if (value === null) return null;
  if (!/^[0-9]+$/u.test(value)) return NaN;
  const length = Number(value);
  return Number.isSafeInteger(length) ? length : NaN;
}

/** Self-reported headers/format only: NOT owner authorization, persisted consent or admission.
 * No public route may use this alone to authorize PDF processing.
 */
export function rawPDFPreflightRejection(headers, env) {
  if (['RAG_ENABLED', 'RAG_AUTO_INDEX_ENABLED', 'RAG_PDF_PROCESSING_ENABLED']
    .some(key => env[key] !== 'true')) return failure('raw_pdf_disabled', 503);
  const aiRejection = aiPrivacyHeadersRejection(headers, env);
  if (aiRejection) return aiRejection;
  if (headers.get('X-Studiquo-RAG-Consent') !== 'rag-openai-v1' ||
      headers.get('X-Studiquo-Raw-PDF-Consent') !== RAW_PDF_CONSENT_VERSION)
    return failure('raw_pdf_consent_required', 403);
  if (headers.get('Content-Type')?.toLowerCase() !== 'application/pdf' ||
      ![null, 'identity'].includes(headers.get('Content-Encoding')?.toLowerCase() ?? null))
    return failure('invalid_pdf_format', 415);
  const length = declaredLength(headers);
  if (length !== null && (!Number.isFinite(length) || length < MAGIC.length))
    return failure('invalid_pdf_length');
  if (length > MAX_RAW_PDF_BYTES) return failure('pdf_too_large', 413);
  return null;
}

/** Disconnected input primitive. Returns bytes or a fixed Response; never sends/persists them.
 * Caller must complete trusted owner/generation/epoch/admission checks BEFORE invoking it.
 * timeoutMs may only shorten the fixed receive deadline (e.g. an earlier caller deadline).
 */
export async function readRawPDFBytesLimited(request, env, { signal, timeoutMs = RECEIVE_TIMEOUT_MS, onReaderCleanup } = {}) {
  const rejection = rawPDFPreflightRejection(request.headers, env);
  if (rejection) return rejection;
  if (request.method !== 'POST') return failure('invalid_pdf_method', 405);
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > RECEIVE_TIMEOUT_MS)
    return failure('invalid_pdf_deadline');
  const signals = [...new Set([request.signal, signal].filter(Boolean))];
  let stopped;
  let interruptRead;
  const stop = code => {
    if (!stopped) { stopped = code; interruptRead?.({ stopped: true }); }
  };
  const onAbort = () => stop('pdf_receive_aborted');
  const timer = setTimeout(() => stop('pdf_receive_timeout'), timeoutMs);
  const deadline = Date.now() + timeoutMs;
  let reader;
  let complete = false;
  try {
    for (const item of signals) {
      item.addEventListener('abort', onAbort, { once: true });
      if (item.aborted) onAbort();
    }
    if (stopped) return failure(stopped, 408);
    if (request.bodyUsed || !request.body || request.body.locked) return failure('invalid_pdf_body');
    reader = request.body.getReader();
    // One fixed buffer avoids unbounded per-chunk bookkeeping or retained input views.
    const buffer = new Uint8Array(MAX_RAW_PDF_BYTES);
    const expected = declaredLength(request.headers);
    let size = 0;
    let reads = 0;
    while (true) {
      if (Date.now() >= deadline) stop('pdf_receive_timeout');
      if (stopped) return failure(stopped, 408);
      // Also bound synchronous/microtask chunk floods where timers cannot run.
      if (++reads > MAX_READ_OPERATIONS) return failure('pdf_stream_limit', 413);
      // Keep only the current read interruptible; racing every chunk against one
      // unresolved promise retains one reaction per chunk until the whole upload ends.
      const part = await new Promise((resolve, reject) => {
        interruptRead = resolve;
        reader.read().then(resolve, reject);
      });
      interruptRead = undefined;
      if (stopped) return failure(stopped, 408);
      if (Date.now() >= deadline) return failure('pdf_receive_timeout', 408);
      if (part.done) break;
      if (!(part.value instanceof Uint8Array)) return failure('invalid_pdf_body');
      const next = size + part.value.byteLength;
      if (next > MAX_RAW_PDF_BYTES) return failure('pdf_too_large', 413);
      if (expected !== null && next > expected) return failure('invalid_pdf_length');
      for (let i = size; i < Math.min(next, MAGIC.length); i++) {
        if (part.value[i - size] !== MAGIC[i]) return failure('invalid_pdf_signature');
      }
      buffer.set(part.value, size);
      size = next;
    }
    if (signals.some(item => item.aborted)) return failure('pdf_receive_aborted', 408);
    if (size < MAGIC.length || (expected !== null && size !== expected)) return failure('invalid_pdf_length');
    complete = true;
    return buffer.slice(0, size);
  } catch {
    return failure(stopped ?? 'invalid_pdf_body', stopped ? 408 : 400);
  } finally {
    interruptRead = undefined;
    clearTimeout(timer);
    for (const item of signals) item.removeEventListener('abort', onAbort);
    let cleanup = Promise.resolve(true);
    if (reader) {
      if (!complete) {
        // Observe cancellation rejection, but never wait indefinitely for an underlying source.
        try { cleanup = reader.cancel().then(() => true, () => false); } catch { cleanup = Promise.resolve(false); }
      }
      try { reader.releaseLock(); } catch { cleanup = Promise.resolve(false); }
    }
    // Trusted caller may await this separately under its cleanup deadline.
    try { onReaderCleanup?.(cleanup); } catch { /* must not replace the selected result */ }
  }
}
