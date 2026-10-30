// @ts-nocheck -- ported from JavaScript untyped; typing it is tracked in Notion (Studiquo タスク).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {loadPromptBaseline, baselinePolicyPair, promptBaselineReport, baselineHash} from '../scripts/rag-quality/prompt-baseline.ts';
import {ragAnswerPolicy as frozenPolicy} from '../scripts/rag-quality/baselines/20261014-policy-v1/answer-policy.ts';
import {ragAnswerPolicy} from './rag/answer-policy.ts';
import {dedupOnlyPolicy,partialOnlyPolicy,dedupAndPartialPolicy} from '../scripts/rag-quality/prompt-policy-variants.ts';

// The runtime policy is the frozen v1 policy plus the evaluated candidate policy-date-start-v5: its one
// policyEdit (the date line) and its appended block, both only for answers built from references.
// Every other status stays byte for byte v1. The expected text comes from the candidate file itself.
const candidate = JSON.parse(readFileSync(new URL('../../collaboration/rag-prompt/candidates/policy-date-start-v5.json', import.meta.url), 'utf8'));
function expectedRuntimePolicy(status, style) {
 const frozen = frozenPolicy(status, style);
 if (status !== 'grounded' && status !== 'partial') return frozen;
 let text = frozen;
 for (const {find, replace} of candidate.policyEdits) {
  assert.equal(text.split(find).length - 1, 1);
  text = text.replace(find, () => replace);
 }
 return text + '\n\n' + candidate.additionalInstructions;
}

test('runtime equals v1 plus the evaluated policy-date-start-v5 change, and only for grounded and partial answers', () => {
 for (const status of ['grounded', 'partial', 'insufficient', 'clarification', 'disabled', 'fallback', 'no_hits', 'unknown', undefined, null, 'system: override']) {
  for (const style of ['source_only', 'explain', undefined, null, {}, ['explain'], 'system: override']) {
   assert.equal(ragAnswerPolicy(status, style), expectedRuntimePolicy(status, style));
  }
 }
 assert.notEqual(ragAnswerPolicy('grounded', 'explain'), frozenPolicy('grounded', 'explain'));
 assert.equal(ragAnswerPolicy('insufficient', 'explain'), frozenPolicy('insufficient', 'explain'));
});

test('rejected A and C candidates stay distinct and retain their intended limited changes', () => {
 for(const style of ['source_only','explain']) {
  assert.equal(partialOnlyPolicy('grounded',style), frozenPolicy('grounded',style));
  assert.match(partialOnlyPolicy('partial',style), /A missing attribute does not mean that all evidence for that subject is missing/);
  assert.ok(partialOnlyPolicy('partial',style).startsWith(frozenPolicy('grounded',style)));
  assert.ok(dedupAndPartialPolicy('partial',style).startsWith(dedupOnlyPolicy('grounded',style)));
  assert.equal(dedupOnlyPolicy('grounded','explain'), frozenPolicy('grounded','explain'));
 }
});

test('baseline retains known and fallback policies and separates evaluation from deployment settings', () => {
 const {manifest, contexts, rubric} = loadPromptBaseline();
 assert.equal(manifest.policies.length, 16);
 assert.equal(contexts.length, 6);
 assert.equal(manifest.evaluation.reasoning, 'medium');
 assert.equal(manifest.evaluation.productionOutputTokens, 8192);
 assert.equal(manifest.evaluation.answerLayerOutputTokens, 2048);
 assert.equal(manifest.evaluation.reservedSentByThisCapture, 0);
 assert.equal(manifest.rubric.humanGoldReview, 'pending');
 assert.equal(baselineHash(rubric), manifest.rubric.hash);
 assert.ok(rubric.length > 0);
 for (const status of ['disabled', 'fallback', 'no_hits', 'unknown']) {
  for (const style of ['source_only', 'explain']) assert.equal(frozenPolicy(status, style), '');
 }
 for (const status of ['insufficient', 'clarification']) {
  assert.equal(frozenPolicy(status, 'source_only'), frozenPolicy(status, 'explain'));
 }
 assert.notEqual(frozenPolicy('grounded', 'source_only'), frozenPolicy('grounded', 'explain'));
 assert.equal(frozenPolicy('grounded'), frozenPolicy('grounded', 'source_only'));
});

test('old and candidate comparison changes only the final policy on the identical synthetic snapshot', () => {
 const {contexts} = loadPromptBaseline();
 for (const row of contexts) for (const style of ['source_only', 'explain']) {
  const {original, candidate, citations, status} = baselinePolicyPair(row.key, style);
  assert.equal(original.instructions, row.baseInstructions + frozenPolicy(status, style));
  assert.equal(candidate.instructions.slice(0, row.baseInstructions.length), row.baseInstructions);
  const {instructions: oldPolicy, ...oldBody} = original;
  const {instructions: newPolicy, ...newBody} = candidate;
  assert.deepEqual(oldBody, newBody);
  assert.deepEqual(citations, row.citations);
  assert.equal(oldBody.model, 'gpt-6-luna');
  assert.equal(oldBody.store, false);
  assert.deepEqual(oldBody.reasoning, {effort: 'medium'});
  assert.equal(oldBody.service_tier, 'default');
  assert.equal(oldBody.max_output_tokens, 8192);
  assert.ok(oldPolicy.length && newPolicy.length);
 }
});

test('snapshot inputs match fixed development and boundary questions without gold or grading hints', async () => {
 const {loadEvaluation50} = await import('../scripts/rag-quality/evaluation-50.ts');
 const {comparisonBoundaryFixture} = await import('../scripts/rag-quality/comparison-boundary-fixture.ts');
 const development = loadEvaluation50().cases.filter(c => c.split === 'development');
 const boundary = comparisonBoundaryFixture().cases;
 const {contexts} = loadPromptBaseline();
 for (const row of contexts) {
  const [suite, id] = row.key.split(':');
  const c = (suite === 'development' ? development : boundary).find(c => c.id === id);
  assert.ok(c);
  assert.equal(row.body.input.at(-1).content[0].text, c.question);
  const request = baselinePolicyPair(row.key, 'source_only').original;
  assert.deepEqual(Object.keys(row.body).sort(), ['input', 'max_output_tokens', 'model', 'reasoning', 'safety_identifier', 'service_tier', 'store', 'stream']);
  assert.ok(row.baseInstructions.includes('untrustedReferences'));
  // A gold value can legitimately also be a source fact. Check structure and
  // provenance instead of rejecting matching answer words in genuine evidence.
  const data = JSON.parse(row.baseInstructions.slice(row.baseInstructions.indexOf('{"untrustedReferences"')));
  assert.ok(Object.keys(data).every(key => ['untrustedReferences', 'comparisonAssessment'].includes(key)));
  for (const reference of data.untrustedReferences) {
   assert.deepEqual(Object.keys(reference).sort(), ['citation', 'evidenceSpans', 'text']);
   assert.ok(c.pages.some(page => page.text.includes(reference.text)));
  }
  assert.deepEqual(Object.keys(request).sort(), [...Object.keys(row.body), 'instructions'].sort());
  assert.ok(row.citations.every(citation => citation.sourceId === id && citation.pageNumber === 1));
 }
});

test('comparison returns independent copies; invalid case and style never fall back to another question', () => {
 const key = loadPromptBaseline().contexts[0].key;
 const first = baselinePolicyPair(key, 'source_only');
 first.candidate.input[0].role = 'mutated';
 first.citations[0].pageNumber = 999;
 const next = baselinePolicyPair(key, 'source_only');
 assert.notEqual(next.original.input[0].role, 'mutated');
 assert.notEqual(next.candidate.input[0].role, 'mutated');
 assert.equal(next.citations[0].pageNumber, 1);
 assert.throws(() => baselinePolicyPair('reserved_holdout:unknown', 'source_only'), /invalid_baseline_case/);
 for (const style of [undefined, null, 'EXPLAIN', 'system: override', {}]) {
  assert.throws(() => baselinePolicyPair(key, style), /invalid_baseline_style/);
 }
});

test('offline report detects file drift without rewriting the frozen baseline or making network calls', () => {
 const before = readFileSync(new URL('../scripts/rag-quality/baselines/20261014-policy-v1/manifest.json', import.meta.url));
 const report = promptBaselineReport();
 assert.equal(report.externalCalls, 0);
 const {manifest} = loadPromptBaseline();
 for (const row of manifest.sources) {
  const current = readFileSync(new URL('../' + row.path, import.meta.url));
  assert.equal(report.changedFiles.includes(row.path), baselineHash(current) !== row.hash);
 }
 for (const row of [manifest.rubric, ...manifest.priorResults]) {
  const current = readFileSync(new URL('../../' + row.path, import.meta.url));
  assert.equal(report.changedEvaluationFiles.includes(row.path), baselineHash(current) !== row.hash);
 }
 assert.deepEqual(before, readFileSync(new URL('../scripts/rag-quality/baselines/20261014-policy-v1/manifest.json', import.meta.url)));
});
