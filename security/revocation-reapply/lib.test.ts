import test from 'node:test';
import assert from 'node:assert/strict';
import { planReapply } from './lib.ts';

const NOW = Date.UTC(2026, 10, 9);
const row = (at: number, kind: string, subject: string, value = '') => ({ at, kind, subject, value });

test('a deleted account is held closed and listed for purge', () => {
  const plan = planReapply([row(1, 'account-deleted', 'aa')], NOW);
  assert.deepEqual(plan.heldAccounts, ['aa']);
  assert.equal(JSON.parse(plan.put[0].value).status, 'deleting');
  assert.equal(plan.put[0].name, 'account-deletion:aa');
});

test('a re-registration after the deletion lifts the hold; a later deletion restores it', () => {
  assert.deepEqual(planReapply([row(1, 'account-deleted', 'aa'), row(2, 'account-reregistered', 'aa')], NOW).heldAccounts, []);
  assert.deepEqual(planReapply([row(1, 'account-deleted', 'aa'), row(2, 'account-reregistered', 'aa'), row(3, 'account-deleted', 'aa')], NOW).heldAccounts, ['aa']);
});

test('the newest session cut-off wins and an expired one is dropped', () => {
  const recent = NOW - 1000, older = NOW - 5000, ancient = NOW - 200 * 86_400_000;
  const plan = planReapply([row(1, 'session-cutoff', 'aa', String(older)), row(2, 'session-cutoff', 'aa', String(recent)), row(3, 'session-cutoff', 'bb', String(ancient))], NOW);
  assert.deepEqual(plan.put.map(item => [item.name, item.value]), [['session-valid-from:aa', String(recent)]]);
});

test('rows at or before the backup time are skipped', () => {
  const plan = planReapply([row(10, 'account-deleted', 'aa'), row(20, 'account-deleted', 'bb')], NOW, 10);
  assert.deepEqual(plan.heldAccounts, ['bb']);
});

test('suspension: last word wins, cleared ones are removed', () => {
  const plan = planReapply([row(1, 'suspension-set', 'account-suspended:aa'), row(2, 'suspension-cleared', 'account-suspended:aa'), row(3, 'suspension-set', 'chat-suspended:bb')], NOW);
  assert.deepEqual(plan.remove, ['account-suspended:aa']);
  assert.deepEqual(plan.put.map(item => item.name), ['chat-suspended:bb']);
});

test('revoked connections are removed by prefix; garbage values are ignored', () => {
  const plan = planReapply([row(1, 'connections-revoked', 'aa'), row(2, 'session-cutoff', 'bb', 'nope')], NOW);
  assert.deepEqual(plan.removePrefix, ['mcp:grant:aa:']);
  assert.deepEqual(plan.put, []);
});

test('rows sharing the same millisecond timestamp are ordered by id so the later id wins', () => {
  const sameAt = 5000;
  // Provided out of id order: id=2 (re-registered) must win over id=1 (deleted), and id=4 (cleared) over id=3 (suspended)
  const plan = planReapply([
    { id: 2, at: sameAt, kind: 'account-reregistered', subject: 'aa' },
    { id: 1, at: sameAt, kind: 'account-deleted', subject: 'aa' },
    { id: 4, at: sameAt, kind: 'suspension-cleared', subject: 'account-suspended:bb' },
    { id: 3, at: sameAt, kind: 'suspension-set', subject: 'account-suspended:bb' },
  ], NOW);
  assert.deepEqual(plan.heldAccounts, []);
  assert.deepEqual(plan.remove, ['account-suspended:bb']);
  assert.deepEqual(plan.put, []);
});
