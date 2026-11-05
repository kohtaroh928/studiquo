import test from 'node:test';
import assert from 'node:assert/strict';
import { planReconcile, kvCategory } from './lib.ts';

const item = (name: string, value: string) => ({ name, value });

test('an earlier value wins over the restored one', () => {
  const plan = planReconcile([item('account:local:x', 'new-hash')], [item('account:local:x', 'old-hash')]);
  assert.deepEqual(plan.put, [item('account:local:x', 'new-hash')]);
  assert.deepEqual(plan.remove, []);
});

test('a key the restore added that was gone before is removed', () => {
  const plan = planReconcile([], [item('mcp:grant:a:b', '{}'), item('session:abc', '{}')]);
  assert.deepEqual(plan.remove.sort(), ['mcp:grant:a:b', 'session:abc']);
});

test('keys that are safe to lose and to get back stay', () => {
  assert.equal(kvCategory('actions:abc'), 'may-lose');
  const plan = planReconcile([], [item('actions:abc', '[]')]);
  assert.deepEqual(plan.remove, []);
  assert.equal(plan.keptFromBackup, 1);
});

test('an unchanged key is not written again', () => {
  assert.deepEqual(planReconcile([item('chat:user:a', '1')], [item('chat:user:a', '1')]).put, []);
});

test('a key that exists only in the earlier state is put back', () => {
  assert.deepEqual(planReconcile([item('account-deletion:h', '{"status":"deleting"}')], []).put, [item('account-deletion:h', '{"status":"deleting"}')]);
});
