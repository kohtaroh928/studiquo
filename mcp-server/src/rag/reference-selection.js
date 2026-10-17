import { coversSubject } from './ranking.js';
import { relevanceEvidence } from './relevance.js';

// Narrow shared-subject form only. Do not infer implied qualifiers or rewrite
// the query: source text need not repeat the user's attribute labels.
export function compoundReferenceSubject(query) {
  const text = String(query).normalize('NFKC').trim();
  const match = /^([^?？。\n、,;；]{2,80})の(入力|出力|材料|生成物|働き|構造|原因|結果|条件|仕組み|しくみ)と(入力|出力|材料|生成物|働き|構造|原因|結果|条件|仕組み|しくみ)(?:の(?:仕組み|しくみ))?(?:(?:を|について)(?:説明して|説明してください|教えて|教えてください)|は(?:何|なに|何ですか)?|とは)?[?？。\s]*$/u.exec(text);
  if (!match || match[2] === match[3] || /と(?!は)|および|かつ|や|または|及び|[・&/]|\band\b/iu.test(match[1])) return '';
  return match[1];
}

export function referenceEligibility(query, plan) {
  const subjects = plan.coverageGroups.length ? plan.coverageGroups : [compoundReferenceSubject(query)].filter(Boolean);
  // Preserve existing selection for unparsed questions. A detected subject
  // must be present in retrieved body, never solely in the source title.
  return candidate => !subjects.length || subjects.some(subject =>
    coversSubject(candidate, subject) && relevanceEvidence(candidate, subject).accepted);
}

// Opt in only for a short, single definition/mechanism question. Rank is not
// confidence: multi-part requests and distributed detail evidence keep Top5.
export function simpleReferenceQuestion(query, plan, requirements) {
  const text = String(query).normalize('NFKC').trim();
  if (text.length > 100 || plan.multi || plan.coverageGroups.length || requirements.facets.length) return false;
  if (/比較|比べ|違い|共通|それぞれ|および|かつ|及び|または|など|一覧|列挙|まとめ|要約|全体|全て|すべて|全部|特徴|原因|対策|手順|流れ|詳しく|詳細|具体例|例えば|[、,;；・&/]|\band\b|と(?!は)|や/iu.test(text)) return false;
  return /^[^?？。\n]+(?:とは|の意味|の定義|のしくみ|の仕組み|しくみ|仕組み)(?:は|を)?(?:何|なに|説明して|教えて|説明してください|教えてください|ですか)?[?？。\s]*$/u.test(text);
}

export function singleRankedReference(candidates, response, query, plan, requirements) {
  if (!simpleReferenceQuestion(query, plan, requirements) || !Array.isArray(response) || response.length !== candidates.length || !response.length) return null;
  const seen = new Set();
  for (const row of response) {
    if (!Number.isInteger(row?.id) || row.id < 0 || row.id >= candidates.length || !Number.isFinite(row.score) || seen.has(row.id)) return null;
    seen.add(row.id);
  }
  const ranked = [...response].sort((a, b) => b.score - a.score);
  if (ranked.length > 1 && ranked[0].score === ranked[1].score) return null;
  return [candidates[ranked[0].id]];
}
