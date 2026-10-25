// Review metadata only. Never include these criteria in model requests.
import {learningPairs} from './learning-fixture.ts';

export const LEARNING_RUBRIC_VERSION = '2026-10-13-v2';

export function learningReviewChecks(pair: any, style: any) {
 if (!learningPairs.includes(pair) || !['source_only','explain'].includes(style)) {
  throw Error('invalid_learning_rubric');
 }
 const checks = [...pair.manualChecks.common, ...pair.manualChecks[style]];
 if (pair.id === 'learning-density-background' && style === 'explain') {
  const old = '密度の体積あたり質量という意味を補足と表示して説明';
  const index = checks.indexOf(old);
  if (index < 0) throw Error('legacy_rubric_mismatch');
  checks[index] = '資料のρ=m/Vとg/cm³から体積あたり質量という意味を説明できる。直接の言い換えには補足表示を必須としない。未記載の性質・用途・たとえは最初の説明より前に補足と表示し、正しさも確認する';
 }
 if (pair.id === 'learning-partial-devices') {
  checks.push('片側の既知仕様は対象名付きの確認できる情報として述べ、両者の違い・共通点として提示しない');
 }
 return checks;
}
