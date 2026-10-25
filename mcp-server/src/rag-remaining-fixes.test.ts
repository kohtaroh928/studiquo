import test from 'node:test';
import assert from 'node:assert/strict';
import { retrieve } from './rag/retrieval.ts';
import { queryPlan } from './rag/query.ts';
import { indexSource, accountKey } from './rag/storage.ts';
import { detailRequirements, assessReference } from './rag/answerability.ts';
import { quantityEvidencePresent } from './rag/detail-presence.ts';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';

async function ask(pages: any[], query: string, sub = 'synthetic-user') {
  const env = qualityEnvironment();
  await indexSource(env, await accountKey(sub), qualitySource({ totalPages: pages.length, pages }));
  return retrieve(env, { sub }, { query });
}
const numbered = (...texts: string[]) => texts.map((text, i) => ({ pageNumber: i + 1, text }));

test('"何時" and "何時間" are asked by their unit, not by a date', () => {
  assert.deepEqual(detailRequirements('天気図の0000UTCは、日本時間で何時にあたりますか。').facets, []);
  assert.deepEqual(detailRequirements('QEⅡストームは、何時間で何hPa低下しましたか。').facets, []);
  // A date or a clock time that is asked for by name still needs a concrete value.
  assert.deepEqual(detailRequirements('月の2027年の満月日時を教えて').facets, ['time']);
  assert.deepEqual(detailRequirements('火山の最新噴火時刻を教えて').facets, ['time']);
  assert.equal(assessReference('月の満月は、月は太陽の光を反射して見える。', detailRequirements('月の2027年の満月日時を教えて')).accepted, false);
});

test('an hour of the day and a length of time are told apart by detail-presence', () => {
  const hour = '天気図の0000UTCは、日本時間で何時にあたりますか。';
  assert.equal(quantityEvidencePresent(hour, '2016年4月7日0000UTC（0900JST）の地上天気図。'), true);
  assert.equal(quantityEvidencePresent(hour, '午後3時に開始する。'), true);
  assert.equal(quantityEvidencePresent(hour, '開始は13:15である。'), true);
  assert.equal(quantityEvidencePresent(hour, '地上天気図は海面気圧と前線を示す。'), false);
  const length = 'QEⅡストームは、何時間で何hPa低下しましたか。';
  assert.equal(quantityEvidencePresent(length, '24時間で990hPa→945hPaに低下した。'), true);
  assert.equal(quantityEvidencePresent(length, '低気圧は急速に発達した。'), false);
  // "何時間" is not an hour of the day: a bare "9時" does not answer it.
  assert.equal(quantityEvidencePresent('何時間かかりますか。', '9時に出発する。'), false);
  assert.equal(quantityEvidencePresent('何時間かかりますか。', '3時間かかる。'), true);
});

test('a unit question whose cut-out subject is a clause is left to the unit check; a plain subject keeps its check', () => {
  const clause = detailRequirements('熱帯低気圧が発生するための条件で、中層の相対湿度は何hPaの高さで、海水温は何度以上必要ですか。');
  assert.deepEqual(clause.facets, []);
  const plain = detailRequirements('三角形の三つの角を全部足すと何度？');
  assert.deepEqual(plain.facets, ['quantity']);
  assert.equal(assessReference('三角形の内角の和は180度。', plain).accepted, true);
  assert.equal(assessReference('三角形は三つの辺で囲まれた図形である。', plain).accepted, false);
});

test('a condition list that answers a multi-unit question is grounded', async () => {
  const hit = await ask(numbered('熱帯低気圧の発生条件。海面から60m程度の深さまで26℃あること。中層（700hPa）で相対湿度が高いこと。', '気温の単位は摂氏である。'),
    '熱帯低気圧が発生するための条件で、中層の相対湿度は何hPaの高さで、海水温は何度以上必要ですか。');
  assert.equal(hit.status, 'grounded');
  assert.ok(hit.citations.some((c: any) => c.pageNumber === 1));
  const missing = await ask(numbered('熱帯低気圧の発生条件。海水温が高いこと。中層で相対湿度が高いこと。'),
    '熱帯低気圧が発生するための条件で、中層の相対湿度は何hPaの高さで、海水温は何度以上必要ですか。');
  assert.equal(missing.detail, 'quantity');
});

test('a clock time is found on the page, and a length of time is not mistaken for a date', async () => {
  const clock = await ask(numbered('天気図は2016年4月7日0000UTC（0900JST）の観測である。', '気温の単位は摂氏である。'), '0000UTCは日本時間で何時にあたりますか。');
  assert.equal(clock.status, 'grounded');
  const lengthOfTime = await ask(numbered('QEⅡストームは、24時間で990hPaから945hPaへ低下した。', '気温の単位は摂氏である。'), 'QEⅡストームは何時間で何hPa低下しましたか。');
  assert.equal(lengthOfTime.status, 'grounded');
  const none = await ask(numbered('天気図は海面気圧と前線を示す。'), '0000UTCは日本時間で何時にあたりますか。');
  assert.equal(none.detail, 'quantity');
});

test('two subjects joined by と and followed by は are planned as two subjects; one subject with two aspects is not', () => {
  const two = queryPlan('ポーラーロウと上層寒冷低気圧は、どこで発生し、どんな温度の特徴がありますか。');
  assert.deepEqual(two.coverageGroups, ['ポーラーロウ', '上層寒冷低気圧']);
  assert.equal(two.multi, true);
  assert.equal(two.queries.length, 3);
  assert.deepEqual(queryPlan('梅雨前線とオホーツク海高気圧は何ですか。').coverageGroups, ['梅雨前線', 'オホーツク海高気圧']);
  for (const one of ['ポーラーロウの特徴と発生条件は何ですか。', 'メリットとデメリットは何ですか。', '台風の発生と上陸は何月に多いですか。',
    '地球と月の関係は何ですか。', '台風とは何ですか。', '大気の川と梅雨前線は、どんな現象ですか。']) assert.deepEqual(queryPlan(one).coverageGroups, [], one);
  // The と of "という", "とされる", "といった" labels a name; it does not join a second subject.
  for (const label of ['ハイブリッド低気圧という呼び方は、学会などで定義が定まっていますか。', '爆弾低気圧とされる基準は、何hPaですか。',
    'Medicaneという言葉は、何と何からの造語ですか。', '湿潤絶対不安定という状態は、どんなときに見られますか。', '台風といった現象は、いつ多いですか。']) {
    assert.deepEqual(queryPlan(label).coverageGroups, [], label);
  }
  // Wording that already names a comparison is planned exactly as before.
  assert.deepEqual(queryPlan('電流計と電圧計の違いは何ですか。').coverageGroups, ['電流計', '電圧計']);
});

test('the page of the second subject is kept even when seven pages about the first would fill the answer', async () => {
  const polar = [
    'ポーラーロウは、冬季に寒帯前線の寒気側の海上に発生する低気圧で、水平スケールは1000km程度以下である。',
    'ポーラーロウの発生には、大陸からの寒気の吹き出しと、相対的に暖かい海水温による不安定が関係する。',
    'ポーラーロウには、台風のようなスパイラル状やコンマ雲状など、構造の多様性がある。',
    '日本付近のポーラーロウとしては、石狩湾の小低気圧がよく知られている。札幌で大雪となることがある。',
    'ポーラーロウは、下層では暖気核を持つことがあり、後に総観規模の低気圧として発達することもある。',
    'ポーラーロウの数値実験では、水平温度傾度がない場合は台風に似た軸対称的構造になる。',
    'ポーラーロウの発達には、上層トラフの接近が影響する事例がある。',
  ];
  const cold = '上層寒冷低気圧は、対流圏では中心付近に寒気を持つことが特徴で、低気圧性循環は上空ほど強い。';
  const pages = numbered(...polar, cold);
  const hit = await ask(pages, 'ポーラーロウと上層寒冷低気圧は、どこで発生し、どんな温度の特徴がありますか。');
  assert.ok(['grounded', 'partial'].includes(hit.status), String(hit.status));
  assert.ok(hit.citations.some((c: any) => c.pageNumber === 8), 'the second subject page is cited');
  assert.ok(hit.citations.some((c: any) => c.pageNumber <= 7), 'a first subject page is cited');
  // Without a second subject in the question, the same library still answers from the first subject alone.
  const single = await ask(pages, 'ポーラーロウは、どこで発生し、どんな特徴がありますか。');
  assert.equal(single.status, 'grounded');
});
