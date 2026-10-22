// NVD API 2.0: キーワードで候補を集め、CPEと版範囲で絞る。
// npm/SwiftPMのライブラリはCPEが付かないことが多いので、「確定」にできるのは
// vendor・product・版範囲がそろったときだけ。それ以外は「要確認」とする。

import { inCpeRange, compareVersions } from './semver.ts';
import { assetKey } from './osv.ts';
import type { HttpClient } from './http.ts';
import type { Asset, Finding, NvdCpeMatch, NvdCve, NvdHint } from './types.ts';

const BASE = 'https://services.nvd.nist.gov/rest/json/cves/2.0';

/** 1ページ分の応答。 */
interface NvdPage { vulnerabilities?: { cve: NvdCve & { vulnStatus?: string } }[]; resultsPerPage?: number; totalResults?: number }

export function nvdHintFor(asset: Pick<Asset, 'ecosystem' | 'name' | 'direct' | 'nvd'>): NvdHint | null {
  if (asset.nvd) return asset.nvd;
  if (asset.ecosystem === 'npm' && asset.direct) {
    const base = asset.name.replace(/^@[^/]+\//, '');
    return { keyword: base, products: [base] };
  }
  return null; // 間接依存はOSVに任せる(NVDの全件検索は件数が多すぎる)
}

export function parseCpe(criteria: unknown) {
  const p = String(criteria).split(':');
  return { part: p[2], vendor: p[3]?.toLowerCase(), product: p[4]?.toLowerCase(), version: p[5] };
}

const norm = (s: string) => String(s).toLowerCase().replace(/[-_]/g, '');

/** 1件のCVEが資産に当たるか。'affected' | 'review' | null(無関係)を返す。 */
export function matchCve(cve: NvdCve, asset: Pick<Asset, 'version'> & Partial<Asset>, hint: Partial<NvdHint>) {
  const products = (hint.products ?? []).map(norm);
  const vendors = (hint.vendors ?? []).map(norm);
  let result = null;
  for (const conf of cve.configurations ?? []) {
    for (const node of conf.nodes ?? []) {
      for (const m of node.cpeMatch ?? []) {
        if (!m.vulnerable) continue;
        const c = parseCpe(m.criteria);
        if (c.part !== 'a') continue; // OSやハードウェアは対象外
        if (!products.includes(norm(c.product ?? ''))) continue;
        const vendorOk = vendors.length === 0 ? null : vendors.includes(norm(c.vendor ?? ''));
        if (vendorOk === false) continue;
        let inRange;
        if (c.version && c.version !== '*' && c.version !== '-') inRange = compareVersions(asset.version, c.version) === 0;
        else inRange = inCpeRange(asset.version, m);
        if (inRange === true && vendorOk === true) return 'affected';
        if (inRange !== false) result = 'review'; // 範囲不明、またはvendor指定なし
      }
    }
  }
  return result;
}

function bestScore(metrics: NvdCve['metrics'] = {}) {
  for (const k of ['cvssMetricV40', 'cvssMetricV31', 'cvssMetricV30']) {
    const m = metrics[k]?.find((x: { type: string; }) => x.type === 'Primary') ?? metrics[k]?.[0];
    if (m) return { cvss: m.cvssData.baseScore, cvssSource: `NVD ${k.replace('cvssMetric', 'CVSS ')}` };
  }
  return { cvss: null, cvssSource: null };
}

export async function queryNvd(client: HttpClient, assets: Asset[], { apiKey = null as string | null } = {}) {
  const findings: Finding[] = [];
  const gap = apiKey ? 700 : 6500; // キー無しは30秒5件まで
  const headers: Record<string, string> = apiKey ? { apiKey } : {};
  for (const asset of assets) {
    const hint = nvdHintFor(asset);
    if (!hint || !asset.version) continue;
    let start = 0;
    for (;;) {
      const url = `${BASE}?keywordSearch=${encodeURIComponent(hint.keyword)}&resultsPerPage=200&startIndex=${start}`;
      const page = await client.json<NvdPage>(url, { headers, minGapMs: gap });
      for (const { cve } of page.vulnerabilities ?? []) {
        if (cve.vulnStatus === 'Rejected') continue;
        const verdict = matchCve(cve, asset, hint);
        if (!verdict) continue;
        findings.push({
          ids: [cve.id],
          cve: cve.id,
          sources: ['nvd'],
          asset: assetKey(asset),
          summary: cve.descriptions?.find((d) => d.lang === 'en')?.value?.split('\n')[0] ?? '',
          ...bestScore(cve.metrics),
          fixed: null,
          status: verdict === 'affected' ? 'confirmed' : 'needs-review',
          references: (cve.references ?? []).map((r) => r.url).slice(0, 5),
          published: cve.published ?? null,
        });
      }
      start += page.resultsPerPage ?? 0;
      if (!page.resultsPerPage || start >= (page.totalResults ?? 0)) break;
    }
  }
  return findings;
}
