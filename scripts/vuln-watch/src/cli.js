#!/usr/bin/env node
// 使い方:
//   node src/cli.js inventory [--swift-resolved <path>]   資産台帳(inventory.json)を作り直す
//   node src/cli.js scan [--offline] [--no-nvd] [--no-jvn] [--out <dir>]   収集→照合→採点→機械判定のレポート
//   node src/cli.js triage-pack [--fresh] [--out <dir>]        判定に回す指摘を triage-input.json に出す(scanも出す)。月曜と --fresh はキャッシュを使わない
//   node src/cli.js triage-apply [--verdicts <file> | --no-reply] [--out <dir>]   エージェントの返信(ファイルか標準入力)を検証して反映
//   node src/cli.js cards-plan --existing <file> [--dry-run] [--out <dir>]   Notionカードの操作リスト cards-ops.json を作る
//   node src/cli.js summary [--created n --updated n --commented n --failed n]   固定書式の要約と通知文を出す
// 共通: --state <path> で state.json の場所を変えられる(試験用)
// 終了コード: 0=完了 / 2=取得に失敗したデータ源があり結果が不完全 / 3=LLM判定が反映されなかった / 4=その両方

import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { buildInventory } from './inventory.js';
import { createClient } from './http.js';
import { queryOsv, osvFindings, assetKey } from './osv.js';
import { queryNvd } from './nvd.js';
import { queryJvn } from './jvn.js';
import { applyTriage, buildTriageInput, findingId, parseVerdicts } from './triage.js';
import { gapWarning, isFreshDay, loadState, markNew, saveState, saveVerdicts, selectForJudgement } from './state.js';
import { buildSummary, planCards } from './cards.js';
import { fetchKev, fetchEpss } from './signals.js';
import { mergeFindings, rank } from './score.js';
import { renderReport } from './report.js';

const here = dirname(fileURLToPath(import.meta.url));
const toolDir = resolve(here, '..');
const repoRoot = resolve(toolDir, '../..');
const inventoryPath = `${toolDir}/inventory.json`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const k = argv[i].slice(2);
      args[k] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    } else args._.push(argv[i]);
  }
  return args;
}

/** NVD_API_KEY は環境変数か、リポジトリ外の ~/.config/studiquo/vuln-watch.env から読む。 */
function loadApiKey() {
  if (process.env.NVD_API_KEY) return process.env.NVD_API_KEY;
  const file = `${homedir()}/.config/studiquo/vuln-watch.env`;
  if (!existsSync(file)) return null;
  const m = /^NVD_API_KEY=(.+)$/m.exec(readFileSync(file, 'utf8'));
  return m ? m[1].trim() : null;
}

function findSwiftResolved(explicit) {
  const rel = 'studiquo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved';
  const candidates = [explicit, process.env.VULN_WATCH_SWIFT_RESOLVED, `${repoRoot}/${rel}`].filter((p) => typeof p === 'string');
  return candidates.find((p) => existsSync(p)) ?? null;
}

function cmdInventory(args) {
  const previous = existsSync(inventoryPath) ? JSON.parse(readFileSync(inventoryPath, 'utf8')) : null;
  const { items, warnings } = buildInventory({
    npmDir: `${repoRoot}/mcp-server`,
    swiftResolved: findSwiftResolved(args['swift-resolved']),
    manualPath: `${toolDir}/assets.manual.json`,
    previous,
  });
  // 生成日時は入れない(中身が同じなら差分が出ないようにする)
  writeFileSync(inventoryPath, JSON.stringify({ items }, null, 2) + '\n');
  console.log(`資産台帳を更新しました: ${items.length}件(npm ${items.filter((i) => i.ecosystem === 'npm').length} / Swift ${items.filter((i) => i.ecosystem === 'SwiftURL').length})`);
  for (const w of warnings) console.warn(`注意: ${w}`);
  return { items, warnings };
}

async function cmdScan(args) {
  const { items, warnings } = cmdInventory(args);
  const client = createClient({ cacheDir: `${toolDir}/.cache`, offline: Boolean(args.offline) });
  const sourceErrors = [];
  let findings = [];

  const unmatchable = items.filter((a) => !a.version);
  try {
    const osv = await queryOsv(client, items);
    findings = findings.concat(osvFindings(osv));
  } catch (e) {
    sourceErrors.push(`OSV: ${e.message}`);
  }
  if (args['no-nvd']) sourceErrors.push('NVD: 取得を省略しました(--no-nvd)');
  if (args['no-jvn']) sourceErrors.push('JVN: 取得を省略しました(--no-jvn)');
  if (!args['no-nvd']) {
    try {
      findings = findings.concat(await queryNvd(client, items, { apiKey: loadApiKey() }));
    } catch (e) {
      sourceErrors.push(`NVD: ${e.message}`);
    }
  }

  if (!args['no-jvn']) {
    try {
      findings = findings.concat(await queryJvn(client, items, { onWarning: (w) => sourceErrors.push(w) }));
    } catch (e) {
      sourceErrors.push(`JVN: ${e.message}`);
    }
  }

  const merged = mergeFindings(findings);
  let kev = new Map();
  let epss = new Map();
  try {
    kev = await fetchKev(client);
  } catch (e) {
    sourceErrors.push(`CISA KEV: ${e.message}(KEV掲載による引き上げが効いていません)`);
  }
  try {
    epss = await fetchEpss(client, merged.map((f) => f.cve).filter(Boolean));
  } catch (e) {
    sourceErrors.push(`EPSS: ${e.message}`);
  }

  const assetsByKey = new Map(items.map((a) => [assetKey(a), a]));
  const statePath = statePathOf(args);
  const state = loadState(statePath);
  const now = new Date();
  const generatedAt = now.toISOString();
  const gap = gapWarning(state, now);
  if (gap) warnings.push(gap);
  const ranked = markNew(
    rank(merged, { assetsByKey, kev, epss }).map((f) => ({ ...f, id: findingId(f) })),
    state,
  );

  const outDir = outDirOf(args);
  mkdirSync(outDir, { recursive: true });
  clearStale(outDir, ['triage-result.json', 'cards-existing.json', 'cards-ops.json', 'cards-ops.dry.json', 'summary.txt']);
  const run = { schema: 2, generatedAt, inventory: items, unmatchable, warnings, sourceErrors, ranked };
  writeFileSync(`${outDir}/latest.json`, JSON.stringify(run, null, 2));
  const counts = writeTriageFiles(outDir, ranked, generatedAt, state, now, Boolean(args.fresh) || isFreshDay(now));
  const md = renderReport({ ranked, inventory: items, unmatchable, warnings, sourceErrors, generatedAt });
  writeFileSync(`${outDir}/latest.md`, md);
  if (!sourceErrors.length) saveState(statePath, ranked, generatedAt, state);

  console.log(md.split('\n').slice(0, 8).join('\n'));
  console.log(`\nレポート: ${outDir}/latest.md(機械判定のみ)\n判定に回す指摘: ${counts.pending}件(判定のキャッシュ再利用 ${counts.cached}件 / 候補 ${counts.all}件) → ${outDir}/triage-input.json`);
  return sourceErrors.length ? 2 : 0;
}

function outDirOf(args) {
  return typeof args.out === 'string' ? resolve(args.out) : `${toolDir}/out`;
}

function statePathOf(args) {
  return typeof args.state === 'string' ? resolve(args.state) : `${toolDir}/state.json`;
}

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));

/** 前回の回の成果物を消す。古い返信や古い操作リストが、今回の回で使われないようにする。 */
function clearStale(outDir, names) {
  for (const n of names) rmSync(`${outDir}/${n}`, { force: true });
}

/** 候補の全件(triage-all.json: 検証用)と、エージェントに判定させる分(triage-input.json)を書く。 */
function writeTriageFiles(outDir, ranked, generatedAt, state, now, fresh) {
  clearStale(outDir, ['reply.json']); // 古い返信を、今回の指摘の判定として使わせない
  const all = buildTriageInput(ranked, { generatedAt });
  const { pending, cached } = selectForJudgement(all.items, state, now, { fresh });
  writeFileSync(`${outDir}/triage-all.json`, JSON.stringify(all, null, 2));
  writeFileSync(`${outDir}/triage-input.json`, JSON.stringify({ ...all, items: pending, cachedCount: cached.length, fresh }, null, 2));
  return { all: all.items.length, pending: pending.length, cached: cached.length };
}

function readRun(outDir) {
  const run = readJson(`${outDir}/latest.json`);
  const input = readJson(`${outDir}/triage-input.json`);
  const all = existsSync(`${outDir}/triage-all.json`) ? readJson(`${outDir}/triage-all.json`) : input;
  if (run.generatedAt !== input.generatedAt || run.generatedAt !== all.generatedAt) {
    throw new Error('latest.json と triage-input.json の生成時刻が違います。scan をやり直してください。');
  }
  return { run, input, all };
}

/** 同じ回(generatedAt)の成果物だけを使う。古いファイルは無かったことにする。 */
function readSameRun(path, generatedAt) {
  if (!existsSync(path)) return null;
  const j = readJson(path);
  return j.generatedAt === generatedAt ? j : null;
}

function cmdTriagePack(args) {
  const outDir = outDirOf(args);
  const run = readJson(`${outDir}/latest.json`);
  const now = new Date();
  const c = writeTriageFiles(outDir, run.ranked, run.generatedAt, loadState(statePathOf(args)), now, Boolean(args.fresh) || isFreshDay(now));
  console.log(`判定に回す指摘: ${c.pending}件(キャッシュ再利用 ${c.cached}件 / 候補 ${c.all}件) → ${outDir}/triage-input.json`);
}

function cmdTriageApply(args) {
  const outDir = outDirOf(args);
  const { run, input, all } = readRun(outDir);
  const statePath = statePathOf(args);
  const state = loadState(statePath);
  const now = new Date();

  const pendingIds = new Set(input.items.map((i) => i.id));
  const cachedVerdicts = all.items
    .filter((i) => !pendingIds.has(i.id) && state.verdicts[i.id]?.hash === i.hash)
    .map((i) => ({ id: i.id, ...state.verdicts[i.id].verdict }));

  const raw = args['no-reply'] ? '' : typeof args.verdicts === 'string' ? readFileSync(args.verdicts, 'utf8') : readFileSync(0, 'utf8');
  let replyIds = new Set();
  try {
    replyIds = new Set(parseVerdicts(raw).map((v) => v?.id));
  } catch {
    // 読めない返信は applyTriage が「採用しなかった判定」として記録する
  }

  const result = applyTriage(run.ranked, all, raw, { repoRoot, allowLowering: run.sourceErrors.length === 0, cachedVerdicts, replyAllowedIds: pendingIds });
  const decided = new Set(result.acceptedVerdicts.map((e) => e.id));
  const unjudged = all.items.filter((i) => !decided.has(i.id)).length; // 判定が付かなかった指摘(エージェントに回したのに返らなかったもの、検証で落ちたキャッシュを含む)
  const cacheUsed = cachedVerdicts.filter((c) => decided.has(c.id)).length;
  const cacheBad = cachedVerdicts.filter((c) => !decided.has(c.id)).map((c) => c.id);
  const triage = { status: result.status, accepted: result.accepted, judged: result.judged, total: result.total, rejected: result.rejected, redactions: result.redactions, unjudged, cached: cacheUsed };

  const hashOf = new Map(all.items.map((i) => [i.id, i.hash]));
  const fresh = result.acceptedVerdicts.filter((e) => replyIds.has(e.id)).map((e) => ({ id: e.id, hash: hashOf.get(e.id), verdict: e.verdict }));
  saveVerdicts(statePath, state, fresh, all.items.map((i) => i.id), now.toISOString(), cacheBad);

  const md = renderReport({ ranked: result.ranked, inventory: run.inventory, unmatchable: run.unmatchable, warnings: run.warnings, sourceErrors: run.sourceErrors, generatedAt: run.generatedAt, triage });
  writeFileSync(`${outDir}/latest.md`, md);
  writeFileSync(`${outDir}/triage-result.json`, JSON.stringify({ ...triage, generatedAt: run.generatedAt, ranked: result.ranked }, null, 2));
  console.log(`LLM判定: ${result.accepted}件を反映(うちキャッシュ ${cacheUsed}件) / 採用しなかった ${result.rejected.length}件 / 判定が付かなかった ${unjudged}件\nレポート: ${outDir}/latest.md`);
  for (const r of result.rejected) console.warn(`  - ${r.id}: ${r.reason}`);
  const incomplete = run.sourceErrors.length > 0;
  const noVerdict = result.status === 'none' || unjudged > 0;
  if (incomplete && noVerdict) return 4;
  if (incomplete) return 2;
  return noVerdict ? 3 : 0;
}

function cmdCardsPlan(args) {
  const outDir = outDirOf(args);
  clearStale(outDir, ['cards-ops.json']); // 失敗しても、前回の操作リストが残って実行されないように、最初に消す
  const run = readJson(`${outDir}/latest.json`);
  const result = readSameRun(`${outDir}/triage-result.json`, run.generatedAt);
  // 既存カードを取得できていないまま計画すると、重複を作ってしまう
  if (typeof args.existing !== 'string' && !args['dry-run']) throw new Error('--existing(Notionから取得した既存カード)が必要です。試すだけなら --dry-run を付けてください。');
  const existing = typeof args.existing === 'string' ? readJson(args.existing) : [];
  const plan = planCards({ ranked: result?.ranked ?? run.ranked, existing, today: new Date().toLocaleDateString('sv-SE'), incomplete: run.sourceErrors.length > 0 });
  // --dry-run は既存カードを知らずに計画するため、実行用の cards-ops.json には書かない
  const dryRun = Boolean(args['dry-run']) && typeof args.existing !== 'string';
  const file = dryRun ? 'cards-ops.dry.json' : 'cards-ops.json';
  writeFileSync(`${outDir}/${file}`, JSON.stringify({ generatedAt: run.generatedAt, dryRun, incomplete: run.sourceErrors.length > 0, triageApplied: Boolean(result), ...plan }, null, 2));
  console.log(`カード計画: 作成 ${plan.counts.create} / 更新 ${plan.counts.update} / コメント ${plan.counts.comment} / 見送り ${plan.skipped.length} → ${outDir}/${file}${dryRun ? '(試験用。実行しない)' : ''}`);
  for (const s of plan.skipped) console.warn(`  見送り: ${s.target}: ${s.reason}`);
  for (const n of plan.notes) console.warn(`  注意: ${n}`);
}

function cmdSummary(args) {
  const outDir = outDirOf(args);
  const run = readJson(`${outDir}/latest.json`);
  const result = readSameRun(`${outDir}/triage-result.json`, run.generatedAt);
  const plan = readSameRun(`${outDir}/cards-ops.json`, run.generatedAt);
  const num = (k) => (typeof args[k] === 'string' && /^\d{1,3}$/.test(args[k]) ? Number(args[k]) : undefined);
  const { text, notify } = buildSummary({
    ranked: result?.ranked ?? run.ranked,
    run,
    triage: result,
    plan,
    executed: { created: num('created'), updated: num('updated'), commented: num('commented'), failed: num('failed') },
    today: new Date().toLocaleDateString('sv-SE'),
    outDir,
  });
  writeFileSync(`${outDir}/summary.txt`, text + '\n');
  console.log(text);
  console.log(notify ? `NOTIFY=${notify}` : 'NOTIFY=なし');
}

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
try {
  if (cmd === 'inventory') cmdInventory(args);
  else if (cmd === 'scan') process.exitCode = await cmdScan(args);
  else if (cmd === 'triage-pack') cmdTriagePack(args);
  else if (cmd === 'triage-apply') process.exitCode = cmdTriageApply(args);
  else if (cmd === 'cards-plan') cmdCardsPlan(args);
  else if (cmd === 'summary') cmdSummary(args);
  else {
    console.error('使い方: cli.js inventory | scan [--offline] [--no-nvd] [--no-jvn] [--out dir] | triage-pack | triage-apply [--verdicts file | --no-reply] | cards-plan --existing file | summary');
    process.exitCode = 1;
  }
} catch (e) {
  console.error(`失敗: ${e.message}`);
  process.exitCode = 1;
}
