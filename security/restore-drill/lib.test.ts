import test from 'node:test';
import assert from 'node:assert/strict';
import {
  actorCell,
  kvCategory,
  kvFamily,
  nonDiscriminating,
  planReconcile,
  redact,
  routeOf,
  splitSql,
  stripJsonc,
  verdictFor,
} from './lib.ts';

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

test('splitSql keeps CREATE TRIGGER blocks with nested CASE...END and inner semicolons intact', () => {
  const sql = `
    -- comment with ; inside
    /* block comment ; */
    CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT);
    CREATE TRIGGER t_guard BEFORE DELETE ON t
    BEGIN
      SELECT CASE WHEN OLD.a = 'x;y' THEN RAISE(ABORT, 'locked;cannot delete') END;
    END;
    INSERT INTO t (a) VALUES ('semi;colon');
  `;
  const statements = splitSql(sql);
  assert.equal(statements.length, 3);
  assert.match(statements[0], /^CREATE TABLE t/);
  assert.match(statements[1], /^CREATE TRIGGER t_guard[\s\S]*END;$/);
  assert.match(statements[2], /^INSERT INTO t/);
});

test('stripJsonc removes line comments, block comments, and trailing commas while preserving URLs in strings', () => {
  const jsonc = `{
    // line comment
    "url": "https://example.test/path // not a comment /* neither */",
    /* block
       comment */
    "items": [1, 2, ],
    "nested": { "ok": true, },
  }`;
  assert.deepEqual(JSON.parse(stripJsonc(jsonc)), {
    url: 'https://example.test/path // not a comment /* neither */',
    items: [1, 2],
    nested: { ok: true },
  });
});

test('verdictFor, actorCell, nonDiscriminating, redact, kvFamily, and routeOf classify and scrub accurately', () => {
  const accessProbe = { id: 'p-access', kind: 'access' as const, stage: 'backup' as const };
  const dataProbe = { id: 'p-data', kind: 'data' as const, stage: 'backup' as const };
  const controlProbe = { id: 'p-ctrl', kind: 'control' as const, stage: 'backup' as const };
  const replayProbe = { id: 'p-replay', kind: 'replay' as const, stage: 'backup' as const };
  const postProbe = { id: 'p-post', kind: 'post-backup' as const, stage: 'post' as const };

  assert.equal(verdictFor(accessProbe, '200:ok', '401:revoked', '500:boom'), 'server-error');
  assert.equal(verdictFor(accessProbe, '200:ok', '401:revoked', '401:revoked'), 'not-revived');
  assert.equal(verdictFor(accessProbe, '200:ok', '401:revoked', '200:ok'), 'reverted');
  assert.equal(verdictFor(accessProbe, '200:ok', '401:revoked', '403:other'), 'partial');
  assert.equal(verdictFor(controlProbe, '200:ok', '200:ok', '200:ok'), 'unchanged');
  assert.equal(verdictFor(controlProbe, '200:ok', '200:ok', '401:lost'), 'control-lost');
  assert.equal(verdictFor(replayProbe, '0', '0', '1'), 'replayed');
  assert.equal(verdictFor(postProbe, undefined, '200:new', '404:gone'), 'lost');

  assert.equal(actorCell(['not-revived', 'unchanged', 'kept'], ['access', 'control', 'post-backup']), '.');
  assert.equal(
    actorCell(['reverted', 'reverted', 'replayed', 'partial', 'server-error', 'control-lost', 'lost'],
              ['access', 'data', 'replay', 'access', 'access', 'control', 'post-backup']),
    'RDJPECL',
  );

  assert.deepEqual(
    nonDiscriminating([accessProbe, dataProbe], { 'p-access': '401', 'p-data': '200' }, { 'p-access': '401', 'p-data': '404' }),
    ['p-access'],
  );

  const scrubbed = redact([
    'user@example.com',
    '1700000000.abcdef0123456789abcdef',
    'mcp_abcdef0123456789',
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_123',
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  ].join(' '));
  assert.equal(scrubbed, '[address] [token] [token] [jwt] [hash]');

  assert.equal(kvFamily('passkeys:credential:abc'), 'passkeys:credential:');
  assert.equal(kvFamily('unknown:key'), '(unclassified)');
  assert.equal(routeOf('/api/document/rooms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/changes/42?x=1'), '/api/document/rooms/:hash/changes/:n');
});
