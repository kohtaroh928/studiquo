import test from 'node:test';
import assert from 'node:assert/strict';
import {normalize, score, finalStatus, loadRubric} from './score.mjs';

// Hand-written strings that exercise the checks. They are not model answers.
const P3 = 'development:e50-partial-03';
const NP = 'boundary:boundary-different-conditions';
const status = (report, variant, caseKey, style, itemId) =>
  finalStatus(report.rows.find(r => r.variant === variant && r.caseKey === caseKey && r.style === style && r.itemId === itemId));

test('normalize absorbs full-width digits, commas, LaTeX units and spaces', () => {
  assert.equal(normalize('$300\\,\\text{円/時間}$'), '300円/時間');
  assert.equal(normalize('１，５００ 円'), '1500円');
});

test('rubric covers every frozen case and only known categories', () => {
  const rubric = loadRubric();
  assert.equal(Object.keys(rubric.cases).length, 6);
  const cats = new Set(Object.keys(rubric.categories));
  for (const item of [...rubric.common, ...Object.values(rubric.cases).flatMap(c => c.items)]) {
    assert.ok(cats.has(item.category), item.id);
    for (const p of [...(item.any ?? []), ...(item.all ?? []), ...(item.forbid ?? []), ...(item.flag ?? [])]) new RegExp(p, 'u');
  }
});

test('the known omission (missing 2-hour delta) is detected and a fix counts as improved', () => {
  const listOnly = 'Eは点灯5時間で価格1600円です。Fは点灯7時間で、価格は資料で確認できません。そのため、お得な方は判断できません。';
  const withDelta = 'Eは点灯5時間で価格1600円です。Fは点灯7時間で、Eより2時間長いです。Fの価格は資料で確認できません。そのため、お得な方は判断できません。';
  const report = score({variants: {baseline: {[P3 + '|source_only']: listOnly}, cand: {[P3 + '|source_only']: withDelta}}});
  assert.equal(status(report, 'baseline', P3, 'source_only', 'p3-delta'), 'pending_omission');
  assert.equal(status(report, 'cand', P3, 'source_only', 'p3-delta'), 'satisfied');
  assert.equal(status(report, 'cand', P3, 'source_only', 'p3-f-price-unknown'), 'satisfied');
  assert.equal(status(report, 'cand', P3, 'source_only', 'p3-no-winner'), 'satisfied');
  assert.deepEqual(report.paired[0].changes.map(c => [c.itemId, c.direction]), [['p3-delta', 'improved']]);
});

test('invented values and forbidden deltas are violations; manual verdict overrides', () => {
  const bad = 'Nの方が4時間長く、1時間あたり333円なのでNの方がお得です。';
  const report = score({variants: {v: {[NP + '|explain']: bad}}}, {['v|' + NP + '|explain|np-no-delta']: 'incorrect'});
  assert.equal(status(report, 'v', NP, 'explain', 'np-no-ratio'), 'pending_violation');
  assert.equal(status(report, 'v', NP, 'explain', 'np-no-winner'), 'pending_violation');
  assert.equal(status(report, 'v', NP, 'explain', 'np-no-delta'), 'incorrect');
  assert.equal(status(report, 'v', NP, 'explain', 'np-cannot-judge'), 'pending_omission');
});

test('explain background needs a label before it; source_only background is flagged', () => {
  const unlabeled = '価格は2000円で同じです。一般的に明るさが強いほど電池は早く減ります。';
  const labeled = '条件が違うため、お得な方は判断できません。理解のための補足: 一般的に明るさが強いほど電池は早く減ります。';
  const report = score({variants: {a: {[NP + '|explain']: unlabeled, [NP + '|source_only']: unlabeled}, b: {[NP + '|explain']: labeled}}});
  assert.equal(status(report, 'a', NP, 'explain', 'x-explain-label-first'), 'pending_review');
  assert.equal(status(report, 'a', NP, 'source_only', 'x-source-only-no-supplement'), 'pending_review');
  assert.equal(status(report, 'b', NP, 'explain', 'x-explain-label-first'), 'satisfied');
});

test('unknown cases, styles and manual verdicts are rejected', () => {
  assert.throws(() => score({variants: {v: {'other|explain': 'x'}}}), /unknown_case/);
  assert.throws(() => score({variants: {v: {[P3 + '|both']: 'x'}}}), /invalid_answer_key/);
  assert.throws(() => score({variants: {v: {[P3 + '|explain']: 'x'}}}, {k: 'pass'}), /invalid_manual_verdict/);
});

test('rubric v2 accepts "差はありません" and "判断できず" without accepting "差はあります"', () => {
  const LM = 'boundary:boundary-equal-category';
  const same = '点灯時間はL・Mともに6時間で、差はありません。価格はどちらも1800円です。Lは屋内、Mは屋外です。';
  const differs = '点灯時間はL・Mともに6時間ですが、差はあります。価格は1800円です。Lは屋内、Mは屋外です。';
  const verdict = 'Eは点灯5時間で1600円、Fは点灯7時間です。Fの価格が分からないため、お得な方は判断できず、全体の比較を資料で裏付けることはできません。';
  const report = score({variants: {a: {[LM + '|explain']: same, [P3 + '|explain']: verdict}, b: {[LM + '|explain']: differs}}});
  assert.equal(status(report, 'a', LM, 'explain', 'lm-same'), 'satisfied');
  assert.equal(status(report, 'b', LM, 'explain', 'lm-same'), 'pending_omission');
  assert.equal(status(report, 'a', P3, 'explain', 'p3-no-verdict'), 'satisfied');
});
