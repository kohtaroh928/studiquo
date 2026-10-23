// Evaluation-only intermediate policy; never imported by Worker production code.
import {ragAnswerPolicy as v1} from './baselines/20261014-policy-v1/answer-policy.ts';
const redundant = 'Do not add general-knowledge definitions, background, analogies or invented examples in source-only mode, even if labeled as supplemental. Requests for beginner explanations do not override this mode. State that a requested definition is not confirmed in the retrieved excerpts when necessary. ';

export function dedupOnlyPolicy(status: any, style: any) {
 const original = v1(status, style);
 if (['grounded', 'partial'].includes(status) && style !== 'explain') {
  if (original.split(redundant).length !== 2) throw Error('invalid_dedup_baseline');
  return original.replace(redundant, '');
 }
 return original;
}

// Rejected candidate C stays reproducible after production was restored to v1.
function partialPrecision(base: any, status: any) {
 if(status !== 'partial') return base;
 const before = 'Evidence for at least one requested comparison subject is missing.';
 const after = 'Some requested information is unsupported in the retrieved excerpts. Identify which attributes are supported or missing for each comparison subject. A missing attribute does not mean that all evidence for that subject is missing.';
 const beforeJA = '比較対象のうち情報が不足するものを明示し、確認できる部分だけ説明してください。';
 const afterJA = '比較対象ごとに、どの項目が確認でき、どの項目が不足しているかを明示し、確認できる部分は説明してください。一つの項目が不足することを、その対象の情報全体がないという意味に広げないでください。';
 if(base.split(before).length !== 2 || base.split(beforeJA).length !== 2) throw Error('invalid_partial_baseline');
 return base.replace(before, after).replace(beforeJA, afterJA);
}

export const partialOnlyPolicy = (status: any, style: any) => partialPrecision(v1(status, style), status);
export const dedupAndPartialPolicy = (status: any, style: any) => partialPrecision(dedupOnlyPolicy(status, style), status);
