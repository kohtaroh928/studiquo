import { referenceSupport } from './answerability.js';
import { coversSubject } from './ranking.js';

export function evidenceNeeds(plan, requirements) {
  return [...plan.coverageGroups.map(subject => `subject:${subject}`),
    ...requirements.targets.flatMap((_, i) => requirements.facets.map(facet => `detail:${i}:${facet}`))];
}
function coverage(reference, plan, requirements) {
  return new Set([
    ...plan.coverageGroups.filter(subject => coversSubject({ text: reference.text }, subject)).map(subject => `subject:${subject}`),
    ...[...referenceSupport(reference.text, requirements)].map(key => `detail:${key}`),
  ]);
}
export function missingEvidence(references, plan, requirements) {
  const found = new Set(references.flatMap(r => [...coverage(r, plan, requirements)]));
  return evidenceNeeds(plan, requirements).filter(key => !found.has(key));
}

// Offsets refer only to the already owner-authorized excerpt. Preserve every
// character, including numbers, negation, case, formulas and table layout.
export function paragraphSpans(text) {
  const spans = [];
  let start = 0;
  for (const match of text.matchAll(/\n[ \t]*\n+/gu)) {
    if (match.index > start) spans.push({ start, end: match.index });
    start = match.index + match[0].length;
  }
  if (start < text.length) spans.push({ start, end: text.length });
  return spans;
}
export function extractEvidence(reference, plan, requirements) {
  const original = paragraphSpans(reference.text);
  // Topic presence cannot certify a mechanism's completeness. Locate only
  // concrete, supported attributes; always retain the original excerpt.
  if (!requirements.facets.length || requirements.freshness || requirements.completeness) return { reference, spans: original };
  // Locate answer-bearing original spans, but preserve ALL surrounding prose.
  // Lexical support cannot establish that a distant qualifier is dispensable
  // (e.g. shipping excluded, corporate-only, or an implicit referent).
  const spans = original.filter(span =>
    referenceSupport(reference.text.slice(span.start, span.end), requirements).size);
  if (!spans.length) return { reference, spans: original };
  return { reference: { ...reference, evidenceSpans: spans }, spans };
}
function paragraphs(text) {
  return paragraphSpans(text).map(span => text.slice(span.start, span.end));
}
function duplicate(candidate, previous) {
  // Keep independent sources and meaningful paragraph order. Do not normalize
  // formulas or treat lexical similarity as duplicate factual evidence.
  if (candidate.citation.sourceId !== previous.citation.sourceId) return false;
  const a = paragraphs(candidate.text), b = paragraphs(previous.text);
  return a.length > 0 && a.length === b.length && a.every((paragraph, i) => paragraph === b[i]);
}
export function selectEvidence(references, plan, requirements, limit = 5, charBudget = 24000, baselineReferences = references) {
  const rows = references.map(r => extractEvidence(r, plan, requirements).reference);
  const selected = [], needs = new Set(evidenceNeeds(plan, requirements));
  let used = 0;
  const add = row => {
    if (selected.includes(row) || selected.length >= limit || used + row.text.length > charBudget) return false;
    if (selected.some(previous => duplicate(row, previous))) return false;
    selected.push(row); used += row.text.length;
    for (const key of coverage(row, plan, requirements)) needs.delete(key);
    return true;
  };
  // Reserve missing information before optional novel passages fill Top5.
  for (const need of [...needs]) {
    if (!needs.has(need)) continue;
    const row = rows.find(r => coverage(r, plan, requirements).has(need) &&
      r.text.length + used <= charBudget && !selected.some(previous => duplicate(r, previous)));
    if (row) add(row);
  }
  for (const row of rows) add(row);
  // No reduction may lose information that the legacy bounded selection had.
  const baseline = [];
  let baselineSize = 0;
  for (const reference of baselineReferences) {
    if (baseline.length >= limit) break;
    if (baselineSize + reference.text.length > charBudget) continue;
    baseline.push(reference); baselineSize += reference.text.length;
  }
  const before = new Set(baseline.flatMap(r => [...coverage(r, plan, requirements)]));
  const after = new Set(selected.flatMap(r => [...coverage(r, plan, requirements)]));
  if ([...before].some(key => !after.has(key))) return baseline;
  return selected;
}
