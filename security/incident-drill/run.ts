// Checks the "stop it" switches that docs/RUNBOOK.md (RB-18) and docs/incidents/drills/ rely on,
// against the real Worker in Miniflare: does each switch stop what it says, and leave alone what
// the runbook says it leaves alone?
//
//   cd mcp-server && npm run security:incident-drill
//
// Exit codes: 0 every claim holds, 1 a claim differs, 2 the drill itself failed.
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import {
  HarnessFailure, bundleWorker, createOutboundGuard, createSecrets, readWranglerConfig, repositoryRoot, startWorker, applyMigrations,
  type WorkerInstance,
} from '../restore-drill/runtime.ts';
import { createWorld, setPasswordWithCode } from '../restore-drill/actors.ts';

interface Check { id: string; claim: string; expected: string; observed: string; ok: boolean }
const checks: Check[] = [];

async function main() {
  const root = await mkdtemp(join(tmpdir(), 'studiquo-incident-drill-'));
  const dirs = { kv: join(root, 'kv'), d1: join(root, 'd1'), do: join(root, 'do') };
  for (const p of Object.values(dirs)) await mkdir(p, { recursive: true });
  const secrets = createSecrets();
  const guard = createOutboundGuard(secrets);
  const config = await readWranglerConfig();
  const script = await bundleWorker();
  const world = createWorld(guard, secrets);
  const withVars = async <T>(vars: Record<string, string>, body: (w: WorkerInstance) => Promise<T>) => {
    const w = await startWorker({ script, config: { ...config, vars: { ...config.vars, ...vars } }, secrets, guard, dirs });
    try { return await body(w); } finally { await w.stop(); }
  };
  const record = (id: string, claim: string, expected: string, observed: string) => checks.push({ id, claim, expected, observed, ok: expected === observed });
  const status = async (w: WorkerInstance, path: string, options: Parameters<WorkerInstance['call']>[1] = {}) => {
    const r = await w.call(path, options);
    return `${r.status}${r.json?.code ? `:${r.json.code}` : ''}`;
  };

  const email = `incident-${randomBytes(5).toString('hex')}@drill.invalid`;
  const password = randomBytes(18).toString('base64url');
  let token = '', second = '';
  // Baseline: the production configuration with nothing switched off.
  await withVars({ DISABLED_FEATURES: '', MAINTENANCE_MODE: '', MIN_APP_BUILD: '' }, async w => {
    await applyMigrations(w.d1);
    const made = await setPasswordWithCode(w, world, email, password, '203.0.113.30');
    if (made.status !== 200 || !made.token) throw new HarnessFailure(`Sign-up answered ${made.status}`);
    token = made.token;
    const again = await w.call('/api/auth/local/login', { json: { email, password }, ip: '203.0.113.30' });
    second = again.json.token;
    record('B0', 'baseline: a signed-in request works', '200', await status(w, '/api/plan', { token }));
    record('B1', 'baseline: chat is open', '200', await status(w, '/api/chat/friends', { token }));
  });

  const probe = {
    ai: (w: WorkerInstance) => status(w, '/api/ai/models', { token }),
    chat: (w: WorkerInstance) => status(w, '/api/chat/friends', { token }),
    collab: (w: WorkerInstance) => status(w, `/api/document/rooms/${'a'.repeat(64)}/init`, { token, json: { blocks: [] } }),
    mcp: (w: WorkerInstance) => status(w, '/api/mcp/connections', { token }),
    signin: (w: WorkerInstance) => status(w, '/api/auth/local/login', { json: { email, password }, ip: '203.0.113.31' }),
    email: (w: WorkerInstance) => status(w, '/api/auth/email/send-code', { json: { email: `x-${randomBytes(3).toString('hex')}@drill.invalid` }, ip: '203.0.113.32' }),
  };
  for (const feature of Object.keys(probe) as (keyof typeof probe)[]) {
    // A fresh session for the sign-out check, minted while nothing is switched off.
    await withVars({ DISABLED_FEATURES: '' }, async w => {
      second = (await w.call('/api/auth/local/login', { json: { email, password }, ip: '203.0.113.30' })).json.token;
    });
    await withVars({ DISABLED_FEATURES: feature }, async w => {
      record(`F-${feature}`, `DISABLED_FEATURES=${feature}: ${feature} answers 503 feature_disabled`, '503:feature_disabled', await probe[feature](w));
      for (const other of Object.keys(probe) as (keyof typeof probe)[]) {
        if (other === feature) continue;
        const observed = await probe[other](w);
        record(`F-${feature}-keeps-${other}`, `DISABLED_FEATURES=${feature}: ${other} is not stopped`, 'not-503', observed.startsWith('503:feature_disabled') ? observed : 'not-503');
      }
      record(`F-${feature}-health`, `DISABLED_FEATURES=${feature}: /health lists it`, 'true', String(JSON.stringify((await w.call('/health')).json ?? {}).includes(feature)));
      record(`F-${feature}-exit`, `DISABLED_FEATURES=${feature}: sign-out (POST /api/session/revoke) still works`, '200', await status(w, '/api/session/revoke', { method: 'POST', token: second }));
    });
  }
  await withVars({ DISABLED_FEATURES: '' }, async w => {
    second = (await w.call('/api/auth/local/login', { json: { email, password }, ip: '203.0.113.30' })).json.token;
  });
  await withVars({ DISABLED_FEATURES: 'chat,collab' }, async w => {
    record('F-pair', 'DISABLED_FEATURES="chat,collab" (drill 3) stops both', '503:feature_disabled+503:feature_disabled', `${await probe.chat(w)}+${await probe.collab(w)}`);
  });
  await withVars({ DISABLED_FEATURES: 'chats' }, async w => {
    record('F-typo', 'a misspelt name stops nothing and /health does not list it', 'true', String(!JSON.stringify((await w.call('/health')).json ?? {}).includes('chats') && (await probe.chat(w)) === '200'));
  });

  await withVars({ MAINTENANCE_MODE: 'true' }, async w => {
    record('M1', 'MAINTENANCE_MODE: an app API answers 503 maintenance', '503:maintenance', await status(w, '/api/plan', { token }));
    record('M2', 'MAINTENANCE_MODE: /health stays up', '200', await status(w, '/health'));
    record('M3', 'RB-18 says MAINTENANCE_MODE does not stop sign-out', '200', await status(w, '/api/session/revoke', { method: 'POST', token: second }));
    record('M4', 'RB-18 says MAINTENANCE_MODE does not stop account deletion (checked with a wrong confirmation, so nothing is deleted)', 'not-503', (await status(w, '/api/account', { method: 'DELETE', token, json: { confirmation: 'no' } })).startsWith('503') ? '503' : 'not-503');
    record('M5', 'the legal page stays up', '200', await status(w, '/privacy'));
  });

  await withVars({ MIN_APP_BUILD: '9999' }, async w => {
    const r = await w.call('/api/plan', { token, headers: { 'user-agent': 'studiquo/1 CFNetwork/1' } });
    record('U1', 'MIN_APP_BUILD above the build: the app gets 426 app_update_required', '426:app_update_required', `${r.status}${r.json?.code ? `:${r.json.code}` : ''}`);
    record('U2', 'MIN_APP_BUILD: a client that is not the app is not turned away', '200', await status(w, '/api/plan', { token, headers: { 'user-agent': 'curl/8' } }));
  });

  await withVars({ AI_PROVIDER_APPROVED: 'false' }, async w => {
    const r = await w.call('/api/ai/chat', { token, json: { messages: [{ role: 'user', content: 'x' }] }, headers: { 'x-studiquo-ai-consent': 'openai-v1', 'x-studiquo-age': 'adult' } });
    record('A1', 'AI_PROVIDER_APPROVED=false: AI answers 503', '503', String(r.status));
    record('A2', 'AI_PROVIDER_APPROVED=false: the rest still works', '200', await status(w, '/api/plan', { token }));
  });

  record('G1', 'no outbound call outside the local fakes', '0', String(guard.state.unexpected.length));
  const removed = await rm(root, { recursive: true, force: true }).then(() => true, () => false);
  record('G2', 'temporary stores removed', 'true', String(removed));

  const outDir = resolve(repositoryRoot, 'security-reports/incident-drill');
  await mkdir(outDir, { recursive: true });
  const text = ['| id | claim | expected | observed | |', '|---|---|---|---|---|', ...checks.map(c => `| ${c.id} | ${c.claim} | ${c.expected} | ${c.observed} | ${c.ok ? 'ok' : '**DIFFERS**'} |`)].join('\n');
  await writeFile(join(outDir, 'incident-drill.md'), text);
  await writeFile(join(outDir, 'incident-drill.json'), JSON.stringify({ checks }, null, 1));
  console.log(text);
  return checks.every(c => c.ok) ? 0 : 1;
}

main().then(code => process.exit(code), error => { console.error(error instanceof HarnessFailure ? `Drill failure: ${error.message}` : error); process.exit(2); });
