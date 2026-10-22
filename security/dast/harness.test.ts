import test from 'node:test';
import assert from 'node:assert/strict';
import { createHarness, runContracts, allowedRequest } from './harness.ts';
import { sanitizeAlerts, sanitizeScannerStatus, sanitizeScanProof, runScan } from './run.ts';
test('gateway forbids remote destinations, writes and unlisted routes', () => {
  assert.equal(allowedRequest('GET', '/api/actions?probe=test'), true);
  for (const [method, path] of [['CONNECT','example.com:443'],['GET','http://example.com/health'],['GET','//example.com/health'],['GET','/api/account'],['DELETE','/api/actions'],['POST','/api/auth/local/login']]) assert.equal(allowedRequest(method,path), false);
});
test('report omits request bodies, evidence, headers and query secrets', () => {
  const output = sanitizeAlerts({site:[{alerts:[{pluginid:'10020',riskcode:'2',count:'1',evidence:'secret',instances:[{uri:'http://127.0.0.1:8090/api/actions?token=secret',evidence:'secret',requestHeader:'secret'}]}]}]});
  assert.deepEqual(output,[{rule:'10020',risk:2,count:1,paths:['/api/actions']}]);
  assert.equal(JSON.stringify(output).includes('secret'),false);
  assert.throws(()=>sanitizeAlerts({}),/Invalid scanner/);
  for (const invalid of [{ pluginid: '', riskcode: '2', instances: [] }, { pluginid: '1', riskcode: '9', instances: [] }, { pluginid: '1', riskcode: '2', count: 'NaN', instances: [] }, { pluginid: '1', riskcode: '2', count: -1, instances: [] }, { pluginid: '1', riskcode: '2', instances: null }]) assert.throws(() => sanitizeAlerts({ site: [{ alerts: [invalid] }] }), /Invalid scanner/);
});
test('actual Workers runtime validates authentication and tenant boundaries', { timeout: 60000 }, async () => {
  const h = await createHarness();
  try {
    // Deliberately introduce cross-user fixture contamination: verification must fail.
    await h.kv.put(`actions:${h.users[0].key}`, JSON.stringify([{ type: 'synthetic', label: 'B' }]));
    await assert.rejects(runContracts(h), /authenticated-actions-A/);
    await h.kv.put(`actions:${h.users[0].key}`, JSON.stringify([{ type: 'synthetic', label: 'A' }]));
    assert.equal((await runContracts(h)).passed, 20);
    // A lost session record must reject a previously valid token.
    await h.kv.delete(`session:${h.users[0].key}`);
    assert.equal((await h.request('/api/actions', h.users[0].token)).status,401);
    assert.equal(h.stats.outboundBlocked,0);
    // A real OAuth handler tries to fetch Apple JWKS; the outbound service blocks it.
    const response = await h.request('/api/auth/apple', null, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ identityToken: 'synthetic-invalid-identity', randomValue: 'synthetic-random-value-for-isolation' }) });
    assert.equal(response.status,401);
    assert.equal(h.stats.outboundBlocked,1);
  } finally { await h.close(); }
});

test('scanner diagnostics admit only fixed stages, exit codes and error types', () => {
  assert.deepEqual(sanitizeScannerStatus({ stage: 'initializing', exitCode: 71, errorType: 'PermissionError', body: 'secret' }), { stage: 'initializing', exitCode: 71, errorType: 'PermissionError' });
  for (const value of [{ stage: 'secret' }, { stage: 'scanner-running', exitCode: '0' }, { stage: 'scanner-running', errorType: 'secret' }]) assert.throws(() => sanitizeScannerStatus(value), /Invalid scanner status/);
});

test('scanner completion requires real active traffic and drained passive queue', () => {
  const proof = { activeScanCount: 1, activeProgress: [100], activeMessageCount: 40, enabledActiveRules: 2, enabledPassiveRules: 3, passivePending: 0 };
  assert.deepEqual(sanitizeScanProof({ ...proof, raw: 'secret' }), proof);
  for (const value of [undefined, {}, { ...proof, activeProgress: [50] }, { ...proof, activeProgress: [] }, { ...proof, activeMessageCount: 0 }, { ...proof, enabledActiveRules: 0 }, { ...proof, enabledPassiveRules: 0 }, { ...proof, passivePending: 1 }, { ...proof, activeScanCount: '1' }]) assert.throws(() => sanitizeScanProof(value), /Scanner completion proof invalid/);
});
