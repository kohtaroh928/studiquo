import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {preparePacket, loadCaseSet} from './workspace.ts';
import {capture, validateCases, writeCaseSet} from './capture-extra-cases.ts';
import {buildPlan} from './run-luna.mjs';
import {loadRubric} from './score.mjs';

const candidate = JSON.parse(readFileSync(new URL('./candidates/example.json', import.meta.url), 'utf8'));
const cases = [{key: 'extra:loan-period', question: '2027年5月に登録した人の貸出期間は?', expectedStatus: 'grounded',
  pages: [{pageNumber: 1, text: '図書館の貸出期間は2週間です。2027年4月1日以降に新規登録した人は3週間になります。'}]}];

test('captured extra cases keep the frozen pairing and leave the fixed set untouched', async () => {
  const log = console.log; console.log = () => {};
  let rows; try {rows = await capture(validateCases(cases));} finally {console.log = log;}
  const dir = mkdtempSync(path.join(tmpdir(), 'extra-'));
  writeCaseSet(dir, rows);
  const packet = preparePacket(candidate, 'extra', dir);
  assert.equal(packet.caseSet, 'extra');
  assert.equal(packet.pairs.length, 2);
  for (const row of packet.pairs) {
    const {instructions: a, ...left} = row.baseline, {instructions: b, ...right} = row.candidate;
    assert.deepEqual(left, right);
    assert.equal(b, a + '\n\n' + candidate.additionalInstructions);
    assert.ok(a.includes('学習アプリ「Studiquo」'));
  }
  assert.equal(preparePacket(candidate).pairs.length, 12);
  assert.equal(preparePacket(candidate).caseSet, 'fixed6');
  // a changed context no longer matches its manifest
  const tampered = JSON.parse(readFileSync(path.join(dir, 'contexts-extra.json'), 'utf8'));
  tampered[0].baseInstructions += 'x';
  writeFileSync(path.join(dir, 'contexts-extra.json'), JSON.stringify(tampered));
  assert.throws(() => loadCaseSet('extra', dir), /extra_cases_corrupt/);
});

test('invalid case sets, case files and rubric names are rejected', () => {
  assert.throws(() => loadCaseSet('other'), /invalid_case_set/);
  assert.throws(() => loadRubric('other'), /invalid_rubric_name/);
  for (const bad of [[], [{...cases[0], key: 'loan'}], [{...cases[0], expectedStatus: 'maybe'}],
    [{...cases[0], pages: [{pageNumber: 2, text: 'x'}]}], [cases[0], cases[0]]]) {
    assert.throws(() => validateCases(bad), /invalid_cases/);
  }
});

test('the default plan is unchanged by the case-set option', () => {
  assert.equal(buildPlan(['example']).planHash, buildPlan(['example'], undefined, 'fixed6').planHash);
});

test('the fresh case set loads from its own files and rubric name', async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'rag-fresh-'));
  const contexts = await capture(validateCases(cases));
  writeCaseSet(dir, contexts, 'fresh');
  assert.equal(loadCaseSet('fresh', dir).contexts.length, contexts.length);
  assert.throws(() => loadCaseSet('extra', dir));
  assert.equal(loadRubric('fresh').id, 'fresh12-atomic-v1');
});
