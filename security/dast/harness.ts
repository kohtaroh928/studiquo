import { createRequire } from 'node:module';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(resolve(root, 'mcp-server/package.json'));
const { Miniflare, convertV4MiniflareOptions, Log, LogLevel } = require('miniflare');
const { build } = require('esbuild');
export const hash = (value: string | NodeJS.ArrayBufferView<ArrayBufferLike>) => createHash('sha256').update(value).digest('hex');
export const scanPaths = ['/health', '/privacy', '/terms', '/api/actions', '/api/mcp/inbox', '/api/mcp/connections'];
export function allowedRequest(method: string | undefined, target: string) {
  // Origin-form only; never accept a scanner-supplied destination or CONNECT.
  if (method !== 'GET' || !target.startsWith('/') || target.startsWith('//')) return false;
  const url = new URL(target, 'http://127.0.0.1:8090');
  return url.origin === 'http://127.0.0.1:8090' && scanPaths.includes(url.pathname);
}
/** The slice of a Miniflare KV namespace the harness uses. */
interface Kv { put(key: string, value: string): Promise<void>; delete(key: string): Promise<void> }

/** Reads a response body as the shape the caller expects (the Worker is the code under test, so the shape is a claim, checked by the asserts that follow). */
const body = <T>(response: Response) => response.json() as Promise<T>;

const deadline = async <T>(promise: Promise<T>, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try { return await Promise.race([promise, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), 30000); })]); } finally { clearTimeout(timer); }
};
export async function createHarness() {
  const bundled = await build({ entryPoints: [resolve(root, 'mcp-server/src/worker.ts')], bundle: true, write: false, format: 'esm', platform: 'neutral', mainFields: ['browser', 'module', 'main'], conditions: ['workerd', 'worker', 'browser'], external: ['cloudflare:workers', 'node:*'], logLevel: 'silent' });
  const stats = { outboundBlocked: 0 };
  const options = {
    host: '127.0.0.1', port: 0, cf: false, kvPersist: false, d1Persist: false, durableObjectsPersist: false, cachePersist: false, modules: true, script: bundled.outputFiles[0].text,
    // Stable Miniflare 4 supports this date; production uses 2026-08-27.
    compatibilityDate: '2026-07-30', compatibilityFlags: ['nodejs_compat'],
    ratelimits: { RATE_LIMIT_APPLE_AUTH: { namespace_id: 'dast-apple', simple: { limit: 5, period: 60 } } },
    kvNamespaces: ['STUDIQUO_DATA'], d1Databases: ['ADMIN_DB'],
    durableObjects: Object.fromEntries(['ChatRoom', 'UserRegistry', 'DocumentRoom', 'RateCounter', 'MCPInbox'].map((className, index) => [['CHAT_ROOM', 'USER_REGISTRY', 'DOCUMENT_ROOM', 'RATE_COUNTER', 'MCP_INBOX'][index], { className, useSQLite: true }])),
    bindings: { PRIVACY_RETENTION_ENABLED: 'false', AI_PROVIDER_APPROVED: 'false' },
    outboundService: () => { stats.outboundBlocked++; return new Response('External requests disabled', { status: 502 }); },
    log: new Log(LogLevel.NONE),
  };
  const mf = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(options) : options);
  try {
    await deadline(mf.ready, 'Workers startup');
    const kv = await deadline<Kv>(mf.getKVNamespace('STUDIQUO_DATA'), 'KV startup');
    const users = [];
    for (const label of ['A', 'B']) {
      const issuedAt = Math.floor(Date.now() / 1000);
      const token = `${issuedAt}.${randomBytes(32).toString('hex')}`;
      const sub = `dast-${label}-${randomUUID()}`;
      const key = hash(token);
      const snapshot = { version: 1, notebooks: [{ id: label, title: `Synthetic ${label}`, pages: [] }], flashcardDecks: [], calendarEvents: [], folders: [] };
      await kv.put(`session:${key}`, JSON.stringify({ sub, issuedAt }));
      await kv.put(`snapshot:${key}`, JSON.stringify(snapshot));
      await kv.put(`actions:${key}`, JSON.stringify([{ type: 'synthetic', label }]));
      users.push({ label, token, sub, key, inboxId: randomUUID() });
    }
    const inbox = await mf.getDurableObjectNamespace('MCP_INBOX');
    for (const user of users) await inbox.get(inbox.idFromName(hash(`mcp-account:${user.sub}`))).enqueue(user.inboxId, 'create_document', { title: user.label, body: 'Synthetic fixture' }, 'DAST');
    const request = (path: string, token?: string | null, init: RequestInit & { headers?: Record<string, string> } = {}) => deadline<Response>(mf.dispatchFetch(`http://127.0.0.1:8090${path}`, { ...init, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...init.headers }, redirect: 'manual' }), 'Worker request');
    return { mf, kv, users, stats, request, close: () => mf.dispose() };
  } catch (error) { await mf.dispose(); throw error; }
}
export type Harness = Awaited<ReturnType<typeof createHarness>>;

export async function runContracts(harness: Harness) {
  const { request, users: [a, b], kv } = harness;
  let passed = 0;
  const check = async (name: string, callback: () => Promise<void>) => { try { await callback(); passed++; } catch { throw new Error(`Contract failed: ${name}`); } };
  for (const user of [a, b]) {
    await check(`authenticated-actions-${user.label}`, async () => {
      const response = await request('/api/actions', user.token);
      assert.equal(response.status, 200); assert.deepEqual(await response.json(), [{ type: 'synthetic', label: user.label }]);
    });
    await check(`authenticated-inbox-${user.label}`, async () => {
      const response = await request('/api/mcp/inbox', user.token);
      assert.equal(response.status, 200); const data = await body<{ id: string; payload: { title: string } }[]>(response);
      assert.equal(data.length, 1); assert.equal(data[0].id, user.inboxId); assert.equal(data[0].payload.title, user.label);
    });
    await check(`mcp-read-isolation-${user.label}`, async () => {
      const response = await request('/mcp', user.token, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_notebooks', arguments: {} } }) });
      assert.equal(response.status, 200); const data = await body<{ result: { structuredContent: { result: { title: string }[] } } }>(response);
      assert.equal(data.result.structuredContent.result[0].title, `Synthetic ${user.label}`);
    });
  }
  await check('cross-account-inbox-acknowledgement', async () => {
    const response = await request(`/api/mcp/inbox/${b.inboxId}`, a.token, { method: 'POST' });
    assert.equal(response.status, 200); assert.equal((await body<{ status: string }>(response)).status, 'missing');
    assert.equal((await body<{ id: string }[]>(await request('/api/mcp/inbox', b.token)))[0].id, b.inboxId);
  });
  for (const path of ['/api/actions', '/api/mcp/inbox', '/mcp']) {
    await check(`anonymous-${path}`, async () => assert.equal((await request(path)).status, 401));
    await check(`fabricated-${path}`, async () => assert.equal((await request(path, `${Math.floor(Date.now()/1000)}.${randomBytes(32).toString('hex')}`)).status, 401));
    const expired = `1.${randomBytes(32).toString('hex')}`;
    await kv.put(`session:${hash(expired)}`, JSON.stringify({ sub: a.sub, issuedAt: 1 }));
    await check(`expired-${path}`, async () => assert.equal((await request(path, expired)).status, 401));
  }
  await check('admin-forbidden', async () => assert.equal((await request('/api/admin/stats', a.token)).status, 403));
  // Exercise the real revocation endpoint, rather than replacing authentication.
  const revoke = await request('/api/session/revoke', b.token, { method: 'POST' });
  assert.equal(revoke.status, 200);
  for (const path of ['/api/actions', '/api/mcp/inbox', '/mcp']) await check(`revoked-${path}`, async () => assert.equal((await request(path, b.token)).status, 401));
  return { status: 'passed', passed, authenticatedUsers: 2 };
}
