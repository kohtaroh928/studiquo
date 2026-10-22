import { createServer, type Server } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, chmod, copyFile, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHarness, runContracts, scanPaths, allowedRequest, type Harness } from './harness.ts';
export const ZAP_IMAGE = 'zaproxy/zap-stable:2.16.1@sha256:7840969c7c9fead565bf9734b12f49f6886db90b1d35b1f74d79710bbd081dab';
/** ZAP のレポート(JSON)の、読む項目だけ。形は信用せず、sanitize* が検証する。 */
interface ZapAlert { pluginid?: unknown; riskcode?: unknown; count?: unknown; instances?: { uri?: unknown }[] }

export function sanitizeAlerts(raw: unknown) {
  const invalid = () => { throw new Error('Invalid scanner report'); };
  const report = raw as { site?: { alerts?: ZapAlert[] }[] } | null | undefined;
  if (!Array.isArray(report?.site) || !report.site.length) invalid();
  return report!.site!.flatMap((site) => {
    if (!Array.isArray(site.alerts)) invalid();
    return site.alerts!.map((alert) => {
      if (!/^[0-9]+$/.test(String(alert.pluginid ?? '')) || !/^[0-3]$/.test(String(alert.riskcode ?? '')) || !Array.isArray(alert.instances)) invalid();
      const count = Number(alert.count ?? alert.instances!.length);
      if (!Number.isSafeInteger(count) || count < 0) invalid();
      const paths = alert.instances!.map((instance) => {
        if (typeof instance?.uri !== 'string') invalid();
        try { const url = new URL(instance.uri as string); return url.origin === 'http://127.0.0.1:8090' && scanPaths.includes(url.pathname) ? url.pathname : '[outside allowlist]'; } catch { invalid(); }
      });
      return { rule: String(alert.pluginid), risk: Number(alert.riskcode), count, paths: [...new Set(paths)] };
    });
  });
}
export function sanitizeScannerStatus(raw: unknown) {
  const status = (raw ?? {}) as { stage?: string; exitCode?: unknown; errorType?: unknown };
  const stages = ['initializing', 'scanner-running', 'scanner-completed', 'scanner-failed', 'scanner-timeout'];
  if (!stages.includes(status.stage as string)) throw new Error('Invalid scanner status');
  const result: { stage: string; exitCode?: number; errorType?: string } = { stage: status.stage as string };
  if (status.exitCode !== undefined) {
    const exitCode = status.exitCode as number;
    if (!Number.isSafeInteger(exitCode) || exitCode < 0 || exitCode > 255) throw new Error('Invalid scanner status');
    result.exitCode = exitCode;
  }
  if (status.errorType !== undefined) {
    if (!['FileNotFoundError', 'PermissionError', 'OSError', 'RuntimeError', 'TimeoutExpired'].includes(status.errorType as string)) throw new Error('Invalid scanner status');
    result.errorType = status.errorType as string;
  }
  return result;
}
export function sanitizeScanProof(raw: unknown) {
  const proof = raw as Record<string, unknown> | null | undefined; // 形は下で全て検証する
  const positive = ['activeScanCount', 'activeMessageCount', 'enabledActiveRules', 'enabledPassiveRules'];
  if (!proof || positive.some(key => !Number.isSafeInteger(proof[key]) || (proof[key] as number) < 1) || proof.passivePending !== 0 || !Array.isArray(proof.activeProgress) || proof.activeProgress.length !== proof.activeScanCount || proof.activeProgress.some((progress: number) => progress !== 100)) throw new Error('Scanner completion proof invalid');
  return Object.fromEntries([...positive, 'passivePending', 'activeProgress'].map(key => [key, proof[key]]));
}
function command(args: readonly string[], timeout = 600000, signal?: AbortSignal): Promise<number> {
  return new Promise((resolveResult, reject) => {
    if (signal?.aborted) { reject(new Error('Scanner cancelled')); return; }
    const child = spawn('docker', args, { stdio: 'ignore' });
    const abort = () => { child.kill('SIGTERM'); reject(new Error('Scanner cancelled')); };
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Scanner timeout')); }, timeout);
    child.once('error', () => { clearTimeout(timer); reject(new Error('Docker unavailable')); });
    child.once('close', code => { clearTimeout(timer); signal?.removeEventListener('abort', abort); resolveResult(code as number); });
  });
}
/** DAST の結果の要約(dast.json に書く。生のレポートは含めない)。 */
export interface ScanSummary {
  status: string;
  mode: string;
  contracts: { status: string; passed: number; authenticatedUsers: number } | null;
  scanner: Record<string, unknown>;
  findings: ReturnType<typeof sanitizeAlerts>;
  error?: string;
}

export async function runScan({ contractsOnly = false } = {}) {
  const summary: ScanSummary = { status: 'error', mode: contractsOnly ? 'contracts-only' : 'zap', contracts: null, scanner: { status: 'not-run' }, findings: [] };
  let harness: Harness | undefined, server: Server | undefined, temporary: string | undefined;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
  const containerName = `studiquo-dast-${process.pid}`;
  try {
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    const started = harness = await createHarness();
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    summary.contracts = await runContracts(started);
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    if (started.stats.outboundBlocked) throw new Error('Worker attempted external communication');
    if (contractsOnly) { summary.status = 'passed'; return summary; }
    if (process.platform !== 'linux') throw new Error('ZAP isolation requires Linux; use --contracts-only locally');
    if (await command(['image', 'inspect', ZAP_IMAGE], 15000) !== 0) throw new Error('Pinned ZAP image missing; pull it before scanning');
    const workDir = temporary = await mkdtemp(join(tmpdir(), 'studiquo-dast-'));
    // Container runs as the current Linux UID; no world-readable credentials.
    await chmod(workDir, 0o700);
    const counts = Object.fromEntries(scanPaths.map(path => [path, 0]));
    let requests = 0;
    let gatewayFailed = false;
    const gateway = server = createServer(async (incoming, outgoing) => {
      try {
        incoming.resume();
        if (++requests > 10000) gatewayFailed = true;
        if (requests > 10000 || !allowedRequest(incoming.method, incoming.url as string)) { outgoing.writeHead(403); outgoing.end(); return; }
        const path = new URL(incoming.url!, 'http://127.0.0.1:8090').pathname;
        // Authentication is inserted at the gateway, never exposed to ZAP or reports.
        const response = await started.request(incoming.url as string, path.startsWith('/api/') ? started.users[0].token : null);
        if (response.status >= 300 && response.status < 400) { gatewayFailed = true; outgoing.writeHead(502); outgoing.end(); return; }
        if (response.status === 200) counts[path]++;
        outgoing.writeHead(response.status, Object.fromEntries(response.headers));
        outgoing.end(Buffer.from(await response.arrayBuffer()));
      } catch { gatewayFailed = true; outgoing.writeHead(502); outgoing.end(); }
    });
    await new Promise<void>((done, reject) => { gateway.once('error', reject); gateway.listen(join(workDir, 'gateway.sock'), done); });
    await chmod(join(workDir, 'gateway.sock'), 0o600);
    const openapi = { openapi: '3.0.3', info: { title: 'Studiquo isolated read-only scan', version: '1' }, servers: [{ url: 'http://127.0.0.1:8090' }], paths: Object.fromEntries(scanPaths.map(path => [path, { get: { parameters: [{ name: 'probe', in: 'query', schema: { type: 'string' } }], responses: { 200: { description: 'Success' } } } }])) };
    await writeFile(join(workDir, 'openapi.json'), JSON.stringify(openapi), { mode: 0o600 });
    await copyFile(fileURLToPath(new URL('./bridge.py', import.meta.url)), join(workDir, 'bridge.py'));
    await copyFile(fileURLToPath(new URL('./scan_proof.py', import.meta.url)), join(workDir, 'scan_proof.py'));
    const code = await command(['run', '--rm', '--name', containerName, '--network', 'none', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '2g', '--cpus', '2', '--user', `${process.getuid!()}:${process.getgid!()}`, '--workdir', '/zap/wrk', '-e', 'HOME=/tmp', '-v', `${workDir}:/zap/wrk:rw`, '--entrypoint', 'python3', ZAP_IMAGE, '/zap/wrk/bridge.py'], 660000, controller.signal);
    const diagnostics = await readFile(join(workDir, 'scanner-status.json'), 'utf8').then(JSON.parse).then(sanitizeScannerStatus).catch(() => ({ stage: 'diagnostics-unavailable' }));
    summary.scanner = { status: [0, 1, 2].includes(code) ? 'awaiting-validation' : 'execution-failed', exitCode: code, ...diagnostics };
    if (![0, 1, 2].includes(code)) throw new Error('Scanner execution failed');
    const proof = await readFile(join(workDir, 'scan-proof.json'), 'utf8').then(JSON.parse).then(sanitizeScanProof).catch(() => { throw new Error('Scanner completion proof invalid'); });
    const raw = JSON.parse(await readFile(join(workDir, 'raw.json'), 'utf8'));
    if (gatewayFailed) throw new Error('Gateway safety limit or infrastructure failure');
    if (!requests || Object.values(counts).some(count => !count)) throw new Error('Scanner coverage incomplete');
    const version = raw['@version'];
    if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Invalid scanner report');
    summary.findings = sanitizeAlerts(raw);
    summary.scanner = { status: 'completed', version, proof, stage: diagnostics.stage, exitCode: code, requests, successfulRequestsByPath: counts, image: ZAP_IMAGE };
    summary.status = summary.findings.length ? 'findings' : 'passed';
    if (started.stats.outboundBlocked) throw new Error('Worker attempted external communication');
  } catch (error) {
    summary.status = 'error'; summary.error = (error as Error).message.startsWith('Contract failed:') ? (error as Error).message : ['Scanner cancelled', 'Docker unavailable', 'Scanner timeout', 'Pinned ZAP image missing; pull it before scanning', 'Scanner execution failed', 'Scanner completion proof invalid', 'Gateway safety limit or infrastructure failure', 'Scanner coverage incomplete', 'Worker attempted external communication', 'ZAP isolation requires Linux; use --contracts-only locally'].includes((error as Error).message) ? (error as Error).message : 'DAST runtime failed';
  } finally {
    process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
    if (!contractsOnly && process.platform === 'linux') await command(['rm', '-f', containerName], 15000).catch(() => {});
    if (server) { const open = server; await new Promise(done => open.close(done)); }
    if (harness) await harness.close();
    if (temporary) await rm(temporary, { recursive: true, force: true });
  }
  return summary;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const outputIndex = args.indexOf('--output');
  const output = outputIndex < 0 ? fileURLToPath(new URL('../../security-reports/dast.json', import.meta.url)) : args[outputIndex + 1];
  const valid = args.every((arg, index) => arg === '--contracts-only' || arg === '--enforce' || arg === '--output' || (outputIndex >= 0 && index === outputIndex + 1));
  if (!valid || (outputIndex >= 0 && !output)) throw new Error('Usage: run.ts [--contracts-only] [--output path]');
  const result = await runScan({ contractsOnly: args.includes('--contracts-only') });
  if (output) { await mkdir(dirname(resolve(output)), { recursive: true }); await writeFile(output, `${JSON.stringify(result, null, 2)}\n`); await writeFile(output.replace(/\.json$/, '') + '.md', `# DAST summary\n\nStatus: ${result.status}\n\nContracts: ${result.contracts?.passed ?? 0} passed\n\nScanner: ${result.scanner.status}\n\nFindings: ${result.findings.length}\n${result.error ? `\nError: ${result.error}\n` : ''}`); }
  console.log(JSON.stringify(result));
  process.exitCode = result.status === 'error' ? 2 : args.includes('--enforce') && result.findings.some((finding) => finding.risk >= 3) ? 1 : 0;
}
