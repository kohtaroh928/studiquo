import type { HttpClient } from './http.ts';

// 優先度の材料: CISA KEV(実際に悪用が確認されたもの)とEPSS(悪用される確率)。

const KEV_URL = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json';
const EPSS_URL = 'https://api.first.org/data/v1/epss';

export async function fetchKev(client: HttpClient) {
  const data = await client.json<{ vulnerabilities?: { cveID: string; dueDate?: string; knownRansomwareCampaignUse?: string }[] }>(KEV_URL);
  return new Map((data.vulnerabilities ?? []).map((v) => [v.cveID, { dueDate: v.dueDate ?? null, ransomware: v.knownRansomwareCampaignUse === 'Known' }]));
}

export async function fetchEpss(client: HttpClient, cves: unknown[] | Iterable<unknown> | null | undefined) {
  const out = new Map();
  const list = [...new Set(cves)];
  for (let i = 0; i < list.length; i += 50) {
    const data = await client.json<{ data?: { cve: string; epss: string; percentile: string }[] }>(`${EPSS_URL}?cve=${list.slice(i, i + 50).join(',')}`);
    for (const r of data.data ?? []) out.set(r.cve, { epss: Number(r.epss), percentile: Number(r.percentile) });
  }
  return out;
}
