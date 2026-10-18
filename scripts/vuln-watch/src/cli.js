#!/usr/bin/env node
// 使い方:
//   node src/cli.js inventory [--swift-resolved <path>]   資産台帳(inventory.json)を作り直す
//   node src/cli.js scan [--offline] [--no-nvd] [--out <dir>]   収集→照合→採点→レポート
// 終了コード: 0=完了 / 2=取得に失敗したデータ源があり結果が不完全

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { buildInventory } from './inventory.js';
import { createClient } from './http.js';
import { queryOsv, osvFindings, assetKey } from './osv.js';
import { queryNvd } from './nvd.js';
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
  const ranked = rank(merged, { assetsByKey, kev, epss });
  const md = renderReport({ ranked, inventory: items, unmatchable, warnings, sourceErrors, generatedAt: new Date().toISOString() });

  const outDir = typeof args.out === 'string' ? resolve(args.out) : `${toolDir}/out`;
  mkdirSync(outDir, { recursive: true });
  writeFileSync(`${outDir}/latest.md`, md);
  writeFileSync(`${outDir}/latest.json`, JSON.stringify({ ranked, sourceErrors }, null, 2));
  console.log(md.split('\n').slice(0, 8).join('\n'));
  console.log(`\nレポート: ${outDir}/latest.md`);
  return sourceErrors.length ? 2 : 0;
}

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
try {
  if (cmd === 'inventory') cmdInventory(args);
  else if (cmd === 'scan') process.exitCode = await cmdScan(args);
  else {
    console.error('使い方: cli.js inventory | scan [--offline] [--no-nvd] [--out dir] [--swift-resolved path]');
    process.exitCode = 1;
  }
} catch (e) {
  console.error(`失敗: ${e.message}`);
  process.exitCode = 1;
}
