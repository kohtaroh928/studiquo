// Offline scoring only. Reads saved answers; never calls a model or reads credentials.
// Automatic checks are preliminary string checks. not_detected/review/violation rows must be
// confirmed by a person reading the answer; manual verdicts always override automatic ones.
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

const STYLES = ['source_only', 'explain'];
const MANUAL = ['satisfied', 'omitted', 'incorrect', 'unsupported', 'not_applicable', 'pending'];
const RUBRIC_FILES = {fixed6: './rubric-fixed6.json', extra: './extra-cases/rubric-extra.json'};
export const loadRubric = (name = 'fixed6') => {
  if (!RUBRIC_FILES[name]) throw Error('invalid_rubric_name');
  return JSON.parse(readFileSync(new URL(RUBRIC_FILES[name], import.meta.url), 'utf8'));
};

// Absorb notation differences: full-width, digit commas, LaTeX wrappers, Markdown emphasis, spaces.
export function normalize(text) {
  return text.normalize('NFKC')
    .replace(/\\(?:text|mathrm|textrm|mbox|operatorname)\{([^}]*)\}/g, '$1')
    .replace(/\\[,;:! ]/g, '').replace(/\\[a-zA-Z]+/g, '').replace(/[{}$*`~]/g, '')
    .replace(/(\d),(?=\d{3})/g, '$1').replace(/[ \t　]+/g, '');
}
const find = (text, patterns) => {
  for (const p of patterns) {const m = new RegExp(p, 'u').exec(text); if (m) return m.index;}
  return -1;
};

export function checkItem(item, text, results = {}) {
  if (item.all) return item.all.every(p => find(text, [p]) >= 0) ? 'satisfied' : 'not_detected';
  if (item.any) return find(text, item.any) >= 0 ? 'satisfied' : 'not_detected';
  if (item.forbid) {
    if (find(text, item.forbid) >= 0) return 'violation';
    return item.flag && find(text, item.flag) >= 0 ? 'review' : 'ok';
  }
  if (item.flag) return find(text, item.flag) >= 0 ? 'review' : 'ok';
  if (item.labelBeforeCue) {
    const cue = find(text, item.labelBeforeCue.cue);
    if (cue < 0) return 'ok';
    const label = find(text, item.labelBeforeCue.label);
    return label >= 0 && label < cue ? 'ok' : 'review';
  }
  if (item.before) {
    if (results[item.before.first]?.auto !== 'satisfied') return 'not_applicable';
    const first = find(text, results[item.before.first].patterns);
    const then = find(text, item.before.then);
    return then < 0 || first < then ? 'ok' : 'review';
  }
  throw Error('invalid_rubric_item:' + item.id);
}

function itemsFor(rubric, caseKey, style) {
  const own = rubric.cases[caseKey]?.items;
  if (!own) throw Error('unknown_case:' + caseKey);
  return [...own, ...rubric.common].filter(item => !item.styles || item.styles.includes(style));
}

// answers: {variants: {name: {"caseKey|style": text}}}; manual: {"variant|caseKey|style|itemId": verdict}
export function score(answers, manual = {}, rubric = loadRubric()) {
  for (const [key, verdict] of Object.entries(manual)) {
    if (!MANUAL.includes(verdict)) throw Error('invalid_manual_verdict:' + key);
  }
  const rows = [];
  for (const [variant, byKey] of Object.entries(answers.variants)) {
    for (const [key, raw] of Object.entries(byKey)) {
      const [caseKey, style] = key.split('|');
      if (!STYLES.includes(style) || typeof raw !== 'string') throw Error('invalid_answer_key:' + key);
      const text = normalize(raw), results = {};
      for (const item of itemsFor(rubric, caseKey, style)) {
        const auto = checkItem(item, text, results);
        results[item.id] = {auto, patterns: item.any ?? item.all};
        rows.push({variant, caseKey, style, itemId: item.id, category: item.category, severity: item.severity,
          auto, manual: manual[[variant, caseKey, style, item.id].join('|')] ?? null});
      }
    }
  }
  return {rubricId: rubric.id, rows, summary: summarize(rows), paired: paired(rows)};
}

// Manual verdict first; otherwise the automatic result is provisional.
export const finalStatus = row => row.manual ?? ({satisfied: 'satisfied', ok: 'satisfied', not_applicable: 'not_applicable',
  not_detected: 'pending_omission', violation: 'pending_violation', review: 'pending_review'})[row.auto];

function summarize(rows) {
  const out = {};
  for (const row of rows) {
    const bucket = ((out[row.variant] ??= {})[row.style] ??= {});
    const cat = (bucket[row.category] ??= {});
    const status = finalStatus(row);
    cat[status] = (cat[status] ?? 0) + 1;
  }
  return out;
}

function paired(rows) {
  const variants = [...new Set(rows.map(r => r.variant))];
  const [base, ...others] = variants;
  const index = new Map(rows.map(r => [[r.variant, r.caseKey, r.style, r.itemId].join('|'), r]));
  return others.map(variant => {
    const changes = [];
    for (const row of rows.filter(r => r.variant === base)) {
      const other = index.get([variant, row.caseKey, row.style, row.itemId].join('|'));
      if (!other) continue;
      const a = finalStatus(row), b = finalStatus(other);
      if (a === b) continue;
      const good = s => s === 'satisfied' || s === 'not_applicable';
      changes.push({caseKey: row.caseKey, style: row.style, itemId: row.itemId, category: row.category,
        baseline: a, candidate: b, direction: good(b) && !good(a) ? 'improved' : good(a) && !good(b) ? 'regressed' : 'changed'});
    }
    return {baseline: base, candidate: variant,
      improved: changes.filter(c => c.direction === 'improved').length,
      regressed: changes.filter(c => c.direction === 'regressed').length, changes};
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2), at = args.indexOf('--rubric');
    const rubricName = at < 0 ? 'fixed6' : args.splice(at, 2)[1];
    const [answersPath, manualPath] = args;
    if (!answersPath) throw Error('usage');
    const answers = JSON.parse(readFileSync(answersPath, 'utf8'));
    const manual = manualPath ? JSON.parse(readFileSync(manualPath, 'utf8')) : {};
    const report = score(answers, manual, loadRubric(rubricName));
    // Answer text is never printed; only item ids and statuses.
    console.log(JSON.stringify({rubricId: report.rubricId, summary: report.summary, paired: report.paired,
      needsReview: report.rows.filter(r => !r.manual && !['satisfied', 'ok', 'not_applicable'].includes(r.auto))
        .map(r => [r.variant, r.caseKey, r.style, r.itemId, r.auto].join('|'))}, null, 2));
  } catch (error) {
    console.error('rag_prompt_score_failed: ' + (error.message.split(':')[0] || 'error'));
    process.exitCode = 1;
  }
}
