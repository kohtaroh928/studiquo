import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, statSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const SCRIPT_PATH = fileURLToPath(new URL('./rag-eval', import.meta.url));
const VALID_ACCOUNT_ID = '0123456789abcdef0123456789abcdef';
const FAKE_SECRET_TOKEN = 'cf-rag-eval-secret-token-value-999';

function createSandbox() {
  const dir = mkdtempSync(path.join(tmpdir(), 'rag-eval-test-'));
  const binDir = path.join(dir, 'bin');
  const privateDir = path.join(dir, 'private');
  const accountFile = path.join(privateDir, 'cloudflare-account-id');
  const keychainFile = path.join(dir, 'mock-keychain.txt');
  const nodeCallLog = path.join(dir, 'node-calls.json');
  mkdirSync(binDir);

  // Mock macOS `security` CLI backed by keychainFile
  const securityPath = path.join(binDir, 'security');
  writeFileSync(
    securityPath,
    `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
case "$cmd" in
  add-generic-password)
    printf '%s' "${FAKE_SECRET_TOKEN}" > "${keychainFile}"
    ;;
  find-generic-password)
    if [ -f "${keychainFile}" ]; then
      cat "${keychainFile}"
    else
      exit 44
    fi
    ;;
  delete-generic-password)
    if [ -f "${keychainFile}" ]; then
      rm -f "${keychainFile}"
      exit 0
    else
      exit 44
    fi
    ;;
  *)
    exit 2
    ;;
esac
`
  );
  chmodSync(securityPath, 0o755);

  // Mock `node` binary so we can verify passed env vars and arguments without hitting real Cloudflare API
  const nodePath = path.join(binDir, 'node');
  writeFileSync(
    nodePath,
    `#!/usr/bin/env bash
set -euo pipefail
printf '{"args":%s,"hasAccount":%s,"hasToken":%s,"remoteReal":%s,"remoteQuality":%s}\\n' \\
  "$(printf '%s\\n' "$@" | awk 'BEGIN{printf "["} {printf "%s\\"%s\\"", (NR>1?",":""), $0} END{printf "]"}')" \\
  "$([ "\${CLOUDFLARE_ACCOUNT_ID:-}" = "${VALID_ACCOUNT_ID}" ] && echo true || echo false)" \\
  "$([ "\${CLOUDFLARE_API_TOKEN:-}" = "${FAKE_SECRET_TOKEN}" ] && echo true || echo false)" \\
  "$([ "\${STUDIQUO_RAG_REAL_MATERIAL_REMOTE:-}" = "true" ] && echo true || echo false)" \\
  "$([ "\${STUDIQUO_RAG_QUALITY_REMOTE:-}" = "true" ] && echo true || echo false)" >> "${nodeCallLog}"
`
  );
  chmodSync(nodePath, 0o755);

  return {dir, binDir, accountFile, keychainFile, nodeCallLog};
}

function runRagEval(sandbox, args, {input = '', env = {}} = {}) {
  const cleanEnv = {...process.env};
  delete cleanEnv.CLOUDFLARE_ACCOUNT_ID;
  delete cleanEnv.CLOUDFLARE_API_TOKEN;
  delete cleanEnv.STUDIQUO_RAG_EVAL_YES;

  const res = spawnSync('bash', [SCRIPT_PATH, ...args], {
    cwd: sandbox.dir,
    input,
    encoding: 'utf8',
    env: {
      ...cleanEnv,
      PATH: `${sandbox.binDir}:${process.env.PATH}`,
      STUDIQUO_RAG_EVAL_SERVICE: 'studiquo-rag-eval-test',
      STUDIQUO_RAG_EVAL_ACCOUNT_FILE: sandbox.accountFile,
      ...env,
    },
  });

  // Never leak the secret token to stdout or stderr on any path
  assert.equal(res.stdout.includes(FAKE_SECRET_TOKEN), false, 'stdout must never contain secret token');
  assert.equal(res.stderr.includes(FAKE_SECRET_TOKEN), false, 'stderr must never contain secret token');
  return res;
}

test('store validates 32-char lowercase hex account ID and sets 0700/0600 permissions', (t) => {
  const sb = createSandbox();
  t.after(() => rmSync(sb.dir, {recursive: true, force: true}));

  // Invalid account IDs (too short, uppercase, non-hex) are rejected before touching keychain
  for (const invalidId of ['short', '0123456789ABCDEF0123456789abcdef', '0123456789abcdef0123456789abcdeg']) {
    const bad = runRagEval(sb, ['store'], {input: `${invalidId}\n`});
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /アカウントIDの形が違います/);
    assert.equal(existsSync(sb.accountFile), false);
    assert.equal(existsSync(sb.keychainFile), false);
  }

  // Valid 32-char hex saves account file with 0600 inside 0700 directory and stores token in keychain
  const good = runRagEval(sb, ['store'], {input: `${VALID_ACCOUNT_ID}\n`});
  assert.equal(good.status, 0, good.stderr);
  assert.equal(readFileSync(sb.accountFile, 'utf8').trim(), VALID_ACCOUNT_ID);
  assert.equal(statSync(sb.accountFile).mode & 0o777, 0o600);
  assert.equal(statSync(path.dirname(sb.accountFile)).mode & 0o777, 0o700);
  assert.equal(existsSync(sb.keychainFile), true);
});

test('check and forget handle missing account ID or missing keychain token cleanly without invoking node', (t) => {
  const sb = createSandbox();
  t.after(() => rmSync(sb.dir, {recursive: true, force: true}));

  // 1. Neither account ID nor token -> stops at missing account ID
  const noAcct = runRagEval(sb, ['check']);
  assert.equal(noAcct.status, 1);
  assert.match(noAcct.stderr, /アカウントIDがありません/);
  assert.equal(existsSync(sb.nodeCallLog), false);

  // 2. Account ID present (via env), but token not in keychain -> stops at missing token
  const noTok = runRagEval(sb, ['check'], {env: {CLOUDFLARE_ACCOUNT_ID: VALID_ACCOUNT_ID}});
  assert.equal(noTok.status, 1);
  assert.match(noTok.stderr, /トークンがキーチェーンにありません/);
  assert.equal(existsSync(sb.nodeCallLog), false);

  // 3. Store both -> check succeeds and passes credentials to child node process
  runRagEval(sb, ['store'], {input: `${VALID_ACCOUNT_ID}\n`});
  const okCheck = runRagEval(sb, ['check']);
  assert.equal(okCheck.status, 0, okCheck.stderr);
  const call = JSON.parse(readFileSync(sb.nodeCallLog, 'utf8').trim());
  assert.equal(call.hasAccount, true);
  assert.equal(call.hasToken, true);
  assert.match(call.args[0], /check-cf-token\.ts$/);

  // 4. forget removes the token, and a second forget reports none stored
  const forget1 = runRagEval(sb, ['forget']);
  assert.equal(forget1.status, 0);
  assert.match(forget1.stdout, /トークンを消しました/);

  const forget2 = runRagEval(sb, ['forget']);
  assert.equal(forget2.status, 0);
  assert.match(forget2.stdout, /保存されたトークンはありません/);
});

test('real-material and quality enforce paid confirmation and extra v7 frozen-set warning', (t) => {
  const sb = createSandbox();
  t.after(() => rmSync(sb.dir, {recursive: true, force: true}));
  runRagEval(sb, ['store'], {input: `${VALID_ACCOUNT_ID}\n`});

  const normalManifest = path.join(sb.dir, 'manifest-v6.json');
  const frozenV7Manifest = path.join(sb.dir, 'rag-real-material-v7-manifest.json');
  const outPath = path.join(sb.dir, 'out', 'result.json');
  const qualityDir = path.join(sb.dir, 'quality-run');
  writeFileSync(normalManifest, '{}');
  writeFileSync(frozenV7Manifest, '{}');
  mkdirSync(qualityDir);

  // Declining confirmation ('n') aborts before calling node
  const declined = runRagEval(sb, ['real-material', normalManifest, outPath], {input: 'n\n'});
  assert.equal(declined.status, 1);
  assert.match(declined.stderr, /中止しました/);
  assert.equal(existsSync(sb.nodeCallLog), false);

  // v7 manifest requires TWO confirmations: first the v7 freeze warning, then the paid call prompt
  const v7DeclinedSecond = runRagEval(sb, ['real-material', frozenV7Manifest, outPath], {input: 'y\nn\n'});
  assert.equal(v7DeclinedSecond.status, 1);
  assert.match(v7DeclinedSecond.stderr, /警告: v7は凍結した未使用の質問です/);
  assert.match(v7DeclinedSecond.stderr, /有料のWorkers AI呼び出しをします/);
  assert.equal(existsSync(sb.nodeCallLog), false);

  const v7AcceptedBoth = runRagEval(sb, ['real-material', frozenV7Manifest, outPath], {input: 'y\ny\n'});
  assert.equal(v7AcceptedBoth.status, 0, v7AcceptedBoth.stderr);

  // STUDIQUO_RAG_EVAL_YES=1 skips interactive prompts for quality
  const qualityOk = runRagEval(sb, ['quality', qualityDir], {env: {STUDIQUO_RAG_EVAL_YES: '1'}});
  assert.equal(qualityOk.status, 0, qualityOk.stderr);

  const calls = readFileSync(sb.nodeCallLog, 'utf8')
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line));
  assert.equal(calls.length, 2);
  assert.equal(calls[0].remoteReal, true);
  assert.equal(calls[1].remoteQuality, true);
});

test('help and invalid arguments return expected exit codes', (t) => {
  const sb = createSandbox();
  t.after(() => rmSync(sb.dir, {recursive: true, force: true}));

  for (const helpArg of [['--help'], ['-h'], ['help'], []]) {
    const res = runRagEval(sb, helpArg);
    assert.equal(res.status, 0);
    assert.match(res.stdout, /scripts\/rag-eval store/);
  }

  for (const badArgs of [['unknown-cmd'], ['real-material', 'only-one-arg'], ['quality']]) {
    const res = runRagEval(sb, badArgs);
    assert.equal(res.status, 2);
  }
});
