import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, chmodSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const SCRIPT_PATH = fileURLToPath(new URL('./cleanup-branches', import.meta.url));

function runGit(cwd, args) {
  const res = spawnSync('git', args, {cwd, encoding: 'utf8'});
  if (res.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${res.stderr}`);
  }
  return res.stdout.trim();
}

function setupReposAndMockGh() {
  const root = mkdtempSync(path.join(tmpdir(), 'cleanup-branches-test-'));
  const remoteDir = path.join(root, 'remote.git');
  const mainDir = path.join(root, 'main');
  const binDir = path.join(root, 'bin');
  mkdirSync(remoteDir);
  mkdirSync(mainDir);
  mkdirSync(binDir);

  runGit(remoteDir, ['init', '--bare', '-b', 'main']);

  runGit(mainDir, ['init', '-b', 'main']);
  runGit(mainDir, ['config', 'user.name', 'Test User']);
  runGit(mainDir, ['config', 'user.email', 'test@example.com']);
  runGit(mainDir, ['remote', 'add', 'origin', remoteDir]);

  writeFileSync(path.join(mainDir, 'base.txt'), 'base\n');
  runGit(mainDir, ['add', 'base.txt']);
  runGit(mainDir, ['commit', '-m', 'initial']);
  runGit(mainDir, ['push', '-u', 'origin', 'main']);

  // 1. claude/merged-clean: PR is MERGED, merged into main, has a clean worktree & remote branch
  const wtClean = path.join(root, 'wt-merged-clean');
  runGit(mainDir, ['worktree', 'add', wtClean, '-b', 'claude/merged-clean', 'main']);
  writeFileSync(path.join(wtClean, 'clean.txt'), 'merged-clean\n');
  runGit(wtClean, ['add', 'clean.txt']);
  runGit(wtClean, ['commit', '-m', 'add clean.txt']);
  runGit(wtClean, ['push', '-u', 'origin', 'claude/merged-clean']);
  runGit(mainDir, ['merge', '--no-ff', '--no-edit', 'claude/merged-clean']);
  runGit(mainDir, ['push', 'origin', 'main']);

  // 2. codex/squash-merged: PR is MERGED, squash-merged into main (same patch-id via git cherry)
  runGit(mainDir, ['branch', 'codex/squash-merged', 'main']);
  const wtSquash = path.join(root, 'wt-squash');
  runGit(mainDir, ['worktree', 'add', wtSquash, 'codex/squash-merged']);
  writeFileSync(path.join(wtSquash, 'squash.txt'), 'squash-content\n');
  runGit(wtSquash, ['add', 'squash.txt']);
  runGit(wtSquash, ['commit', '-m', 'add squash.txt']);
  // Apply the exact same patch onto main so `git cherry origin/main codex/squash-merged` has only '-'
  writeFileSync(path.join(mainDir, 'squash.txt'), 'squash-content\n');
  runGit(mainDir, ['add', 'squash.txt']);
  runGit(mainDir, ['commit', '-m', 'squash merge add squash.txt']);
  runGit(mainDir, ['push', 'origin', 'main']);

  // 3. claude/merged-dirty: PR is MERGED and ancestor of origin/main, but worktree has uncommitted changes
  const wtDirty = path.join(root, 'wt-merged-dirty');
  runGit(mainDir, ['worktree', 'add', wtDirty, '-b', 'claude/merged-dirty', 'main']);
  writeFileSync(path.join(wtDirty, 'uncommitted.txt'), 'dirty\n');

  // 4. claude/merged-ahead: PR is MERGED, but local branch has a new unmerged commit not on origin/main
  runGit(mainDir, ['switch', '-c', 'claude/merged-ahead', 'main']);
  writeFileSync(path.join(mainDir, 'ahead.txt'), 'unmerged-work\n');
  runGit(mainDir, ['add', 'ahead.txt']);
  runGit(mainDir, ['commit', '-m', 'unmerged commit']);
  runGit(mainDir, ['switch', 'main']);

  // 5. codex/open-pr: PR is OPEN (even though ancestor of main)
  runGit(mainDir, ['branch', 'codex/open-pr', 'main']);

  // 6. antigravity/no-pr: no PR at all
  runGit(mainDir, ['branch', 'antigravity/no-pr', 'main']);

  // Mock `gh` CLI that returns MERGED / OPEN / empty according to `--head <branch>`
  const ghMockPath = path.join(binDir, 'gh');
  writeFileSync(
    ghMockPath,
    `#!/bin/sh
branch=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--head" ]; then
    branch="$2"
    shift 2
  else
    shift 1
  fi
done
case "$branch" in
  claude/merged-clean|codex/squash-merged|claude/merged-dirty|claude/merged-ahead|claude/in-main-dir)
    echo "MERGED"
    ;;
  codex/open-pr)
    echo "OPEN"
    ;;
  *)
    echo ""
    ;;
esac
`
  );
  chmodSync(ghMockPath, 0o755);

  return {root, remoteDir, mainDir, binDir, wtClean, wtSquash, wtDirty};
}

function runCleanup(cwd, binDir, args = []) {
  return spawnSync('sh', [SCRIPT_PATH, ...args], {
    cwd,
    encoding: 'utf8',
    env: {...process.env, PATH: `${binDir}:${process.env.PATH}`},
  });
}

test('dry-run lists candidates and protected branches without deleting anything', (t) => {
  const {root, mainDir, binDir, wtClean, wtSquash} = setupReposAndMockGh();
  t.after(() => rmSync(root, {recursive: true, force: true}));

  const res = runCleanup(mainDir, binDir, []);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /削除\s+claude\/merged-clean \+ worktree/);
  assert.match(res.stdout, /削除\s+codex\/squash-merged \+ worktree/);
  assert.match(res.stdout, /残す\s+claude\/merged-dirty \(worktreeに未コミット変更あり/);
  assert.match(res.stdout, /残す\s+claude\/merged-ahead \(origin\/mainに無いコミットあり\)/);
  assert.match(res.stdout, /残す\s+codex\/open-pr \(PR: OPEN\)/);
  assert.match(res.stdout, /残す\s+antigravity\/no-pr \(PR: なし\)/);
  assert.match(res.stdout, /\(確認のみ。実行するには --yes\)/);

  // Nothing was actually removed in dry-run
  assert.equal(existsSync(wtClean), true);
  assert.equal(existsSync(wtSquash), true);
  const branches = runGit(mainDir, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']).split('\n');
  assert.ok(branches.includes('claude/merged-clean'));
  assert.ok(branches.includes('codex/squash-merged'));
});

test('--yes deletes only merged & clean branches, worktrees, and remote refs while protecting others', (t) => {
  const {root, remoteDir, mainDir, binDir, wtClean, wtSquash, wtDirty} = setupReposAndMockGh();
  t.after(() => rmSync(root, {recursive: true, force: true}));

  const res = runCleanup(mainDir, binDir, ['--yes']);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /リモートも削除/);

  // Merged & clean worktrees and branches are removed (including remote ref)
  assert.equal(existsSync(wtClean), false);
  assert.equal(existsSync(wtSquash), false);
  const branchesAfter = runGit(mainDir, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']).split('\n');
  assert.equal(branchesAfter.includes('claude/merged-clean'), false);
  assert.equal(branchesAfter.includes('codex/squash-merged'), false);

  const remoteRefs = runGit(remoteDir, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']).split('\n');
  assert.equal(remoteRefs.includes('claude/merged-clean'), false);

  // Protected branches and dirty worktree remain untouched
  assert.equal(existsSync(wtDirty), true);
  assert.ok(branchesAfter.includes('main'));
  assert.ok(branchesAfter.includes('claude/merged-dirty'));
  assert.ok(branchesAfter.includes('claude/merged-ahead'));
  assert.ok(branchesAfter.includes('codex/open-pr'));
  assert.ok(branchesAfter.includes('antigravity/no-pr'));
});

test('branch currently checked out in the main directory is protected even if PR is MERGED', (t) => {
  const {root, mainDir, binDir} = setupReposAndMockGh();
  t.after(() => rmSync(root, {recursive: true, force: true}));

  runGit(mainDir, ['switch', '-c', 'claude/in-main-dir', 'main']);
  const res = runCleanup(mainDir, binDir, ['--yes']);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /残す\s+claude\/in-main-dir \(mainのフォルダで使用中\)/);

  const branches = runGit(mainDir, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']).split('\n');
  assert.ok(branches.includes('claude/in-main-dir'));
});
