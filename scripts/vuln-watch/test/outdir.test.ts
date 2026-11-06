import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, symlinkSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { checkedOutDir } from '../src/outdir.ts';

const toolDir = resolve(import.meta.dirname, '..');

test('the tool\'s own out directory and temporary directories are accepted', () => {
  assert.ok(checkedOutDir(join(toolDir, 'out'), toolDir));
  assert.ok(checkedOutDir(join(toolDir, 'out', 'nested'), toolDir));
  assert.ok(checkedOutDir(join(mkdtempSync(join(tmpdir(), 'vw-')), 'run'), toolDir));
});

test('anything else is refused', () => {
  for (const bad of ['/', '/etc', '/Users', join(toolDir, '..'), join(toolDir, 'src'), join(toolDir, 'out', '..', 'src'), '/tmpfoo', join(tmpdir(), '..')]) {
    assert.equal(checkedOutDir(bad, toolDir), null, bad);
  }
});

test('a symlink inside an allowed root cannot lead out of it', () => {
  const base = mkdtempSync(join(tmpdir(), 'vw-link-'));
  mkdirSync(join(base, 'real'));
  symlinkSync('/etc', join(base, 'escape'));
  assert.equal(checkedOutDir(join(base, 'escape', 'x'), toolDir), null);
  assert.ok(checkedOutDir(join(base, 'real', 'x'), toolDir));
});
