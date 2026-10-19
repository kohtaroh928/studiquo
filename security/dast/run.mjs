import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, chmod, copyFile, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHarness, runContracts, scanPaths, allowedRequest } from './harness.mjs';
export const ZAP_IMAGE = 'zaproxy/zap-stable:2.16.1@sha256:7840969c7c9fead565bf9734b12f49f6886db90b1d35b1f74d79710bbd081dab';
export function sanitizeAlerts(raw) {
  const invalid = () => { throw new Error('Invalid scanner report'); };
  if (!Array.isArray(raw?.site) || !raw.site.length) invalid();
  return raw.site.flatMap(site => {
    if (!Array.isArray(site.alerts)) invalid();
    return site.alerts.map(alert => {
      if (!/^[0-9]+$/.test(String(alert.pluginid ?? '')) || !/^[0-3]$/.test(String(alert.riskcode ?? '')) || !Array.isArray(alert.instances)) invalid();
      const count = Number(alert.count ?? alert.instances.length);
      if (!Number.isSafeInteger(count) || count < 0) invalid();
      const paths = alert.instances.map(instance => {
        if (typeof instance?.uri !== 'string') invalid();
        try { const url = new URL(instance.uri); return url.origin === 'http://127.0.0.1:8090' && scanPaths.includes(url.pathname) ? url.pathname : '[outside allowlist]'; } catch { invalid(); }
      });
      return { rule: String(alert.pluginid), risk: Number(alert.riskcode), count, paths: [...new Set(paths)] };
    });
  });
}
export function sanitizeScannerStatus(status) {
  const stages = ['initializing', 'scanner-running', 'scanner-completed', 'scanner-failed', 'scanner-timeout'];
  if (!stages.includes(status?.stage)) throw new Error('Invalid scanner status');
  const result = { stage: status.stage };
  if (status.exitCode !== undefined) {
    if (!Number.isSafeInteger(status.exitCode) || status.exitCode < 0 || status.exitCode > 255) throw new Error('Invalid scanner status');
    result.exitCode = status.exitCode;
  }
  if (status.errorType !== undefined) {
    if (!['FileNotFoundError', 'PermissionError', 'OSError', 'RuntimeError', 'TimeoutExpired'].includes(status.errorType)) throw new Error('Invalid scanner status');
    result.errorType = status.errorType;
  }
  return result;
}
export function sanitizeScanProof(proof) {
  const positive = ['activeScanCount', 'activeMessageCount', 'enabledActiveRules', 'enabledPassiveRules'];
  if (!proof || positive.some(key => !Number.isSafeInteger(proof[key]) || proof[key] < 1) || proof.passivePending !== 0 || !Array.isArray(proof.activeProgress) || proof.activeProgress.length !== proof.activeScanCount || proof.activeProgress.some(progress => progress !== 100)) throw new Error('Scanner completion proof invalid');
  return Object.fromEntries([...positive, 'passivePending', 'activeProgress'].map(key => [key, proof[key]]));
}
function command(args, timeout = 600000, signal) {
  return new Promise((resolveResult, reject) => {
    if (signal?.aborted) { reject(new Error('Scanner cancelled')); return; }
    const child = spawn('docker', args, { stdio: 'ignore' });
    const abort = () => { child.kill('SIGTERM'); reject(new Error('Scanner cancelled')); };
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Scanner timeout')); }, timeout);
    child.once('error', () => { clearTimeout(timer); reject(new Error('Docker unavailable')); });
    child.once('close', code => { clearTimeout(timer); signal?.removeEventListener('abort', abort); resolveResult(code); });
  });
}
export async function runScan({ contractsOnly = false } = {}) {
  const summary = { status: 'error', mode: contractsOnly ? 'contracts-only' : 'zap', contracts: null, scanner: { status: 'not-run' }, findings: [] };
  let harness, server, temporary;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
  const containerName = `studiquo-dast-${process.pid}`;
  try {
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    harness = await createHarness();
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    summary.contracts = await runContracts(harness);
    if (controller.signal.aborted) throw new Error('Scanner cancelled');
    if (harness.stats.outboundBlocked) throw new Error('Worker attempted external communication');
    if (contractsOnly) { summary.status = 'passed'; return summary; }
    if (process.platform !== 'linux') throw new Error('ZAP isolation requires Linux; use --contracts-only locally');
    if (await command(['image', 'inspect', ZAP_IMAGE], 15000) !== 0) throw new Error('Pinned ZAP image missing; pull it before scanning');
    temporary = await mkdtemp(join(tmpdir(), 'studiquo-dast-'));
    // Container runs as the current Linux UID; no world-readable credentials.
    await chmod(temporary, 0o700);
    const counts = Object.fromEntries(scanPaths.map(path => [path, 0]));
    let requests = 0;
    let gatewayFailed = false;
    server = createServer(async (incoming, outgoing) => {
      try {
        incoming.resume();
        if (++requests > 10000) gatewayFailed = true;
        if (requests > 10000 || !allowedRequest(incoming.method, incoming.url)) { outgoing.writeHead(403); outgoing.end(); return; }
        const path = new URL(incoming.url, 'http://127.0.0.1:8090').pathname;
        // Authentication is inserted at the gateway, never exposed to ZAP or reports.
        const response = await harness.request(incoming.url, path.startsWith('/api/') ? harness.users[0].token : null);
        if (response.status >= 300 && response.status < 400) { gatewayFailed = true; outgoing.writeHead(502); outgoing.end(); return; }
        if (response.status === 200) counts[path]++;
        outgoing.writeHead(response.status, Object.fromEntries(response.headers));
        outgoing.end(Buffer.from(await response.arrayBuffer()));
      } catch { gatewayFailed = true; outgoing.writeHead(502); outgoing.end(); }
    });
    await new Promise((done, reject) => { server.once('error', reject); server.listen(join(temporary, 'gateway.sock'), done); });
    await chmod(join(temporary, 'gateway.sock'), 0o600);
    const openapi = { openapi: '3.0.3', info: { title: 'Studiquo isolated read-only scan', version: '1' }, servers: [{ url: 'http://127.0.0.1:8090' }], paths: Object.fromEntries(scanPaths.map(path => [path, { get: { parameters: [{ name: 'probe', in: 'query', schema: { type: 'string' } }], responses: { 200: { description: 'Success' } } } }])) };
    await writeFile(join(temporary, 'openapi.json'), JSON.stringify(openapi), { mode: 0o600 });
    await copyFile(fileURLToPath(new URL('./bridge.py', import.meta.url)), join(temporary, 'bridge.py'));
    await copyFile(fileURLToPath(new URL('./scan_proof.py', import.meta.url)), join(temporary, 'scan_proof.py'));
    const code = await command(['run', '--rm', '--name', containerName, '--network', 'none', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '2g', '--cpus', '2', '--user', `${process.getuid()}:${process.getgid()}`, '--workdir', '/zap/wrk', '-e', 'HOME=/tmp', '-v', `${temporary}:/zap/wrk:rw`, '--entrypoint', 'python3', ZAP_IMAGE, '/zap/wrk/bridge.py'], 660000, controller.signal);
    const diagnostics = await readFile(join(temporary, 'scanner-status.json'), 'utf8').then(JSON.parse).then(sanitizeScannerStatus).catch(() => ({ stage: 'diagnostics-unavailable' }));
    summary.scanner = { status: [0, 1, 2].includes(code) ? 'awaiting-validation' : 'execution-failed', exitCode: code, ...diagnostics };
    if (![0, 1, 2].includes(code)) throw new Error('Scanner execution failed');
    const proof = await readFile(join(temporary, 'scan-proof.json'), 'utf8').then(JSON.parse).then(sanitizeScanProof).catch(() => { throw new Error('Scanner completion proof invalid'); });
    const raw = JSON.parse(await readFile(join(temporary, 'raw.json'), 'utf8'));
    if (gatewayFailed) throw new Error('Gateway safety limit or infrastructure failure');
    if (!requests || Object.values(counts).some(count => !count)) throw new Error('Scanner coverage incomplete');
    const version = raw['@version'];
    if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Invalid scanner report');
    summary.findings = sanitizeAlerts(raw);
    summary.scanner = { status: 'completed', version, proof, stage: diagnostics.stage, exitCode: code, requests, successfulRequestsByPath: counts, image: ZAP_IMAGE };
    summary.status = summary.findings.length ? 'findings' : 'passed';
    if (harness.stats.outboundBlocked) throw new Error('Worker attempted external communication');
  } catch (error) {
    summary.status = 'error'; summary.error = error.message.startsWith('Contract failed:') ? error.message : ['Scanner cancelled', 'Docker unavailable', 'Scanner timeout', 'Pinned ZAP image missing; pull it before scanning', 'Scanner execution failed', 'Scanner completion proof invalid', 'Gateway safety limit or infrastructure failure', 'Scanner coverage incomplete', 'Worker attempted external communication', 'ZAP isolation requires Linux; use --contracts-only locally'].includes(error.message) ? error.message : 'DAST runtime failed';
  } finally {
    process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
    if (!contractsOnly && process.platform === 'linux') await command(['rm', '-f', containerName], 15000).catch(() => {});
    if (server) await new Promise(done => server.close(done));
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
  if (!valid || (outputIndex >= 0 && !output)) throw new Error('Usage: run.mjs [--contracts-only] [--output path]');
  const result = await runScan({ contractsOnly: args.includes('--contracts-only') });
  if (output) { await mkdir(dirname(resolve(output)), { recursive: true }); await writeFile(output, `${JSON.stringify(result, null, 2)}\n`); await writeFile(output.replace(/\.json$/, '') + '.md', `# DAST summary\n\nStatus: ${result.status}\n\nContracts: ${result.contracts?.passed ?? 0} passed\n\nScanner: ${result.scanner.status}\n\nFindings: ${result.findings.length}\n${result.error ? `\nError: ${result.error}\n` : ''}`); }
  console.log(JSON.stringify(result));
  process.exitCode = result.status === 'error' ? 2 : args.includes('--enforce') && result.findings.some(finding => finding.risk >= 3) ? 1 : 0;
}
