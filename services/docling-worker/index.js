import { DurableObject, WorkerEntrypoint } from 'cloudflare:workers';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_PDF = 10 * 1024 * 1024, MAX_OUTPUT = 4 * 1024 * 1024;
const DEADLINE = 125000, STARTUP = 30000, CLEANUP = 10000;
const RETRIES = [10000, 30000, 90000];
const fail = code => new Error(code);
const validId = id => { if (typeof id !== 'string' || !UUID.test(id)) throw fail('input_invalid'); };
function pdfInput(value) {
  if (!(value instanceof Uint8Array) && !(value instanceof ArrayBuffer)) throw fail('input_invalid');
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  if (bytes.byteLength < 5 || bytes.byteLength > MAX_PDF || ![37,80,68,70,45].every((v,i) => bytes[i] === v)) throw fail('input_invalid');
  return new Uint8Array(bytes);
}
const sha = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2,'0')).join('');
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === names.sort().join(',');

// V2 requires a trusted, persisted deadline; never regenerate it on retry.
function rpcEnvelope(value,parse) {
  if(!keys(value,parse?['version','jobId','pdfSha256','notAfter']:['version','jobId','notAfter'])||value.version!==2)throw fail('input_invalid');
  validId(value.jobId);
  if(!Number.isSafeInteger(value.notAfter)||value.notAfter<1||value.notAfter>Number.MAX_SAFE_INTEGER-180000||
   (parse&&(typeof value.pdfSha256!=='string'||!/^[a-f0-9]{64}$/.test(value.pdfSha256))))throw fail('input_invalid');
  return Object.freeze({...value});
}
function rpcTime(contract,now,parse) {
  if(!Number.isSafeInteger(now)||now<0||contract.notAfter>now+180000||(parse&&now>=contract.notAfter))throw fail('input_invalid');
}

// Boundary validation, not a replacement for the final structured-input validator.
export function validateManifest(value, digest) {
  if (!keys(value, ['version','integration','batches']) || value.version !== 1 || value.integration !== 'prepared_only_no_upload' || !Array.isArray(value.batches) || !value.batches.length || value.batches.length > 20) throw fail('output_invalid');
  let total, common, next = 1;
  for (const batch of value.batches) {
    if (!keys(batch, ['structure','totalPages','pages']) || !Number.isInteger(batch.totalPages) || batch.totalPages < 1 || batch.totalPages > 20 || !Array.isArray(batch.pages) || !batch.pages.length || batch.pages.length > 5) throw fail('output_invalid');
    if (!keys(batch.structure, ['version','documentNamespace','document']) || batch.structure.version !== 1 || !/^[a-f0-9]{64}$/.test(batch.structure.documentNamespace) || batch.structure.document?.pdfSha256 !== digest) throw fail('output_invalid');
    const binding = JSON.stringify(batch.structure);
    if (total !== undefined && (total !== batch.totalPages || common !== binding)) throw fail('output_invalid');
    total = batch.totalPages; common = binding;
    for (const page of batch.pages) {
      if (!keys(page, ['pageNumber','text','structured']) || page.pageNumber !== next++ || typeof page.text !== 'string' || !page.text.trim() || page.text.length > 100000 || !keys(page.structured, ['version','records']) || page.structured.version !== 1 || !Array.isArray(page.structured.records) || !page.structured.records.length || page.structured.records.length > 100) throw fail('output_invalid');
      for (const record of page.structured.records) {
        if (!keys(record, ['text','metadata']) || typeof record.text !== 'string' || !record.text.trim() || record.text.length > 6000 || !record.metadata || typeof record.metadata !== 'object' || Array.isArray(record.metadata)) throw fail('output_invalid');
      }
    }
  }
  if (next !== total + 1) throw fail('output_invalid');
  return value;
}

export class DoclingProcessor extends WorkerEntrypoint {
  async fetch() { return new Response('Not found', { status: 404 }); }
  async parse(jobId, pdfBytes) {
    if (this.env.DOCLING_RPC_V2_ONLY === 'true') throw fail('rpc_upgrade_required');
    if (this.env.DOCLING_EXECUTION_ENABLED !== 'true') throw fail('execution_disabled');
    validId(jobId); const bytes = pdfInput(pdfBytes);
    try { return await this.env.DOCLING_JOBS.get(this.env.DOCLING_JOBS.idFromName(jobId)).parse(jobId, bytes); }
    catch { throw fail('processing_failed'); }
  }
  async cancel(jobId) {
    if (this.env.DOCLING_RPC_V2_ONLY === 'true') throw fail('rpc_upgrade_required');
    validId(jobId);
    try { return await this.env.DOCLING_JOBS.get(this.env.DOCLING_JOBS.idFromName(jobId)).cancel(jobId); }
    catch { throw fail('cleanup_failed'); }
  }
  async parseV2(input,pdfBytes) {
    if(this.env.DOCLING_RPC_V2_ONLY!=='true')throw fail('rpc_upgrade_required');
    if(this.env.DOCLING_EXECUTION_ENABLED!=='true')throw fail('execution_disabled');
    const contract=rpcEnvelope(input,true),bytes=pdfInput(pdfBytes);rpcTime(contract,Date.now(),true);
    try{return await this.env.DOCLING_JOBS.get(this.env.DOCLING_JOBS.idFromName(contract.jobId)).parseV2(contract,bytes);}
    catch{throw fail('processing_failed');}
  }
  async cancelV2(input) {
    if(this.env.DOCLING_RPC_V2_ONLY!=='true')throw fail('rpc_upgrade_required');
    const contract=rpcEnvelope(input,false);rpcTime(contract,Date.now(),false);
    try{return await this.env.DOCLING_JOBS.get(this.env.DOCLING_JOBS.idFromName(contract.jobId)).cancelV2(contract);}
    catch{throw fail('cleanup_failed');}
  }

}

export default DoclingProcessor;

export class DoclingJob extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.stopping = false;
    this.ready = this.gate(async () => {
      const state = await ctx.storage.get('job');
      if (state && ['running','finishing'].includes(state.status)) {
        await ctx.storage.put('job', { ...state, status: 'poisoned' });
        await ctx.storage.setAlarm(Date.now());
      }
    });
    // Some denied/public entrances never await initialization. Mark its rejection
    // handled immediately, while retaining the original rejected promise for RPCs.
    this.ready.catch(() => {});
  }
  async fetch() { return new Response('Not found', { status: 404 }); }
  // Never throw out of blockConcurrencyWhile: Workers otherwise resets this DO.
  async gate(operation) {
    const outcome = await this.ctx.blockConcurrencyWhile(async () => {
      try { return { ok: true, value: await operation() }; }
      catch (error) { return { ok: false, unavailable: error?.message === 'job_unavailable' }; }
    });
    if (!outcome.ok) throw fail(outcome.unavailable ? 'job_unavailable' : 'processing_failed');
    return outcome.value;
  }
  now() { return Date.now(); }
  async limited(work, milliseconds, signal) {
    if (milliseconds <= 0 || signal?.aborted) throw fail('processing_failed');
    let timer, listener;
    try {
      return await Promise.race([Promise.resolve().then(work), new Promise((_, reject) => {
        timer = setTimeout(() => reject(fail('processing_failed')), milliseconds);
        if (signal) { listener = () => reject(fail('processing_failed')); signal.addEventListener('abort', listener, { once: true }); }
      })]);
    } finally { clearTimeout(timer); if (listener) signal.removeEventListener('abort', listener); }
  }
  async claim(jobId,contract) {
    if(this.env.DOCLING_RPC_V2_ONLY==='true'){
      contract=rpcEnvelope(contract,true);if(contract.jobId!==jobId)throw fail('input_invalid');
    }else if(contract)throw fail('rpc_upgrade_required');
    await this.ready;
    return this.gate(async () => {
      if (await this.ctx.storage.get('job')) throw fail('job_unavailable');
      if(contract)rpcTime(contract,this.now(),true);
      const state = { jobId, status: 'running', deadline: Math.min(this.now() + DEADLINE,contract?.notAfter??Infinity), cleanupAttempts: 0,
        ...(contract?{rpcVersion:2,notAfter:contract.notAfter}:{}) };
      await this.ctx.storage.put('job', state);
      try { await this.ctx.storage.setAlarm(state.deadline); }
      catch { await this.ctx.storage.put('job', { ...state, status: 'poisoned' }); throw fail('processing_failed'); }
      return state;
    });
  }
  async assertRunning() {
    const state = await this.ctx.storage.get('job');
    if (this.stopping || state?.status !== 'running' || this.now() >= state.deadline) throw fail('processing_failed');
  }
  async parse(jobId, pdfBytes) {
    try { if(this.env.DOCLING_RPC_V2_ONLY==='true')throw fail('rpc_upgrade_required');return await this.execute(jobId, pdfBytes); } catch { throw fail('processing_failed'); }
  }
  async parseV2(input,pdfBytes) {
    try{
      if(this.env.DOCLING_RPC_V2_ONLY!=='true')throw fail('rpc_upgrade_required');
      const contract=rpcEnvelope(input,true),bytes=pdfInput(pdfBytes);rpcTime(contract,this.now(),true);
      return await this.execute(contract.jobId,bytes,contract);
    }catch{throw fail('processing_failed');}
  }
  async execute(jobId, pdfBytes,contract) {
    if (this.env.DOCLING_EXECUTION_ENABLED !== 'true') throw fail('execution_disabled');
    validId(jobId); const bytes = pdfInput(pdfBytes);
    if(contract || this.env.DOCLING_RPC_V2_ONLY==='true'){
      if(this.env.DOCLING_RPC_V2_ONLY!=='true')throw fail('rpc_upgrade_required');
      contract=rpcEnvelope(contract,true);if(contract.jobId!==jobId)throw fail('input_invalid');
      rpcTime(contract,this.now(),true);if(await sha(bytes)!==contract.pdfSha256)throw fail('input_invalid');
    }
    let state;
    try {
      if (this.stopping) throw fail('job_unavailable');
      state = await this.claim(jobId,contract);
    } catch (error) {
      if (error?.message !== 'job_unavailable') {
        this.stopping = true; this.abort?.abort();
        await this.cleanup();
      }
      throw fail('processing_failed');
    }
    this.abort = new AbortController();
    let cleanupAttempted = false;
    try {
      const digest = await sha(bytes);
      await this.assertRunning();
      if (this.stopping || this.abort.signal.aborted) throw fail('processing_failed');
      this.ctx.container.start({ enableInternet: false });
      const monitor = this.ctx.container.monitor();
      // Handle both clean unexpected exit and monitor failures without logging details.
      this.ctx.waitUntil(Promise.resolve(monitor).then(() => this.unexpectedExit(), () => this.unexpectedExit()).catch(() => {}));
      const port = this.ctx.container.getTcpPort(8080);
      const startupEnd = Math.min(state.deadline, this.now() + STARTUP);
      for (;;) {
        await this.assertRunning();
        if (this.now() >= startupEnd) throw fail('processing_failed');
        let response;
        try { response = await this.limited(() => port.fetch('http://127.0.0.1:8080/ready', { method: 'GET', redirect: 'manual', signal: this.abort.signal }), Math.min(1000, startupEnd - this.now()), this.abort.signal); }
        catch { /* A connection may be refused while the fixed process starts. */ }
        if (response?.status === 204) { response.body?.cancel().catch(() => {}); if (this.now() >= startupEnd) throw fail('processing_failed'); break; }
        response?.body?.cancel().catch(() => {});
        await this.limited(() => new Promise(resolve => setTimeout(resolve, 100)), startupEnd - this.now(), this.abort.signal);
      }
      await this.assertRunning();
      if (this.stopping || this.abort.signal.aborted) throw fail('processing_failed');
      const response = await this.limited(() => port.fetch('http://127.0.0.1:8080/parse', {
        method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/pdf', 'Content-Length': String(bytes.byteLength) }, body: bytes, signal: this.abort.signal,
      }), state.deadline - this.now(), this.abort.signal);
      if (response.status !== 200 || response.headers.get('content-type')?.split(';')[0].trim() !== 'application/json') { response.body?.cancel().catch(() => {}); throw fail('output_invalid'); }
      const text = await this.limited(() => this.readResponse(response), state.deadline - this.now(), this.abort.signal);
      const result = validateManifest(JSON.parse(text), digest);
      await this.assertRunning();
      await this.gate(async () => {
        await this.assertRunning();
        await this.ctx.storage.put('job', { ...state, status: 'finishing' });
      });
      cleanupAttempted = true;
      if (!await this.cleanup()) throw fail('cleanup_failed');
      return await this.gate(async () => {
        const current = await this.ctx.storage.get('job');
        if (this.stopping || current.status !== 'finishing' || this.now() >= state.deadline) throw fail('processing_failed');
        await this.ctx.storage.put('job', { ...current, status: 'completed' });
        return result;
      });
    } catch {
      this.stopping = true; this.abort.abort();
      try { await this.markStopped('failed'); }
      catch { /* Persistence failure cannot suppress VM teardown. */ }
      finally { if (!cleanupAttempted) await this.cleanup(); }
      throw fail('processing_failed');
    }
  }
  async readResponse(response) {
    const declared = response.headers.get('content-length');
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_OUTPUT)) { response.body?.cancel().catch(() => {}); throw fail('output_invalid'); }
    if (!response.body) throw fail('output_invalid');
    const reader = response.body.getReader(), chunks = []; let size = 0, done = false;
    try {
      for (;;) {
        const part = await this.limited(() => reader.read(), 125000, this.abort.signal);
        if (part.done) { done = true; break; }
        size += part.value.byteLength;
        if (size > MAX_OUTPUT) throw fail('output_invalid');
        chunks.push(part.value);
      }
      if (declared !== null && Number(declared) !== size) throw fail('output_invalid');
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } finally { if (!done) reader.cancel().catch(() => {}); reader.releaseLock(); }
  }
  async markStopped(status) {
    await this.gate(async () => {
      const state = await this.ctx.storage.get('job');
      if (state && !['completed','poisoned','cancelled','expired'].includes(state.status)) await this.ctx.storage.put('job', { ...state, status });
    });
  }
  async unexpectedExit() {
    if (this.destroyRequested || this.stopping) return;
    this.stopping = true; this.abort?.abort();
    try { await this.markStopped('failed'); }
    catch { /* Keep raw storage errors private. */ }
    finally { await this.cleanup(); }
  }
  async cleanup() {
    if (this.cleaning) return this.cleaning;
    this.destroyRequested = true;
    this.cleaning = (async () => {
      try {
        await this.limited(() => this.ctx.container.destroy(), CLEANUP);
        // A resolved destroy is necessary, but not sufficient when recording
        // its confirmation fails. Never treat timeout/late completion as proof.
        await this.gate(async () => {
          const state = await this.ctx.storage.get('job');
          if (state?.rpcVersion === 2) {
            const at = this.now();
            if (!Number.isSafeInteger(at) || at < 0) throw fail('cleanup_failed');
            const first = state.destroyConfirmedAt;
            if (first !== undefined && (!Number.isSafeInteger(first) || first < 0 || first > at)) throw fail('cleanup_failed');
            await this.ctx.storage.put('job', { ...state, destroyConfirmedAt: first ?? at });
          }
          // No retention alarm exists yet. Introducing one must replace this
          // cleanup-only cancellation; do not infer permission to purge here.
          await this.ctx.storage.deleteAlarm();
        });
        return true;
      } catch {
        this.stopping = true; this.abort?.abort();
        try { await this.gate(async () => {
          const state = await this.ctx.storage.get('job');
          if (!state) return;
          const attempts = state.cleanupAttempts + 1;
          await this.ctx.storage.put('job', { ...state, status: 'poisoned', cleanupAttempts: attempts });
          if (attempts <= RETRIES.length) await this.ctx.storage.setAlarm(this.now() + RETRIES[attempts - 1]);
        }); } catch { /* Durable poison/alarm may be unavailable: remain closed in memory. */ }
        return false;
      }
    })();
    try { return await this.cleaning; } finally { this.cleaning = undefined; }
  }
  async cancel(jobId) {
    try { if(this.env.DOCLING_RPC_V2_ONLY==='true')throw fail('rpc_upgrade_required');return await this.cancelJob(jobId); } catch { throw fail('cleanup_failed'); }
  }
  async cancelV2(input) {
    try{
      if(this.env.DOCLING_RPC_V2_ONLY!=='true')throw fail('rpc_upgrade_required');
      const contract=rpcEnvelope(input,false);rpcTime(contract,this.now(),false);
      return await this.cancelJob(contract.jobId,contract);
    }catch{throw fail('cleanup_failed');}
  }
  async cancelJob(jobId,contract) {
    validId(jobId);
    if(this.env.DOCLING_RPC_V2_ONLY==='true'){
      contract=rpcEnvelope(contract,false);if(contract.jobId!==jobId)throw fail('input_invalid');
    }else if(contract)throw fail('rpc_upgrade_required');
    let recorded = false, destroyed = false, identityRejected = false;
    try {
      await this.ready;
      await this.gate(async () => {
        const state = await this.ctx.storage.get('job');
        if (state && (state.jobId !== jobId || (state.rpcVersion===2 && (!contract || state.notAfter!==contract.notAfter))))throw fail('job_unavailable');
        if(contract)rpcTime(contract,this.now(),false);
        this.stopping = true; this.abort?.abort();
        if(state || !contract || this.now()<contract.notAfter){
          await this.ctx.storage.put('job',state?{...state,status:state.status==='poisoned'?'poisoned':'cancelled'}:
            {jobId,status:'cancelled',deadline:this.now(),cleanupAttempts:0,...(contract?{rpcVersion:2,notAfter:contract.notAfter}:{})});
          await this.ctx.storage.setAlarm(this.now());
        }
        // An expired empty V2 still requires destroy, without a new marker.
        recorded = true;
      });
    } catch (error) {
      identityRejected = error?.message === 'job_unavailable';
    } finally {
      // A known mismatched identity must not interrupt the active job.
      if (!identityRejected) {
        this.stopping = true; this.abort?.abort();
        destroyed = await this.cleanup();
      }
    }
    if (!recorded || !destroyed) throw fail('cleanup_failed');
    return { cancelled: true };
  }
  async alarm() {
    let teardown = false;
    try {
      await this.ready;
      const state = await this.ctx.storage.get('job');
      if (!state || state.status === 'completed') return;
      if (state.status === 'running' && this.now() < state.deadline) {
        await this.ctx.storage.setAlarm(state.deadline);
        return;
      }
      teardown = true;
      this.stopping = true; this.abort?.abort();
      await this.markStopped('expired');
    } catch { teardown = true; }
    finally {
      if (teardown) {
        this.stopping = true; this.abort?.abort();
        await this.cleanup();
      }
    }
  }
}
