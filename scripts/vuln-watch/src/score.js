// 優先度の計算。数値は式だけで決め、LLMには決めさせない(設計書「優先度の付け方」)。
// 重みは実データを見て調整する前提で、定数としてまとめている。

export const WEIGHTS = {
  cvssUnknown: 5, // CVSSが無いときの仮の値
  cvssFactor: 6, // CVSS(0-10) → 0-60点
  epssFactor: 20, // EPSS(0-1) → 0-20点
  kevBonus: 30,
  sensitiveBonus: 10, // 認証・課金・個人情報に関わる依存
  exposure: { server: 1.0, app: 0.9, tooling: 0.5 },
  tiers: { urgent: 80, high: 55, medium: 30 },
};

export const TIERS = ['緊急', '高', '中', '情報'];

export function scoreFinding(f, w = WEIGHTS) {
  const base = (f.cvss ?? w.cvssUnknown) * w.cvssFactor + (f.epss ?? 0) * w.epssFactor + (f.kev ? w.kevBonus : 0);
  const mult = w.exposure[f.exposure] ?? 1;
  return Math.min(100, Math.round(base * mult + (f.sensitive ? w.sensitiveBonus : 0)));
}

export function tierFor(f, score, w = WEIGHTS) {
  let tier;
  if (f.kev || score >= w.tiers.urgent) tier = '緊急';
  else if (score >= w.tiers.high) tier = '高';
  else if (score >= w.tiers.medium) tier = '中';
  else tier = '情報';
  // 「要確認」は該当が確定していないので、KEVを除いて「中」を上限にする
  if (f.status === 'needs-review' && !f.kev) {
    if (tier === '緊急' || tier === '高') tier = '中';
  } else if (f.status === 'needs-review' && tier === '緊急') {
    tier = '高';
  }
  return tier;
}

/** 同じ脆弱性(CVE、無ければ最初のID)×同じ資産を1件にまとめる。 */
export function mergeFindings(findings) {
  const map = new Map();
  for (const f of findings) {
    const key = `${f.cve ?? f.ids[0]}|${f.asset}`;
    const prev = map.get(key);
    if (!prev) {
      map.set(key, { ...f, ids: [...new Set(f.ids)], sources: [...f.sources], references: [...f.references] });
      continue;
    }
    prev.ids = [...new Set([...prev.ids, ...f.ids])];
    prev.sources = [...new Set([...prev.sources, ...f.sources])];
    prev.references = [...new Set([...prev.references, ...f.references])].slice(0, 8);
    prev.cve ??= f.cve;
    // 数値のCVSSがある方を優先。同じ種類ならNVD(公式の数値)を優先
    const isProxy = (x) => /代用値/.test(x ?? '');
    if (f.cvss !== null && (prev.cvss === null || (isProxy(prev.cvssSource) && !isProxy(f.cvssSource)) || (f.sources.includes('nvd') && !isProxy(f.cvssSource)))) {
      prev.cvss = f.cvss;
      prev.cvssSource = f.cvssSource;
    }
    prev.fixed ??= f.fixed;
    prev.jvndb ??= f.jvndb;
    prev.titleJa ??= f.titleJa;
    prev.matchedBy ??= f.matchedBy;
    prev.summary ||= f.summary;
    if (f.status === 'confirmed') prev.status = 'confirmed';
  }
  return [...map.values()];
}

export function rank(findings, { assetsByKey, kev, epss }) {
  return findings
    .map((f) => {
      const asset = assetsByKey.get(f.asset) ?? {};
      const cveId = f.cve;
      const full = {
        ...f,
        exposure: asset.exposure ?? 'server',
        sensitive: asset.sensitive ?? false,
        usage: asset.usage ?? null,
        kev: cveId ? kev.get(cveId) ?? null : null,
        epss: cveId ? epss.get(cveId)?.epss ?? null : null,
      };
      full.score = scoreFinding({ ...full, kev: Boolean(full.kev) });
      full.tier = tierFor({ ...full, kev: Boolean(full.kev) }, full.score);
      return full;
    })
    .sort((a, b) => TIERS.indexOf(a.tier) - TIERS.indexOf(b.tier) || b.score - a.score || (a.cve ?? a.ids[0]).localeCompare(b.cve ?? b.ids[0]));
}
