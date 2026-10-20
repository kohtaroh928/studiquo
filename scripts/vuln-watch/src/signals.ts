// 優先度の材料: CISA KEV(実際に悪用が確認されたもの)とEPSS(悪用される確率)。

const KEV_URL = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json';
const EPSS_URL = 'https://api.first.org/data/v1/epss';

export async function fetchKev(client: any) {
  const data = await client.json(KEV_URL);
  return new Map((data.vulnerabilities ?? []).map((v: any) => [v.cveID, { dueDate: v.dueDate ?? null, ransomware: v.knownRansomwareCampaignUse === 'Known' }]));
}

export async function fetchEpss(client: any, cves: any) {
  const out = new Map();
  const list = [...new Set(cves)];
  for (let i = 0; i < list.length; i += 50) {
    const data = await client.json(`${EPSS_URL}?cve=${list.slice(i, i + 50).join(',')}`);
    for (const r of data.data ?? []) out.set(r.cve, { epss: Number(r.epss), percentile: Number(r.percentile) });
  }
  return out;
}
