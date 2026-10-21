import test from 'node:test';
import assert from 'node:assert/strict';
import { quantityEvidencePresent, distinctiveTerms, termsMissingFrom } from './rag/detail-presence.ts';
import { retrieve } from './rag/retrieval.ts';
import { indexSource, accountKey } from './rag/storage.ts';
import { qualityEnvironment, qualitySource } from './rag-quality-fixture.ts';

test('a question that asks for a rate needs a rate in the excerpts, not just the topic', () => {
  const ask = '気象予報士試験の合格率は何%ですか。';
  assert.equal(quantityEvidencePresent(ask, '気象予報士試験は国家資格である。受験は年に2回ある。'), false);
  assert.equal(quantityEvidencePresent(ask, '気象予報士試験の合格率は約5%である。'), true);
  assert.equal(quantityEvidencePresent(ask, '合格者は受験者の1割に満たない。'), true);
  assert.equal(quantityEvidencePresent(ask, '合格率は5パーセントである。'), true);
});

test('each asked unit looks for its own kind of number', () => {
  assert.equal(quantityEvidencePresent('発生した件数は年間で何件ですか。', '2012年7月23日に発表された。'), false);
  assert.equal(quantityEvidencePresent('発生した件数は年間で何件ですか。', '年間で12件発生した。'), true);
  assert.equal(quantityEvidencePresent('矢羽は何m/sを表しますか。', '長矢羽は10kt（約5m/s）である。'), true);
  assert.equal(quantityEvidencePresent('矢羽は何m/sを表しますか。', '長矢羽は10ktである。'), false);
  assert.equal(quantityEvidencePresent('ノットは何倍でkm/hになりますか。', 'おおよそ2倍で近似できる。'), true);
  assert.equal(quantityEvidencePresent('水温は何度必要ですか。', '海面から60m程度の深さまで26℃あること。'), true);
  assert.equal(quantityEvidencePresent('緯度は何度付近ですか。', '図では30˚N付近に位置する。'), true);
  assert.equal(quantityEvidencePresent('水温は何度必要ですか。', '海水温が高いこと。'), false);
});

test('several asked units are alternatives, and unit-less quantity words only need some number', () => {
  const ask = '中層は何hPaで、水温は何度以上、どのくらいの深さですか。';
  assert.equal(quantityEvidencePresent(ask, '中層（700hPa）で相対湿度が高いこと。'), true);
  assert.equal(quantityEvidencePresent('スケールはどれくらいですか。', '水平スケールは1000km程度以下。'), true);
  assert.equal(quantityEvidencePresent('スケールはどれくらいですか。', '水平スケールが小さい低気圧。'), false);
  assert.equal(quantityEvidencePresent('個数はいくつですか。', '三つある。'), true);
  assert.equal(quantityEvidencePresent('個数はいくつですか。', 'いくつかある。'), false);
});

test('questions that do not ask for a quantity are never held back by this check', () => {
  for (const q of ['ポーラーロウとはどんな低気圧ですか。', '何度も繰り返す理由は何ですか。', '何件かの例を挙げてください。', '違いを説明して']) {
    assert.equal(quantityEvidencePresent(q, '数字を含まない説明。'), true, q);
  }
});

test('distinctive terms are specific katakana words, not common loanwords', () => {
  assert.deepEqual(distinctiveTerms('ラニーニャ現象と台風の発生数の関係は？'), ['ラニーニャ']);
  assert.deepEqual(distinctiveTerms('おいしいカレーの作り方を教えてください。'), ['カレー']);
  assert.deepEqual(distinctiveTerms('データのパターンを教えて'), []);
  assert.deepEqual(distinctiveTerms('ポーラーロウとは何ですか'), ['ポーラーロウ']);
});

test('a long-vowel mark at the end of a loanword does not decide whether it is present', () => {
  assert.deepEqual(termsMissingFrom('コンピュータの仕組みは？', ['コンピューターは計算する機械。']), []);
  assert.deepEqual(termsMissingFrom('コンピューターの仕組みは？', ['コンピュータは計算する機械。']), []);
  assert.deepEqual(termsMissingFrom('ラニーニャの影響は？', ['エルニーニョは海面水温が高い状態。']), ['ラニーニャ']);
});

// The stub's semantic search ranks pages in the order they were added, while the keyword search
// ranks by text match. Putting an unrelated page first makes the two searches disagree on the top
// result; putting the answering page first makes them agree.
async function ask(pages: any[], query: string, sub = 'synthetic-user', tweak?: (env: any) => void) {
  const env = qualityEnvironment();
  await indexSource(env, await accountKey(sub), qualitySource({ totalPages: pages.length, pages }));
  tweak?.(env);
  return retrieve(env, { sub }, { query });
}
const numbered = (...texts: string[]) => texts.map((text, i) => ({ pageNumber: i + 1, text }));

test('same topic but the asked rate is not written: no citation, status insufficient', async () => {
  const query = '気象予報士試験の合格率は何%ですか。';
  const missing = await ask([{ pageNumber: 1, text: '気象予報士試験は気象に関する国家資格である。試験は年に2回行われる。' }], query);
  assert.equal(missing.status, 'insufficient');
  assert.deepEqual(missing.citations, []);
  assert.equal(missing.context, '');
  const written = await ask([{ pageNumber: 1, text: '気象予報士試験の合格率は約5%である。試験は年に2回行われる。' }], query);
  assert.equal(written.status, 'grounded');
  assert.equal(written.citations.length, 1);
});

test('a word the library never uses cannot be answered from nearby pages', async () => {
  const query = 'ラニーニャ現象と台風の発生数にはどんな関係がありますか。';
  const absent = await ask(numbered('気温の単位は摂氏である。', '台風は熱帯の海上で発生する低気圧である。台風の発生数は夏から秋に多い。'), query);
  assert.deepEqual(absent.citations, []);
  assert.equal(absent.context, '');
  assert.ok(['insufficient', 'no_match'].includes(absent.reason ?? absent.status), String(absent.reason));
  const present = await ask(numbered('気温の単位は摂氏である。', 'ラニーニャ現象が起きると台風の発生数が増える年がある。'), query);
  assert.equal(present.status, 'grounded');
  assert.ok(present.citations.some((c: any) => c.pageNumber === 2));
});

test('an unrelated question falls back to ordinary chat instead of citing the library', async () => {
  const hit = await ask(numbered('地震は断層のずれによって起こる。', '光合成は植物が光を使って養分を作るしくみである。'), 'おいしいカレーの作り方を教えてください。');
  assert.deepEqual(hit.citations, []);
  assert.equal(hit.context, '');
  assert.equal(hit.reason, 'no_match');
});

test('a loanword the excerpt lacks but another page uses is not treated as absent from the library', async () => {
  const hit = await ask(numbered('アメリカ気象学会は用語集を公開している。', '米国西岸の年間降水量の30～50%が大気の川に関連して生じる。'), 'アメリカ西岸の年間降水量のうち、大気の川に関連するものはどれくらいですか。');
  assert.equal(hit.status, 'grounded');
  assert.ok(hit.citations.some((c: any) => c.pageNumber === 2));
});

test('when both searches put the same excerpt first, a missing word is a paraphrase and the excerpt is kept', async () => {
  const query = 'プールの底が本当より浅く見えるのはなぜ？';
  const answer = '水の底は実際より浅く見える。光が水面で屈折して目に届くためである。';
  const agree = await ask(numbered(answer, '気温の単位は摂氏である。'), query);
  assert.equal(agree.status, 'grounded');
  assert.ok(agree.citations.some((c: any) => c.pageNumber === 1));
  // Same words, but the semantic search favors another page: nothing vouches for the paraphrase.
  const disagree = await ask(numbered('気温の単位は摂氏である。', answer), query);
  assert.deepEqual(disagree.citations, []);
});

test('a failed library check never removes evidence', async () => {
  const pages = numbered('気温の単位は摂氏である。', 'ラニーニャ現象が起きると台風の発生数が増える年がある。');
  const query = 'ラニーニャ現象と台風の発生数にはどんな関係がありますか。';
  const hit = await ask(pages, query, 'synthetic-user', (env: any) => {
    const original = env.ADMIN_DB.prepare;
    env.ADMIN_DB.prepare = (sql: string) => {
      if (sql.includes('instr(c.text')) throw new Error('library check unavailable');
      return original(sql);
    };
  });
  assert.equal(hit.status, 'grounded');
});

test('money units are asked for and recognized at any scale', () => {
  const ask = '損害保険金は、1件あたり何万円ですか。';
  assert.equal(quantityEvidencePresent(ask, '損害保険金支払い金額（億円）\n10678\n2018年'), false);
  assert.equal(quantityEvidencePresent(ask, '支払い金額は10678億円だった。'), true);
  assert.equal(quantityEvidencePresent('参加費は何円ですか。', '参加費は5000円。'), true);
  assert.equal(quantityEvidencePresent('参加費は何円ですか。', '参加費は無料。'), false);
  assert.equal(quantityEvidencePresent('価格は何ドルですか。', '価格は12ドル。'), true);
});

test('with tying, the number must be in the top excerpt or in one that names the subject', () => {
  const ask = 'Hurricane Karenの最大風速は何ノットでしたか。';
  const karen = 'Hurricane Karenは2001年9月に発生した。';
  const other = '猛烈な台風は最大風速105kt以上である。';
  const tied = { tied: true };
  assert.equal(quantityEvidencePresent(ask, [{ text: karen, primary: true }, { text: other }], tied), false);
  assert.equal(quantityEvidencePresent(ask, [{ text: karen + '最大風速は80ktだった。', primary: true }, { text: other }], tied), true);
  assert.equal(quantityEvidencePresent(ask, [{ text: karen }, { text: 'Karenの最大風速は80kt。' }], tied), true);
  assert.equal(quantityEvidencePresent(ask, [{ text: other, primary: true }, { text: karen }], tied), true);
  // Without tying (comparisons, plain strings) any excerpt may carry the number, as before.
  assert.equal(quantityEvidencePresent(ask, [{ text: karen, primary: true }, { text: other }]), true);
  assert.equal(quantityEvidencePresent(ask, karen + other, tied), true);
});

test('a subject made only of common words is tied to the top excerpt alone', () => {
  const ask = '台風第21号の最大風速は何m/sでしたか。';
  const top = '台風第21号は2018年9月に上陸した。';
  const other = '台風の強さは最大風速33m/s以上で区別される。';
  assert.equal(quantityEvidencePresent(ask, [{ text: top, primary: true }, { text: other }], { tied: true }), false);
  assert.equal(quantityEvidencePresent(ask, [{ text: top + '最大風速は50m/sだった。', primary: true }, { text: other }], { tied: true }), true);
});

test('a number on an unrelated page does not rescue a question whose own page lacks it', async () => {
  const query = 'Hurricane Karenの最大風速は何ノットでしたか。';
  const hit = await ask(numbered('Hurricane Karenは2001年9月に発生した低気圧である。', '台風の最大風速は105kt以上で猛烈な台風とされる。'), query);
  assert.deepEqual(hit.citations, []);
  assert.equal(hit.context, '');
  const stated = await ask(numbered('Hurricane Karenの最大風速は80ノットだった。', '台風の最大風速は105kt以上で猛烈な台風とされる。'), query);
  assert.equal(stated.status, 'grounded');
});
