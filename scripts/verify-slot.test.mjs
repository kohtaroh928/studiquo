import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const SCRIPT_PATH = fileURLToPath(new URL('./verify-slot', import.meta.url));

function runGit(cwd, args) {
  const res = spawnSync('git', args, {cwd, encoding: 'utf8'});
  if (res.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${res.stderr}`);
  }
  return res.stdout.trim();
}

function runVerifySlot(cwd, args, extraEnv = {}) {
  return spawnSync('sh', [SCRIPT_PATH, ...args], {
    cwd,
    encoding: 'utf8',
    env: {...process.env, AGENT_NAME: 'test-agent', ...extraEnv},
  });
}

function createTempRepo() {
  const dir = mkdtempSync(path.join(tmpdir(), 'verify-slot-test-'));
  runGit(dir, ['init', '-b', 'main']);
  runGit(dir, ['config', 'user.name', 'Test User']);
  runGit(dir, ['config', 'user.email', 'test@example.com']);
  writeFileSync(path.join(dir, 'fileA.txt'), 'base-A\n');
  writeFileSync(path.join(dir, 'fileB.txt'), 'base-B\n');
  runGit(dir, ['add', 'fileA.txt', 'fileB.txt']);
  runGit(dir, ['commit', '-m', 'initial main']);

  // Create branch-a modifying fileA.txt
  runGit(dir, ['switch', '-c', 'claude/branch-a']);
  writeFileSync(path.join(dir, 'fileA.txt'), 'branch-a-change\n');
  runGit(dir, ['commit', '-am', 'commit on branch-a']);

  // Create branch-b modifying fileB.txt
  runGit(dir, ['switch', 'main']);
  runGit(dir, ['switch', '-c', 'codex/branch-b']);
  writeFileSync(path.join(dir, 'fileB.txt'), 'branch-b-change\n');
  runGit(dir, ['commit', '-am', 'commit on branch-b']);

  // Create branch-conflict modifying fileA.txt differently
  runGit(dir, ['switch', 'main']);
  runGit(dir, ['switch', '-c', 'claude/branch-conflict']);
  writeFileSync(path.join(dir, 'fileA.txt'), 'conflict-change\n');
  runGit(dir, ['commit', '-am', 'conflicting commit on fileA']);

  runGit(dir, ['switch', 'main']);
  return dir;
}

test('single-branch acquire checks out detached HEAD and release restores main', (t) => {
  const dir = createTempRepo();
  t.after(() => rmSync(dir, {recursive: true, force: true}));

  const branchASha = runGit(dir, ['rev-parse', 'claude/branch-a']);
  const acq = runVerifySlot(dir, ['acquire', 'claude/branch-a']);
  assert.equal(acq.status, 0, acq.stderr);
  assert.match(acq.stdout, /札を取りました/);

  const headSha = runGit(dir, ['rev-parse', 'HEAD']);
  assert.equal(headSha, branchASha);
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.lock')), true);

  // While locked, another acquire must fail
  const secondAcq = runVerifySlot(dir, ['acquire', 'codex/branch-b']);
  assert.notEqual(secondAcq.status, 0);
  assert.match(secondAcq.stderr, /ほかの人が使用中のため取れません/);

  // Release restores main and removes lock
  const rel = runVerifySlot(dir, ['release']);
  assert.equal(rel.status, 0, rel.stderr);
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.lock')), false);
  assert.equal(runGit(dir, ['symbolic-ref', '--short', 'HEAD']), 'main');
});

test('queue add, remove, deduplication, and acquire --queue stack multiple branches on main', (t) => {
  const dir = createTempRepo();
  t.after(() => rmSync(dir, {recursive: true, force: true}));

  // Cannot add main itself
  const addMain = runVerifySlot(dir, ['add', 'main']);
  assert.notEqual(addMain.status, 0);

  // Cannot add non-existent branch
  const addMissing = runVerifySlot(dir, ['add', 'no-such-branch']);
  assert.notEqual(addMissing.status, 0);

  // Add branch-a and branch-b (plus duplicate branch-a)
  assert.equal(runVerifySlot(dir, ['add', 'claude/branch-a']).status, 0);
  const dup = runVerifySlot(dir, ['add', 'claude/branch-a']);
  assert.equal(dup.status, 0);
  assert.match(dup.stdout, /すでに荷台に入っています/);
  assert.equal(runVerifySlot(dir, ['add', 'codex/branch-b']).status, 0);

  const queueBefore = readFileSync(path.join(dir, '.git', 'studiquo-verify.queue'), 'utf8')
    .trim()
    .split('\n');
  assert.deepEqual(queueBefore, ['claude/branch-a', 'codex/branch-b']);

  // Acquire --queue merges both onto main in detached HEAD without altering original branches
  const branchAShaBefore = runGit(dir, ['rev-parse', 'claude/branch-a']);
  const branchBShaBefore = runGit(dir, ['rev-parse', 'codex/branch-b']);

  const acqQueue = runVerifySlot(dir, ['acquire', '--queue']);
  assert.equal(acqQueue.status, 0, acqQueue.stderr);
  assert.match(acqQueue.stdout, /荷台のブランチをまとめた確認枠/);

  assert.equal(readFileSync(path.join(dir, 'fileA.txt'), 'utf8'), 'branch-a-change\n');
  assert.equal(readFileSync(path.join(dir, 'fileB.txt'), 'utf8'), 'branch-b-change\n');
  assert.equal(runGit(dir, ['rev-parse', 'claude/branch-a']), branchAShaBefore);
  assert.equal(runGit(dir, ['rev-parse', 'codex/branch-b']), branchBShaBefore);

  const lockContent = readFileSync(path.join(dir, '.git', 'studiquo-verify.lock'), 'utf8');
  assert.match(lockContent, /branch=queue: claude\/branch-a, codex\/branch-b/);

  // Release clears both the lock and the queue
  const rel = runVerifySlot(dir, ['release']);
  assert.equal(rel.status, 0, rel.stderr);
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.lock')), false);
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.queue')), false);
  assert.equal(runGit(dir, ['symbolic-ref', '--short', 'HEAD']), 'main');
});

test('acquire --queue aborts and restores main without lock when branches conflict', (t) => {
  const dir = createTempRepo();
  t.after(() => rmSync(dir, {recursive: true, force: true}));

  assert.equal(runVerifySlot(dir, ['add', 'claude/branch-a']).status, 0);
  assert.equal(runVerifySlot(dir, ['add', 'claude/branch-conflict']).status, 0);

  const acq = runVerifySlot(dir, ['acquire', '--queue']);
  assert.notEqual(acq.status, 0);
  assert.match(acq.stderr, /重ねる途中で失敗しました/);

  // Lock must not remain, and working tree must be back on main cleanly
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.lock')), false);
  assert.equal(runGit(dir, ['symbolic-ref', '--short', 'HEAD']), 'main');
  assert.equal(runGit(dir, ['status', '--porcelain']), '');

  // Removing the conflicting branch allows acquire --queue to succeed
  assert.equal(runVerifySlot(dir, ['remove', 'claude/branch-conflict']).status, 0);
  assert.equal(runVerifySlot(dir, ['acquire', '--queue']).status, 0);
  assert.equal(runVerifySlot(dir, ['release']).status, 0);
});

test('dirty working tree blocks both acquire and release', (t) => {
  const dir = createTempRepo();
  t.after(() => rmSync(dir, {recursive: true, force: true}));

  // Dirty main blocks acquire
  writeFileSync(path.join(dir, 'fileA.txt'), 'uncommitted-edit\n');
  const dirtyAcq = runVerifySlot(dir, ['acquire', 'claude/branch-a']);
  assert.notEqual(dirtyAcq.status, 0);
  assert.match(dirtyAcq.stderr, /未コミットの変更があるため切り替えません/);

  // Clean up, acquire, then dirty while holding lock -> blocks release
  runGit(dir, ['checkout', '--', 'fileA.txt']);
  assert.equal(runVerifySlot(dir, ['acquire', 'claude/branch-a']).status, 0);

  writeFileSync(path.join(dir, 'fileB.txt'), 'dirty-during-verify\n');
  const dirtyRel = runVerifySlot(dir, ['release']);
  assert.notEqual(dirtyRel.status, 0);
  assert.match(dirtyRel.stderr, /未コミットの変更があるため戻しません/);
  assert.equal(existsSync(path.join(dir, '.git', 'studiquo-verify.lock')), true);
});
