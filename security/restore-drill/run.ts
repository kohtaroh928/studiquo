// Restore drill: does restoring an old copy of D1, KV or the Durable Objects bring back
// what was revoked or deleted afterwards? Runs the real Worker in Miniflare only.
//
//   node security/restore-drill/run.ts            (from mcp-server/: npm run security:restore-drill)
//
// Exit codes: 0 nothing revived, 1 something revived or left inconsistent, 2 the drill itself failed.
import { cp, mkdtemp, mkdir, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  HarnessFailure, bundleWorker, createOutboundGuard, createSecrets, readWranglerConfig, repositoryRoot, startWorker, applyMigrations,
  type StoreDirectories, type WorkerInstance,
} from './runtime.ts';
import {
  actorCell, kvCategory, kvFamily, nonDiscriminating, planReconcile, redact, verdictFor, type ProbeKind, type ProbeShape, type Verdict,
} from './lib.ts';
import {
  applyRevocations, createPostBackupActivity, createWorld, exportKv, prepareBackupPoint, runCronUntilDrained,
  type KvExport, type World,
} from './actors.ts';

interface Probe extends ProbeShape {
  actor: string;
  what: string;
  run(w: WorkerInstance, world: World): Promise<string>;
}

// Probes that spend a one-time credential: not repeated after the job run.
const MUTATING = new Set(['E:revoked-mcp-refresh', 'E2:used-refresh-token', 'B:login-old-password', 'D:login-old-password', 'J:login-old-password', 'I2:login-old-password']);

const plan = async (w: WorkerInstance, token: string | undefined) => {
  if (!token) return 'no-token';
  const r = await w.call('/api/plan', { token });
  return `${r.status}:${r.json?.plan ?? r.json?.tier ?? ''}`;
};
const mcpCall = async (w: WorkerInstance, accessToken: string) => {
  const r = await w.call('/mcp', {
    token: accessToken, headers: { accept: 'application/json, text/event-stream' },
    json: { jsonrpc: '2.0', id: 9, method: 'tools/list', params: {} },
  });
  return String(r.status);
};
const refresh = async (w: WorkerInstance, token: string, clientId: string) => {
  const r = await w.call('/oauth/token', { form: { grant_type: 'refresh_token', refresh_token: token, client_id: clientId } });
  return String(r.status);
};
const login = async (w: WorkerInstance, account: { email: string; password: string; ip: string }) => {
  const r = await w.call('/api/auth/local/login', { json: { email: account.email, password: account.password }, ip: account.ip });
  return String(r.status);
};
const roomHas = async (w: WorkerInstance, world: World, room: string, asAccount: string, marker: string) => {
  const r = await w.call(`/api/chat/rooms/${world.rooms[room]}/messages`, { token: world.accounts[asAccount].token });
  return `${r.status}:${r.text.includes(world.markers[marker]) ? 'present' : 'absent'}`;
};

function buildProbes(): Probe[] {
  const p = (actor: string, what: string, kind: ProbeKind, stage: 'backup' | 'post', run: Probe['run']): Probe => ({ id: `${actor}:${what}`, actor, what, kind, stage, run });
  return [
    p('A', 'plan', 'control', 'backup', (w, x) => plan(w, x.accounts.A.token)),
    p('A', 'library-id', 'control', 'backup', async (w, x) => { const r = await w.call('/api/account/library-id', { token: x.accounts.A.token }); return `${r.status}:${r.json?.libraryID === x.libraryIds.A}`; }),
    p('A', 'mcp-access', 'control', 'backup', (w, x) => mcpCall(w, x.mcp.A.accessToken)),
    p('A', 'message-ap', 'control', 'backup', (w, x) => roomHas(w, x, 'AP', 'A', 'A')),
    p('B', 'session', 'access', 'backup', (w, x) => plan(w, x.accounts.B.token)),
    p('B', 'mcp-access', 'access', 'backup', (w, x) => mcpCall(w, x.mcp.B.accessToken)),
    p('B', 'plan-after-reregistration-lookup', 'access', 'backup', async (w, x) => { const r = await w.call('/api/entitlements', { token: x.accounts.B.token }); return String(r.status); }),
    p('B', 'login-old-password', 'access', 'backup', (w, x) => login(w, x.accounts.B)),
    p('D', 'login-old-password', 'access', 'backup', (w, x) => login(w, x.accounts.D)),
    p('J', 'login-old-password', 'access', 'backup', (w, x) => login(w, x.accounts.J)),
    p('I2', 'login-old-password', 'access', 'backup', (w, x) => login(w, x.accounts.I2)),
    p('C', 'session-after-logout', 'access', 'backup', (w, x) => plan(w, x.accounts.C.token)),
    p('D', 'old-session-after-reset', 'access', 'backup', (w, x) => plan(w, x.accounts.D.token)),
    p('D', 'new-session', 'post-backup', 'post', (w, x) => plan(w, x.accounts.D.newToken)),
    p('E', 'revoked-mcp-access', 'access', 'backup', (w, x) => mcpCall(w, x.mcp.E.accessToken)),
    p('E', 'revoked-mcp-refresh', 'access', 'backup', (w, x) => refresh(w, x.mcp.E.refreshToken, x.mcp.E.clientId)),
    p('E2', 'used-refresh-token', 'access', 'backup', (w, x) => refresh(w, x.mcp.E2.refreshToken, x.mcp.E2.clientId)),
    p('F', 'suspended-account-session', 'access', 'backup', async (w, x) => { const r = await w.call('/api/chat/me', { token: x.accounts.F.token, json: { name: 'Drill F' } }); return String(r.status); }),
    p('F2', 'chat-suspended', 'access', 'backup', async (w, x) => { const r = await w.call('/api/chat/me', { token: x.accounts.F2.token, json: { name: 'Drill F2' } }); return String(r.status); }),
    p('G', 'cancelled-message', 'data', 'backup', (w, x) => roomHas(w, x, 'GP', 'P', 'G1')),
    p('G', 'operator-removed-message', 'data', 'backup', (w, x) => roomHas(w, x, 'GP', 'P', 'G2')),
    p('G', 'friend-list-after-removal', 'data', 'backup', async (w, x) => { const r = await w.call('/api/chat/friends', { token: x.accounts.G.token }); return `${r.status}:${JSON.stringify(r.json).includes(x.accounts.P.code ?? '?') ? 'P-listed' : 'P-absent'}`; }),
    p('G', 'blocked-list', 'data', 'backup', async (w, x) => { const r = await w.call('/api/chat/friends/blocked', { token: x.accounts.G.token }); return `${r.status}:${r.text.length > 4 ? 'has-entries' : 'empty'}`; }),
    p('H', 'plan-after-subscription-end', 'access', 'backup', (w, x) => plan(w, x.accounts.H.token)),
    p('I', 'passkeys-after-removal', 'data', 'backup', async (w, x) => { const r = await w.call('/api/passkeys/status', { token: x.accounts.I.token }); return `${r.status}:${JSON.stringify(r.json)}`; }),
    p('I2', 'old-session-after-reset', 'access', 'backup', (w, x) => plan(w, x.accounts.I2.token)),
    p('I2', 'new-session', 'post-backup', 'post', (w, x) => plan(w, x.accounts.I2.newToken)),
    p('J', 'old-session-after-reregistration', 'access', 'backup', (w, x) => plan(w, x.accounts.J.token)),
    p('J', 'new-session', 'post-backup', 'post', (w, x) => plan(w, x.accounts.J.newToken)),
    p('J', 'new-plan', 'post-backup', 'post', async (w, x) => { const r = await w.call('/api/plan', { token: x.accounts.J.newToken }); return `${r.status}:${r.json?.plan ?? ''}`; }),
    p('JR', 'old-session-deleted-before-backup', 'control', 'backup', (w, x) => plan(w, x.accounts.JR.token)),
    p('JR', 'new-session', 'post-backup', 'post', (w, x) => plan(w, x.accounts.JR.newToken)),
    p('K', 'post-backup-account', 'post-backup', 'post', (w, x) => plan(w, x.accounts.K?.token)),
    p('K', 'post-backup-message', 'post-backup', 'post', (w, x) => roomHas(w, x, 'AK', 'A', 'K')),
    p('A', 'post-backup-message-ap', 'post-backup', 'post', (w, x) => roomHas(w, x, 'AP', 'A', 'A-after-backup')),
  ];
}

async function observe(w: WorkerInstance, world: World, probes: Probe[], stage: 'backup' | 'all') {
  const seen: Record<string, string> = {};
  for (const probe of probes) {
    if (stage === 'backup' && probe.stage === 'post') continue;
    try { seen[probe.id] = await probe.run(w, world); } catch (error) { seen[probe.id] = `error:${redact(error instanceof Error ? error.message : String(error))}`; }
  }
  return seen;
}

const exists = (path: string) => access(path).then(() => true, () => false);

async function copyStores(from: StoreDirectories, to: StoreDirectories, which: (keyof StoreDirectories)[]) {
  for (const key of which) {
    await rm(to[key], { recursive: true, force: true });
    if (await exists(from[key])) await cp(from[key], to[key], { recursive: true });
    else await mkdir(to[key], { recursive: true });
  }
}

interface Scenario { name: string; description: string; apply(dir: StoreDirectories, w?: WorkerInstance): Promise<void>; afterStart?(w: WorkerInstance): Promise<void> }

async function main() {
  const began = Date.now();
  const root = await mkdtemp(join(tmpdir(), 'studiquo-restore-drill-'));
  const outDir = resolve(repositoryRoot, 'security-reports/restore-drill');
  await mkdir(outDir, { recursive: true });
  const dirs = (name: string): StoreDirectories => ({ kv: join(root, name, 'kv'), d1: join(root, name, 'd1'), do: join(root, name, 'do') });
  const live = dirs('live'), backup = dirs('backup'), post = dirs('post');
  for (const d of [live, backup, post]) for (const p of Object.values(d)) await mkdir(p, { recursive: true });

  const secrets = createSecrets();
  const guard = createOutboundGuard(secrets);
  const config = await readWranglerConfig();
  const script = await bundleWorker();
  const world = createWorld(guard, secrets);
  const probes = buildProbes();
  const timings: Record<string, number> = {};
  const time = async <T>(label: string, work: () => Promise<T>) => { const t = Date.now(); try { return await work(); } finally { timings[label] = Date.now() - t; } };

  let atBackup: Record<string, string> = {}, baseline: Record<string, string> = {};
  let kvAtBackup: KvExport = [];
  let migrations = { files: 0, statements: 0, expectedTables: [] as string[] };

  // Some probes change state (a refresh token can be used once), so the stores are copied
  // BEFORE any probe runs, and every observation is made on its own scratch copy.
  const observeOn = async (name: string, from: StoreDirectories, stage: 'backup' | 'all') => {
    const scratch = dirs(name);
    for (const p of Object.values(scratch)) await mkdir(p, { recursive: true });
    await copyStores(from, scratch, ['kv', 'd1', 'do']);
    const inst = await startWorker({ script, config, secrets, guard, dirs: scratch });
    try { return await observe(inst, world, probes, stage); } finally { await inst.stop(); }
  };

  // 1. the backup point
  let w = await startWorker({ script, config, secrets, guard, dirs: live });
  try {
    migrations = await applyMigrations(w.d1);
    await time('prepare backup point', () => prepareBackupPoint(w, world));
    kvAtBackup = await exportKv(w);
  } finally { await w.stop(); }
  await copyStores(live, backup, ['kv', 'd1', 'do']);
  atBackup = await observeOn('observe-backup', backup, 'backup');

  // 2. revocations and deletions, then work that has nothing to do with them
  w = await startWorker({ script, config, secrets, guard, dirs: live });
  let kvPost: KvExport = [];
  try {
    await time('revocations', () => applyRevocations(w, world));
    await time('post-backup activity', () => createPostBackupActivity(w, world));
    kvPost = await exportKv(w);
  } finally { await w.stop(); }
  await copyStores(live, post, ['kv', 'd1', 'do']);
  baseline = await observeOn('observe-post', post, 'all');

  // 3. restore scenarios
  const subsets: (keyof StoreDirectories)[][] = [['kv'], ['d1'], ['do'], ['kv', 'd1'], ['kv', 'do'], ['d1', 'do'], ['kv', 'd1', 'do']];
  const scenarios: Scenario[] = [
    { name: 'none (control)', description: 'Nothing restored: the baseline must reproduce', apply: async d => copyStores(post, d, ['kv', 'd1', 'do']) },
    ...subsets.map((set): Scenario => ({
      name: set.join('+').toUpperCase().replace(/DO/g, 'DO'),
      description: `Whole-store restore of ${set.join(', ')} to the backup point`,
      apply: async d => { await copyStores(post, d, ['kv', 'd1', 'do']); await copyStores(backup, d, set); },
    })),
    ...([['kv-export-all', 'KV emptied, then every exported key written back'],
         ['kv-export-selective', 'KV emptied, then every exported key written back except sessions, tokens, codes and snapshots'],
         ['kv-export-all+reconcile', 'As kv-export-all, then the pre-restore state is put back over it (planReconcile)'],
         ['kv-export-selective+reconcile', 'As kv-export-selective, then the pre-restore state is put back over it (planReconcile)']] as const).map(([name, description]): Scenario => ({
      name, description,
      apply: async d => { await copyStores(post, d, ['kv', 'd1', 'do']); await rm(d.kv, { recursive: true, force: true }); await mkdir(d.kv, { recursive: true }); },
      afterStart: async inst => {
        for (const entry of kvAtBackup) {
          if (name.startsWith('kv-export-selective') && kvCategory(entry.name) === 'must-not-restore') continue;
          await inst.kv.put(entry.name, entry.value, entry.expiration ? { expiration: entry.expiration } : undefined);
        }
        if (name.endsWith('+reconcile')) {
          const plan = planReconcile(kvPost, await exportKv(inst));
          for (const item of plan.put) await inst.kv.put(item.name, item.value, item.expiration ? { expiration: item.expiration } : undefined);
          for (const key of plan.remove) await (inst.kv as unknown as { delete(key: string): Promise<void> }).delete(key);
        }
      },
    })),
  ];

  const results: { scenario: Scenario; seen: Record<string, string>; afterCron: Record<string, string>; cronError?: string; verdicts: Record<string, Verdict>; seconds: number; serverErrors: number }[] = [];
  for (const scenario of scenarios) {
    const run = dirs(`scenario-${results.length}`);
    for (const p of Object.values(run)) await mkdir(p, { recursive: true });
    const t0 = Date.now();
    await scenario.apply(run);
    const inst = await startWorker({ script, config, secrets, guard, dirs: run });
    try {
      if (scenario.afterStart) await scenario.afterStart(inst);
      const errorsBefore = inst.serverErrors.length;
      const seen = await observe(inst, world, probes, 'all');
      let afterCron: Record<string, string> = {}, cronError: string | undefined;
      try { await runCronUntilDrained(inst); afterCron = await observe(inst, world, probes.filter(p => !MUTATING.has(p.id)), 'all'); } catch (error) { cronError = redact(error instanceof Error ? error.message : String(error)); }
      const verdicts: Record<string, Verdict> = {};
      for (const probe of probes) verdicts[probe.id] = verdictFor(probe, atBackup[probe.id], baseline[probe.id], seen[probe.id]);
      results.push({ scenario, seen, afterCron, cronError, verdicts, seconds: (Date.now() - t0) / 1000, serverErrors: inst.serverErrors.length - errorsBefore });
    } finally { await inst.stop(); }
  }

  // 4. controls: without these a "not revived" row means nothing
  const weak = nonDiscriminating(probes, atBackup, baseline);
  const allRestored = results.find(r => r.scenario.name === 'KV+D1+DO');
  const none = results.find(r => r.scenario.name.startsWith('none'));
  const controls = [
    { name: 'The backup point and the post-revocation state differ for the access/data probes', passed: weak.length === 0, evidence: weak.length ? `identical in both states, so they prove nothing: ${weak.join(', ')}` : 'every access/data probe changed' },
    { name: 'Restoring nothing reproduces the baseline', passed: !!none && Object.values(none.verdicts).every(v => v === 'not-revived' || v === 'unchanged' || v === 'kept'), evidence: none ? JSON.stringify(Object.entries(none.verdicts).filter(([, v]) => !['not-revived', 'unchanged', 'kept'].includes(v))) : 'scenario missing' },
    { name: 'Restoring everything is seen by the probes (they can detect a revival)', passed: !!allRestored && Object.values(allRestored.verdicts).some(v => v === 'reverted'), evidence: allRestored ? `${Object.values(allRestored.verdicts).filter(v => v === 'reverted').length} probes reverted` : 'scenario missing' },
    { name: 'No outbound call outside the local fakes', passed: guard.state.unexpected.length === 0, evidence: `${guard.state.unexpected.length} unexpected, ${guard.state.mocked.length} answered locally` },
  ];

  const cleanup = await rm(root, { recursive: true, force: true }).then(async () => !(await exists(root)));
  controls.push({ name: 'The temporary stores were removed', passed: cleanup, evidence: cleanup ? 'removed' : 'left behind' });

  // 5. report
  const actors = [...new Set(probes.map(p => p.actor))];
  const kinds = probes.map(p => p.kind);
  const matrix = results.map(r => ({
    scenario: r.scenario.name, description: r.scenario.description,
    cells: Object.fromEntries(actors.map(actor => {
      const ids = probes.filter(p => p.actor === actor).map(p => p.id);
      return [actor, actorCell(ids.map(id => r.verdicts[id]), ids.map(id => kinds[probes.findIndex(p => p.id === id)]))];
    })),
    revived: probes.filter(p => r.verdicts[p.id] === 'reverted').map(p => p.id),
    partial: probes.filter(p => r.verdicts[p.id] === 'partial').map(p => ({ id: p.id, atBackup: atBackup[p.id], baseline: baseline[p.id], observed: r.seen[p.id] })),
    serverErrors: probes.filter(p => r.verdicts[p.id] === 'server-error').map(p => p.id),
    controlsLost: probes.filter(p => r.verdicts[p.id] === 'control-lost').map(p => p.id),
    lostPostBackup: probes.filter(p => r.verdicts[p.id] === 'lost').map(p => p.id),
    changedByCron: r.cronError ? [`cron failed: ${r.cronError}`] : probes.filter(p => r.afterCron[p.id] !== undefined && r.afterCron[p.id] !== r.seen[p.id]).map(p => `${p.id}: ${r.seen[p.id]} -> ${r.afterCron[p.id]}`),
    seconds: r.seconds, serverErrorCount: r.serverErrors,
  }));
  const kvFamilies = [...new Set(kvPost.map(e => kvFamily(e.name)))].sort();
  const unclassified = kvPost.filter(e => kvCategory(e.name) === null).map(e => e.name.split(':')[0] + ':');
  const report = { generatedAt: new Date(began).toISOString(), compatibilityDate: '2026-07-30 (production 2026-08-27)', migrations, probes: probes.map(p => ({ id: p.id, kind: p.kind, atBackup: atBackup[p.id], baseline: baseline[p.id] })), controls, matrix, kvFamiliesSeen: kvFamilies, unclassifiedKvPrefixes: [...new Set(unclassified)], timingsMs: timings, elapsedSeconds: (Date.now() - began) / 1000 };
  await writeFile(join(outDir, 'restore-drill.json'), JSON.stringify(report, null, 1));
  const legend = 'R=access revived, D=deleted data back, J=job replayed, P=partial/new state, E=server error, C=control lost, L=post-backup work lost';
  const lines = [`# Restore drill`, '', legend, '', `| scenario | ${actors.join(' | ')} |`, `|---|${actors.map(() => '---').join('|')}|`,
    ...matrix.map(m => `| ${m.scenario} | ${actors.map(a => (m.cells as Record<string, string>)[a]).join(' | ')} |`), '', '## Controls', ...controls.map(c => `- ${c.passed ? 'PASS' : 'FAIL'}: ${c.name} (${c.evidence})`)];
  await writeFile(join(outDir, 'restore-drill.md'), lines.join('\n'));
  console.log(lines.join('\n'));

  if (controls.some(c => !c.passed)) { console.error('A control failed: the matrix cannot be trusted.'); return 2; }
  const bad = matrix.some(m => m.scenario !== 'none (control)' && (m.revived.length || m.partial.length || m.serverErrors.length));
  return bad ? 1 : 0;
}

main().then(code => process.exit(code), error => { console.error(error instanceof HarnessFailure ? `Drill failure: ${error.message}` : error); process.exit(2); });
