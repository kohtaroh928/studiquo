// Key rotation drill: follows docs/RUNBOOK.md (RB-14 and appendix A) step by step against the real
// Worker in Miniflare, with made-up keys, and checks both halves of a rotation: the new key works,
// and the old key (or an unsigned/forged credential) no longer gets in once it is retired.
//
//   cd mcp-server && npm run security:key-rotation-drill
//
// Exit codes: 0 every check as expected, 1 a check differed, 2 the drill itself failed.
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import {
  HarnessFailure, bundleWorker, createOutboundGuard, createSecrets, readWranglerConfig, repositoryRoot, startWorker, applyMigrations,
  type StoreDirectories, type SyntheticSecrets, type WorkerInstance,
} from '../restore-drill/runtime.ts';
import { createWorld, confirmEmailCode } from '../restore-drill/actors.ts';
import { redact, sha256 } from '../restore-drill/lib.ts';

interface Check { id: string; area: string; step: string; expected: string; observed: string; ok: boolean }
const checks: Check[] = [];
const key = () => randomBytes(32).toString('base64');

async function main() {
  const root = await mkdtemp(join(tmpdir(), 'studiquo-key-rotation-'));
  const dirs: StoreDirectories = { kv: join(root, 'kv'), d1: join(root, 'd1'), do: join(root, 'do') };
  for (const p of Object.values(dirs)) await mkdir(p, { recursive: true });
  const base = createSecrets();
  const inner = createOutboundGuard(base);
  const resendKeys: string[] = [];
  // Same guard, plus a record of which Resend key signed each mail.
  const guard = { state: inner.state, handler: async (request: Request) => {
    if (new URL(request.url).hostname === 'api.resend.com') resendKeys.push(request.headers.get('authorization') ?? '');
    return inner.handler(request);
  } } as typeof inner;
  const config = await readWranglerConfig();
  const script = await bundleWorker();
  const world = createWorld(guard, base);

  const secretsWith = (patch: Record<string, string | null>): SyntheticSecrets => {
    // The runbook introduces signing before it requires it; production's wrangler.jsonc already has the flag on.
    const bindings: Record<string, string> = { ...base.bindings, REQUIRE_SIGNED_TOKENS: 'false' };
    delete (bindings as Record<string, string | undefined>).TOKEN_SIGNING_KEY; // each stage sets what it needs
    for (const [name, value] of Object.entries(patch)) { if (value === null) delete (bindings as Record<string, string | undefined>)[name]; else bindings[name] = value; }
    return { ...base, bindings };
  };
  const withWorker = async <T>(patch: Record<string, string | null>, body: (w: WorkerInstance) => Promise<T>) => {
    const w = await startWorker({ script, config, secrets: secretsWith(patch), guard, dirs });
    try { return await body(w); } finally { await w.stop(); }
  };
  const record = (area: string, id: string, step: string, expected: string, observed: string) => checks.push({ area, id, step, expected, observed, ok: expected === observed });
  const plan = async (w: WorkerInstance, token: string) => String((await w.call('/api/plan', { token })).status);
  const login = async (w: WorkerInstance, email: string, password: string, ip: string) => {
    const r = await w.call('/api/auth/local/login', { json: { email, password }, ip });
    if (r.status !== 200 || !r.json?.token) throw new HarnessFailure(`Login answered ${r.status}`);
    world.sensitive.add(r.json.token);
    return r.json.token as string;
  };

  const email = `rotation-${randomBytes(5).toString('hex')}@drill.invalid`;
  const password = randomBytes(18).toString('base64url');
  const ip = '203.0.113.7';
  const [K1, K2, K3] = [key(), key(), key()];
  const S1 = key(), S2 = key();
  let legacy = '', s1 = '', s2 = '', s3 = '';

  // --- Token signing (RB-14) ---------------------------------------------------------------
  await withWorker({}, async w => {
    await applyMigrations(w.d1);
    const made = await confirmEmailCode(w, world, email, password, ip);
    if (made.status !== 200 || !made.token) throw new HarnessFailure(`Sign-up answered ${made.status}`);
    legacy = made.token;
    record('token', 'T0', 'no key set: a token has no signature and works', '200', await plan(w, legacy));
    record('token', 'T0c', 'no key set: still works on a second request', '200', await plan(w, legacy));
    record('token', 'T0b', 'no key set: the token has two parts', '2', String(legacy.split('.').length));
  });
  await withWorker({}, async w => {
    record('token', 'T0d', 'no key set, after a restart of the worker on the same stores: still works', '200', await plan(w, legacy));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K1 }, async w => {
    record('token', 'T1', 'K1 set (step 2): the earlier unsigned token still works', '200', await plan(w, legacy));
    s1 = await login(w, email, password, ip);
    record('token', 'T2', 'K1 set: a new login is signed (three parts)', '3', String(s1.split('.').length));
    record('token', 'T3', 'K1 set: the signed token works', '200', await plan(w, s1));
    const forged = `${s1.split('.').slice(0, 2).join('.')}.${randomBytes(32).toString('base64url')}`;
    record('token', 'T4', 'a token with an invented signature is refused', '401', await plan(w, forged));
    const madeUp = `${Math.floor(Date.now() / 1000)}.${randomBytes(32).toString('hex')}`;
    record('token', 'T5', 'a made-up unsigned token is refused (no such session)', '401', await plan(w, madeUp));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K1, REQUIRE_SIGNED_TOKENS: 'true' }, async w => {
    record('token', 'T6', 'REQUIRE_SIGNED_TOKENS on (step 5): the unsigned token is refused', '401', await plan(w, legacy));
    record('token', 'T7', 'REQUIRE_SIGNED_TOKENS on: the signed token works', '200', await plan(w, s1));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K2, TOKEN_SIGNING_KEY_OLD: K1, REQUIRE_SIGNED_TOKENS: 'true' }, async w => {
    record('token', 'T8', 'rotation K1 -> K2 with K1 as _OLD: the token signed with K1 still works', '200', await plan(w, s1));
    s2 = await login(w, email, password, ip);
    record('token', 'T9', 'rotation: a new login works and uses K2 (it is refused once K2 is retired, below)', '200', await plan(w, s2));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K2, REQUIRE_SIGNED_TOKENS: 'true' }, async w => {
    record('token', 'T10', '_OLD removed: the token signed with K1 is refused', '401', await plan(w, s1));
    record('token', 'T11', '_OLD removed: the token signed with K2 works', '200', await plan(w, s2));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, REQUIRE_SIGNED_TOKENS: 'true' }, async w => {
    record('token', 'T12', 'leak response, K2 replaced by K3 without _OLD: the K2 token is refused', '401', await plan(w, s2));
    s3 = await login(w, email, password, ip);
    record('token', 'T13', 'leak response: signing in again works', '200', await plan(w, s3));
  });
  await withWorker({ TOKEN_SIGNING_KEY: null, REQUIRE_SIGNED_TOKENS: 'true' }, async w => {
    // The runbook's "避ける操作": the flag without a key. The worker's own warning exists; what do requests do?
    record('token', 'T14', 'REQUIRE_SIGNED_TOKENS on but the key MISSING (runbook "避ける操作"): nothing is checked, so a signed token is accepted (fail-open; app.ts reports it as a configuration warning only)', '200', await plan(w, s3));
  });

  // --- Snapshot encryption (appendix A-1) ----------------------------------------------------
  const emailB = `rotation-b-${randomBytes(5).toString('hex')}@drill.invalid`;
  const passwordB = randomBytes(18).toString('base64url');
  const ipB = '203.0.113.8';
  let tokenB = '', tokenC = '';
  const emailC = `rotation-c-${randomBytes(5).toString('hex')}@drill.invalid`;
  const passwordC = randomBytes(18).toString('base64url');
  const snapshot = (marker: string) => ({ version: 1, notebooks: [{ id: 'n', title: marker, tags: [], pages: [] }], flashcardDecks: [], calendarEvents: [], folders: [] });
  const markerB = `rotation-note-${randomBytes(4).toString('hex')}`, markerC = `rotation-note-${randomBytes(4).toString('hex')}`;
  const readTitles = async (w: WorkerInstance, token: string, marker: string) => {
    const r = await w.call('/mcp', { token, headers: { accept: 'application/json, text/event-stream' }, json: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_notebooks', arguments: {} } } });
    return r.text.includes(marker) ? 'readable' : `unreadable(${r.status})`;
  };
  const storedPrefix = async (w: WorkerInstance, token: string) => {
    const hash = sha256(token);
    const raw = await w.kv.get(`snapshot:${hash}`);
    return raw === null ? 'absent' : raw.startsWith('enc1.') ? raw.split('.').slice(0, 2).join('.') : 'plaintext';
  };
  await withWorker({ TOKEN_SIGNING_KEY: K3, SNAPSHOT_ENCRYPTION_KEY: S1 }, async w => {
    tokenB = await login(w, email, password, ip); // reuse the first account for B
    const madeC = await confirmEmailCode(w, world, emailC, passwordC, '203.0.113.9');
    tokenC = madeC.token ?? '';
    for (const [token, marker] of [[tokenB, markerB], [tokenC, markerC]] as const) {
      const put = await w.call('/api/snapshot', { method: 'PUT', token, json: snapshot(marker) });
      if (put.status !== 200) throw new HarnessFailure(`Snapshot upload answered ${put.status}`);
    }
    record('snapshot', 'S0', 'key S1 without an ID: stored under id 1', 'enc1.1', await storedPrefix(w, tokenB));
    record('snapshot', 'S0b', 'key S1: readable through MCP', 'readable', await readTitles(w, tokenB, markerB));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, SNAPSHOT_ENCRYPTION_KEY: S2, SNAPSHOT_ENCRYPTION_KEY_ID: '2', SNAPSHOT_ENCRYPTION_KEY_OLD: S1, SNAPSHOT_ENCRYPTION_KEY_OLD_ID: '1' }, async w => {
    record('snapshot', 'S1', 'documented rotation (KEY=S2 id 2, OLD=S1 id 1): the old record is readable', 'readable', await readTitles(w, tokenB, markerB));
    await w.call('/api/snapshot', { method: 'PUT', token: tokenB, json: snapshot(markerB) }); // B syncs again
    record('snapshot', 'S2', 'after B syncs again the record is under the new id', 'enc1.2', await storedPrefix(w, tokenB));
    record('snapshot', 'S3', 'C has not synced yet: still under id 1', 'enc1.1', await storedPrefix(w, tokenC));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, SNAPSHOT_ENCRYPTION_KEY: S2, SNAPSHOT_ENCRYPTION_KEY_ID: '2' }, async w => {
    record('snapshot', 'S4', 'OLD removed: the record B re-synced is readable', 'readable', await readTitles(w, tokenB, markerB));
    record('snapshot', 'S5', 'OLD removed: the record C never re-synced is NOT readable (the documented cost of retiring S1)', 'unreadable(200)', await readTitles(w, tokenC, markerC));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, SNAPSHOT_ENCRYPTION_KEY: S2, SNAPSHOT_ENCRYPTION_KEY_ID: '2', SNAPSHOT_ENCRYPTION_KEY_OLD: S1 }, async w => {
    record('snapshot', 'S6', 'the runbook\'s trap: OLD without OLD_ID (stored id 1, kept as 0): the record cannot be read', 'unreadable(200)', await readTitles(w, tokenC, markerC));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, SNAPSHOT_ENCRYPTION_KEY: S2, SNAPSHOT_ENCRYPTION_KEY_OLD: S1, SNAPSHOT_ENCRYPTION_KEY_OLD_ID: '1' }, async w => {
    record('snapshot', 'S7', 'the other trap: new key without an ID (defaults to 1, the same as OLD_ID 1): the old record cannot be read', 'unreadable(200)', await readTitles(w, tokenC, markerC));
  });

  // --- RevenueCat webhook secret (appendix A-1) ----------------------------------------------
  const newSecret = randomBytes(32).toString('base64url');
  const event = (secret: string | undefined) => ({ authorization: secret ?? '' });
  const post = (w: WorkerInstance, header: string) => w.call('/api/admin/revenuecat-webhook', { headers: { authorization: header }, json: { event: { id: randomBytes(6).toString('hex'), type: 'TEST', app_user_id: 'rotation-none', environment: 'PRODUCTION', event_timestamp_ms: Date.now() } } }).then(r => String(r.status));
  await withWorker({ TOKEN_SIGNING_KEY: K3, REVENUECAT_WEBHOOK_SECRET: base.webhookSecret }, async w => {
    record('webhook', 'W0', 'current secret is accepted', '200', await post(w, base.webhookSecret));
  });
  await withWorker({ TOKEN_SIGNING_KEY: K3, REVENUECAT_WEBHOOK_SECRET: newSecret }, async w => {
    record('webhook', 'W1', 'after rotation the old secret is refused', '401', await post(w, base.webhookSecret));
    record('webhook', 'W2', 'after rotation the new secret is accepted', '200', await post(w, newSecret));
    record('webhook', 'W3', 'a header with an added "Bearer " prefix is refused (exact match, as the runbook says)', '401', await post(w, `Bearer ${newSecret}`));
    record('webhook', 'W4', 'an empty header is refused', '401', await post(w, event(undefined).authorization));
  });

  // --- Mail key (appendix A-1: Resend) ---------------------------------------------------------
  const newResend = `drill-${randomBytes(16).toString('hex')}`;
  resendKeys.length = 0;
  await withWorker({ TOKEN_SIGNING_KEY: K3, RESEND_API_KEY: newResend }, async w => {
    await w.call('/api/auth/email/send-code', { json: { email: `rotation-mail-${randomBytes(4).toString('hex')}@drill.invalid` }, ip: '203.0.113.20' });
  });
  record('mail', 'M1', 'after rotation the mail is sent with the new key only', `Bearer ${newResend}`, resendKeys.at(-1) ?? 'no mail');
  record('mail', 'M2', 'the old mail key is not used any more', 'false', String(resendKeys.some(value => value === `Bearer ${base.bindings.RESEND_API_KEY}`) && resendKeys.at(-1) !== `Bearer ${newResend}`));

  // --- Report ----------------------------------------------------------------------------------
  const unexpected = guard.state.unexpected.length;
  checks.push({ id: 'G1', area: 'harness', step: 'no outbound call outside the local fakes', expected: '0', observed: String(unexpected), ok: unexpected === 0 });
  const gone = await rm(root, { recursive: true, force: true }).then(() => true, () => false);
  checks.push({ id: 'G2', area: 'harness', step: 'temporary stores removed', expected: 'true', observed: String(gone), ok: gone });
  const outDir = resolve(repositoryRoot, 'security-reports/key-rotation');
  await mkdir(outDir, { recursive: true });
  const text = ['| id | step | expected | observed | |', '|---|---|---|---|---|', ...checks.map(c => `| ${c.id} | ${c.step} | ${c.expected} | ${redact(c.observed)} | ${c.ok ? 'ok' : '**DIFFERS**'} |`)].join('\n');
  await writeFile(join(outDir, 'key-rotation.json'), JSON.stringify({ checks }, null, 1));
  await writeFile(join(outDir, 'key-rotation.md'), text);
  console.log(text);
  return checks.every(c => c.ok) ? 0 : 1;
}

main().then(code => process.exit(code), error => { console.error(error instanceof HarnessFailure ? `Drill failure: ${error.message}` : error); process.exit(2); });
