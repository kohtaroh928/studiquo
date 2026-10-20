// 資産台帳: package-lock.json と Package.resolved から、監視対象の一覧を作る。
// exposure: server=Workerに入って公開側で動く / app=iPadアプリに同梱 / tooling=開発・ビルド用のみ

import { readFileSync, existsSync } from 'node:fs';
import type { Asset, ManualAssets, NpmLock, SwiftPin, SwiftResolved } from './types.ts';

/** OSV(SwiftURL)のパッケージ名は「github.com/owner/repo」。スキームと.gitは付けない。 */
export function swiftUrlName(location: string) {
  return String(location)
    .replace(/^[a-z+]+:\/\//i, '')
    .replace(/^git@([^:]+):/, '$1/')
    .replace(/\.git$/, '')
    .replace(/\/$/, '');
}

export function parseNpmLock(lock: NpmLock, pkgJson: { dependencies?: object; devDependencies?: object } = {}): Asset[] {
  const direct = new Set([
    ...Object.keys(pkgJson.dependencies ?? {}),
    ...Object.keys(pkgJson.devDependencies ?? {}),
  ]);
  const items: Asset[] = [];
  for (const [path, meta] of Object.entries(lock.packages ?? {})) {
    if (!path.includes('node_modules/')) continue; // ルート自身は除く
    const name = path.slice(path.lastIndexOf('node_modules/') + 'node_modules/'.length);
    if (!meta.version || meta.link) continue;
    items.push({
      ecosystem: 'npm',
      name,
      version: meta.version,
      direct: direct.has(name) && path === `node_modules/${name}`,
      exposure: meta.dev || meta.devOptional ? 'tooling' : 'server',
    });
  }
  return items;
}

export function parseSwiftResolved(resolved: SwiftResolved): Asset[] {
  const pins = resolved.pins ?? resolved.object?.pins ?? [];
  return pins.map((p: SwiftPin) => {
    const location = p.location ?? p.repositoryURL ?? '';
    const identity = p.identity ?? String(p.package ?? '').toLowerCase();
    return {
      ecosystem: 'SwiftURL',
      name: swiftUrlName(location),
      identity,
      version: p.state?.version ?? null,
      revision: p.state?.revision ?? null,
      exposure: 'app',
    };
  });
}

/** 手書き補足(assets.manual.json)を重ねる。キーは「ecosystem:name」または「SwiftURL:identity」。 */
export function applyManual(items: Asset[], manual: ManualAssets): Asset[] {
  return items.map((it) => {
    const hint = manual.assets?.[`${it.ecosystem}:${it.name}`] ?? manual.assets?.[`${it.ecosystem}:${it.identity}`] ?? {};
    return {
      ...it,
      exposure: hint.exposure ?? it.exposure,
      sensitive: hint.sensitive ?? false,
      usage: hint.usage ?? null,
      nvd: hint.nvd ?? null,
    };
  });
}

function key(it: Asset) {
  return `${it.ecosystem}:${it.name}@${it.version ?? it.revision}`;
}

export function dedupe(items: Asset[]): Asset[] {
  const seen = new Map<string, Asset>();
  for (const it of items) {
    const k = key(it);
    const prev = seen.get(k);
    // 同じ版が runtime と dev の両方にあるなら runtime を優先(危険側)
    if (!prev || (prev.exposure === 'tooling' && it.exposure !== 'tooling')) seen.set(k, { ...prev, ...it });
  }
  return [...seen.values()].sort((a, b) => key(a).localeCompare(key(b)));
}

const readJson = (p: string) => JSON.parse(readFileSync(p, 'utf8'));

/**
 * @param {{npmDir:string, swiftResolved:string|null, manualPath:string, previous?:object}} o
 * Package.resolved はgit管理外(xcodeprojが無視されるため)。見つからなければ前回の台帳のSwift分を引き継ぐ。
 */
export function buildInventory({ npmDir, swiftResolved, manualPath, previous = null }: { npmDir: string; swiftResolved: string | null; manualPath: string; previous?: { items?: Asset[] } | null }) {
  const warnings: string[] = [];
  const manual = existsSync(manualPath) ? readJson(manualPath) : {};
  let items = parseNpmLock(readJson(`${npmDir}/package-lock.json`), readJson(`${npmDir}/package.json`));

  if (swiftResolved && existsSync(swiftResolved)) {
    items = items.concat(parseSwiftResolved(readJson(swiftResolved)));
  } else {
    const carried = (previous?.items ?? []).filter((i: { ecosystem: string; }) => i.ecosystem === 'SwiftURL');
    warnings.push(
      carried.length
        ? `Package.resolved が見つからないため、前回の台帳のSwift分(${carried.length}件)を引き継ぎました。`
        : 'Package.resolved が見つからず、Swift分は空です(--swift-resolved で指定してください)。',
    );
    items = items.concat(carried);
  }
  return { items: dedupe(applyManual(items, manual)), warnings };
}
