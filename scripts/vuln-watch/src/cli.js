#!/usr/bin/env node
// 使い方:
//   node src/cli.js inventory [--swift-resolved <path>]   資産台帳(inventory.json)を作り直す
//   node src/cli.js scan [--offline] [--no-nvd] [--no-jvn] [--out <dir>]   収集→照合→採点→機械判定のレポート
//   node src/cli.js triage-pack [--out <dir>]                  判定に回す指摘を triage-input.json に出す(scanも出す)
//   node src/cli.js triage-apply [--verdicts <file>] [--out <dir>]   エージェントの返信(ファイルか標準入力)を検証して反映
// 終了コード: 0=完了 / 2=取得に失敗したデータ源があり結果が不完全 / 3=LLM判定が反映されなかった / 4=その両方

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { buildInventory } from './inventory.js';
import { createClient } from './http.js';
import { queryOsv, osvFindings, assetKey } from './osv.js';
import { queryNvd } from './nvd.js';
import { queryJvn } from './jvn.js';
import { applyTriage, buildTriageInput, findingId } from './triage.js';
import { loadState, markNew, saveState } from './state.js';
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
  const statePath = `${toolDir}/state.json`;
  const state = loadState(statePath);
  const generatedAt = new Date().toISOString();
  const ranked = markNew(
    rank(merged, { assetsByKey, kev, epss }).map((f) => ({ ...f, id: findingId(f) })),
    state,
  );

  const outDir = outDirOf(args);
  mkdirSync(outDir, { recursive: true });
  const run = { schema: 2, generatedAt, inventory: items, unmatchable, warnings, sourceErrors, ranked };
  writeFileSync(`${outDir}/latest.json`, JSON.stringify(run, null, 2));
  writeFileSync(`${outDir}/triage-input.json`, JSON.stringify(buildTriageInput(ranked, { generatedAt }), null, 2));
  const md = renderReport({ ranked, inventory: items, unmatchable, warnings, sourceErrors, generatedAt });
  writeFileSync(`${outDir}/latest.md`, md);
  if (!sourceErrors.length) saveState(statePath, ranked, generatedAt, state);

  console.log(md.split('\n').slice(0, 8).join('\n'));
  console.log(`\nレポート: ${outDir}/latest.md(機械判定のみ)\n判定の入力: ${outDir}/triage-input.json`);
  return sourceErrors.length ? 2 : 0;
}

function outDirOf(args) {
  return typeof args.out === 'string' ? resolve(args.out) : `${toolDir}/out`;
}

function readRun(outDir) {
  const run = JSON.parse(readFileSync(`${outDir}/latest.json`, 'utf8'));
  const input = JSON.parse(readFileSync(`${outDir}/triage-input.json`, 'utf8'));
  if (run.generatedAt !== input.generatedAt) throw new Error('latest.json と triage-input.json の生成時刻が違います。scan をやり直してください。');
  return { run, input };
}

function cmdTriagePack(args) {
  const outDir = outDirOf(args);
  const run = JSON.parse(readFileSync(`${outDir}/latest.json`, 'utf8'));
  const input = buildTriageInput(run.ranked, { generatedAt: run.generatedAt });
  writeFileSync(`${outDir}/triage-input.json`, JSON.stringify(input, null, 2));
  console.log(`判定に回す指摘: ${input.items.length}件 → ${outDir}/triage-input.json`);
}

function cmdTriageApply(args) {
  const outDir = outDirOf(args);
  const { run, input } = readRun(outDir);
  const raw = typeof args.verdicts === 'string' ? readFileSync(args.verdicts, 'utf8') : readFileSync(0, 'utf8');
  const result = applyTriage(run.ranked, input, raw, { repoRoot, allowLowering: run.sourceErrors.length === 0 });
  const triage = { status: result.status, accepted: result.accepted, judged: result.judged, total: result.total, rejected: result.rejected };
  const md = renderReport({ ranked: result.ranked, inventory: run.inventory, unmatchable: run.unmatchable, warnings: run.warnings, sourceErrors: run.sourceErrors, generatedAt: run.generatedAt, triage });
  writeFileSync(`${outDir}/latest.md`, md);
  writeFileSync(`${outDir}/triage-result.json`, JSON.stringify({ ...triage, ranked: result.ranked }, null, 2));
  console.log(`LLM判定: ${result.accepted}件を反映 / 採用しなかった ${result.rejected.length}件\nレポート: ${outDir}/latest.md`);
  for (const r of result.rejected) console.warn(`  - ${r.id}: ${r.reason}`);
  const incomplete = run.sourceErrors.length > 0;
  const noVerdict = result.status !== 'applied';
  if (incomplete && noVerdict) return 4;
  if (incomplete) return 2;
  return noVerdict ? 3 : 0;
}

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
try {
  if (cmd === 'inventory') cmdInventory(args);
  else if (cmd === 'scan') process.exitCode = await cmdScan(args);
  else if (cmd === 'triage-pack') cmdTriagePack(args);
  else if (cmd === 'triage-apply') process.exitCode = cmdTriageApply(args);
  else {
    console.error('使い方: cli.js inventory | scan [--offline] [--no-nvd] [--no-jvn] [--out dir] | triage-pack | triage-apply [--verdicts file]');
    process.exitCode = 1;
  }
} catch (e) {
  console.error(`失敗: ${e.message}`);
  process.exitCode = 1;
}
