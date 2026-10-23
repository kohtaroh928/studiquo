// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {ragAnswerPolicy} from './rag/answer-policy.ts';
import {fixture, evaluateCase} from '../scripts/rag-quality/final-answer-evaluate.ts';

// Mock transport tests validate the production prompt path, not LLM quality.
const mockAnswer = () => new Response('data: {"type":"response.output_text.delta","delta":"synthetic answer"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n');
async function capture(c) {
 const requests = [];
 const result = await evaluateCase(c, {openaiFetch: async (_url, options) => {
  requests.push(JSON.parse(options.body));
  return mockAnswer();
 }});
 assert.equal(requests.length, 1);
 assert.equal(result.httpStatus, 200);
 return {request: requests[0], result};
}

for (const id of ['grounded-number', 'partial-one-subject']) {
 test(`production ${id} carries presentation rules after untrusted reference data`, async () => {
  const c = fixture.cases.find(c => c.id === id);
  const {request, result} = await capture(c);
  assert.equal(result.status, c.expectedStatus);
  const system = request.instructions;
  const policy = ragAnswerPolicy(c.expectedStatus);
  assert.ok(system.endsWith(policy));
  assert.ok(system.indexOf('untrustedReferences') < system.lastIndexOf(policy));
  assert.match(policy, /資料で確認できる単位を数値とともに保持/);
  assert.match(policy, /単位を省く表記ではどの単位で表した数値か明示/);
  assert.match(policy, /不要な代入式は作らない/);
  assert.match(policy, /基準日・タイムゾーン・週の範囲/);
  assert.match(policy, /必要な条件・例外を省略しない/);
  assert.match(policy, /質問された項目と、その回答を判断するために不可欠な情報に限って/);
  assert.match(policy, /資料に「記載なし」「不明」と明示されていても/);
  assert.match(policy, /不足事項の一覧を明示的に求めた場合/);
  assert.match(policy, /新しい判断や情報を加えない末尾/);
  assert.match(policy, /ユーザーが要約を明示的に求めた場合/);
  assert.match(policy, /複数の質問には、それぞれ漏れなく答えて/);
  assert.match(policy, /明示的に比較を求められた対象の情報/);
  assert.equal(request.input.at(-1).content[0].text, c.query);
  assert.ok(result.citationDatabaseValid);
 });
}

test('insufficient evidence retains its narrow response rather than inviting substitutions', async () => {
 const c = fixture.cases.find(c => c.id === 'insufficient-price');
 const {request, result} = await capture(c);
 assert.equal(result.status, 'insufficient');
 assert.deepEqual(result.citations, []);
 const system = request.instructions;
 assert.ok(system.endsWith(ragAnswerPolicy('insufficient')));
 assert.match(system, /別の対象の価格・数値・配列・数式/);
 assert.doesNotMatch(system, /untrustedReferences/);
});

for (const mode of ['no_hits', 'outage', 'no_consent']) {
 test(`${mode} preserves the exact disabled request without presentation rules`, async () => {
  // An empty vector branch or embedding outage can still use keyword hits.
  // Use a genuinely unrelated query to exercise ordinary-chat fallback.
  const c = fixture.cases.find(c => c.id === 'fallback-outage');
  const disabled = await capture({...c, mode: 'disabled'});
  const fallback = await capture({...c, mode});
  assert.deepEqual(fallback.request, disabled.request);
  assert.deepEqual(fallback.result.citations, []);
  assert.doesNotMatch(fallback.request.instructions, /不要な代入式は作らない/);
 });
}

test('embedding outage with surviving keyword evidence still uses grounded presentation rules', async () => {
 const c = fixture.cases.find(c => c.id === 'grounded-number');
 const {request, result} = await capture({...c, mode: 'outage'});
 assert.equal(result.status, 'grounded');
 assert.ok(result.citations.length > 0);
 assert.ok(request.instructions.endsWith(ragAnswerPolicy('grounded')));
});
