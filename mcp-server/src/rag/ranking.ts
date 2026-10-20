// Rank fusion avoids using model scores as calibrated answer probabilities.
// Conservative initial RRF weight; quality evaluations must validate it before rollout.
export function fuseRanks(candidates: any, response: any, rrfWeight = 3) {
  if (!Array.isArray(response) || response.length !== candidates.length) return candidates;
  const seen = new Set();
  for (const row of response) {
    if (!Number.isInteger(row?.id) || row.id < 0 || row.id >= candidates.length ||
        !Number.isFinite(row.score) || seen.has(row.id)) return candidates;
    seen.add(row.id);
  }
  const ranked = [...response].sort((a, b) => b.score - a.score || a.id - b.id);
  const positions = new Map(ranked.map((r, i) => [r.id, i]));
  return candidates.map((c: any, i: any) => ({ ...c,
    selectionScore: rrfWeight / (61 + i) + 1 / (61 + positions.get(i)!),
  })).sort((a: any, b: any) => b.selectionScore - a.selectionScore || b.rrf - a.rrf || a.chunk_id.localeCompare(b.chunk_id));
}

const pageKey = (c: any) => `${c.source_id}:${c.page_number}`;
export function coversSubject(candidate: any, subject: any) {
  const normalize = (s: any) => String(s ?? '').normalize('NFKC').replace(/\s+/gu, '').toLowerCase();
  const target = normalize(subject);
  if (!target) return false;
  if (normalize(candidate.text).includes(target)) return true;
  const segments = [...new Set(target.split('の'))];
  if (segments.length < 2 || segments.length > 4 || segments.some(s => s.length < 2 && !/^[\p{Script=Han}]$/u.test(s))) return false;
  // Headings may put the core before its qualifier. Require every segment in
  // one short body span, never across sentences/paragraphs or via metadata.
  return String(candidate.text ?? '').normalize('NFKC').split(/\n\s*\n|[。！？!?]/u).some(raw => {
    const span = normalize(raw);
    for (const segment of segments) {
      let at = span.indexOf(segment);
      while (at >= 0) {
        const window = span.slice(at, at + 160);
        if (segments.every(s => window.includes(s))) return true;
        at = span.indexOf(segment, at + 1);
      }
    }
    return false;
  });
}
// Reserve relevant subject representatives BEFORE Top15 as well as before Top5.
// Source/page diversity keeps overlapping children from consuming all context slots.
export function selectDiverse(candidates: any, groups: any = [], limit = 5, eligible: any = () => true, fillDuplicates = false) {
  const selected: any[] = [], pages = new Set();
  const add = (c: any) => { if (c && selected.length < limit && !pages.has(pageKey(c))) { selected.push(c); pages.add(pageKey(c)); } };
  for (const subject of groups) add(candidates.find((c: any) => eligible(c) && coversSubject(c, subject)));
  for (const candidate of candidates) if (eligible(candidate)) add(candidate);
  if (fillDuplicates) {
    const ids = new Set(selected.map(c => c.chunk_id));
    for (const candidate of candidates) if (selected.length < limit && eligible(candidate) && !ids.has(candidate.chunk_id)) {
      selected.push(candidate); ids.add(candidate.chunk_id);
    }
  }
  return selected;
}
