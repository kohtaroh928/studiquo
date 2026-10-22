// OSV.dev: パッケージ名+版で直接引く。版範囲の判定はOSV側が行うので、ここでは「確定」として扱う。

import { cvss3BaseScore, severityLabelToScore } from './cvss.ts';
import type { HttpClient } from './http.ts';
import type { Asset, Finding, OsvVuln } from './types.ts';

const BASE = 'https://api.osv.dev/v1';

/** querybatch / query の1件分の応答。 */
interface OsvQueryResult { vulns?: { id: string }[]; next_page_token?: string }

export function assetKey(a: Pick<Asset, 'ecosystem' | 'name' | 'version'>) {
  return `${a.ecosystem}:${a.name}@${a.version}`;
}

/** 該当する資産ごとにOSVの脆弱性IDを集める。版が分からない資産(リビジョン固定など)は対象外。 */
export async function queryOsv(client: HttpClient, assets: Asset[]) {
  const targets = assets.filter((a) => a.version);
  const hits: { asset: Asset; id: string }[] = [];
  const skipped = assets.filter((a) => !a.version);

  for (let i = 0; i < targets.length; i += 500) {
    const chunk = targets.slice(i, i + 500);
    const body = JSON.stringify({
      queries: chunk.map((a) => ({ package: { name: a.name, ecosystem: a.ecosystem }, version: a.version })),
    });
    const res = await client.json<{ results?: OsvQueryResult[] }>(`${BASE}/querybatch`, { method: 'POST', body });
    for (let j = 0; j < chunk.length; j++) {
      const r: OsvQueryResult = res.results?.[j] ?? {};
      let ids = (r.vulns ?? []).map((v) => v.id);
      // 1問い合わせの結果が多いときはページ分割される
      let token = r.next_page_token;
      while (token) {
        const page = await client.json<OsvQueryResult>(`${BASE}/query`, {
          method: 'POST',
          body: JSON.stringify({ package: { name: chunk[j].name, ecosystem: chunk[j].ecosystem }, version: chunk[j].version, page_token: token }),
        });
        ids = ids.concat((page.vulns ?? []).map((v) => v.id));
        token = page.next_page_token;
      }
      for (const id of new Set(ids)) hits.push({ asset: chunk[j], id });
    }
  }

  const details = new Map<string, OsvVuln>();
  for (const id of new Set<string>(hits.map((h) => h.id))) {
    details.set(id, await client.json<OsvVuln>(`${BASE}/vulns/${encodeURIComponent(id)}`));
  }
  return { hits, details, skipped };
}

export function fixedVersionFor(vuln: OsvVuln, asset: Pick<Asset, 'name' | 'ecosystem'>) {
  const fixes: string[] = [];
  for (const aff of vuln.affected ?? []) {
    if (aff.package?.name !== asset.name || aff.package?.ecosystem !== asset.ecosystem) continue;
    for (const range of aff.ranges ?? []) {
      for (const ev of range.events ?? []) if (ev.fixed) fixes.push(ev.fixed);
    }
  }
  return fixes.length ? fixes : null;
}

export function scoreFromVuln(vuln: OsvVuln) {
  for (const s of vuln.severity ?? []) {
    const n = cvss3BaseScore(s.score);
    if (n !== null) return { cvss: n, cvssSource: 'CVSS v3 (OSV vector)' };
  }
  const label = vuln.database_specific?.severity;
  const n = severityLabelToScore(label);
  return n === null ? { cvss: null, cvssSource: null } : { cvss: n, cvssSource: `深刻度ラベル ${label} からの代用値` };
}

export function osvFindings({ hits, details }: { hits: { asset: Asset; id: string }[]; details: Map<string, OsvVuln> }): Finding[] {
  const out: Finding[] = [];
  for (const { asset, id } of hits) {
    const v = details.get(id);
    if (!v || v.withdrawn) continue;
    const ids = [v.id, ...(v.aliases ?? [])];
    out.push({
      ids,
      cve: ids.find((x) => x.startsWith('CVE-')) ?? null,
      sources: ['osv'],
      asset: assetKey(asset),
      summary: v.summary ?? (v.details ?? '').split('\n')[0],
      ...scoreFromVuln(v),
      fixed: fixedVersionFor(v, asset),
      status: 'confirmed',
      references: (v.references ?? []).map((r) => r.url).slice(0, 5),
      published: v.published ?? null,
    });
  }
  return out;
}
