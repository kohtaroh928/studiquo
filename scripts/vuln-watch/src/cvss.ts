// CVSS v3.x のベーススコア計算。OSV/GHSAはベクトル文字列しか持たないことがあるため。
// v4.0 は計算が大きいので扱わない(呼び出し側が文字の深刻度にフォールバックする)。

const W: Record<string, Record<string, number>> = {
  AV: { N: 0.85, A: 0.62, L: 0.55, P: 0.2 },
  AC: { L: 0.77, H: 0.44 },
  UI: { N: 0.85, R: 0.62 },
  CIA: { H: 0.56, L: 0.22, N: 0 },
};

function roundUp1(x: any) {
  const i = Math.round(x * 100000);
  return i % 10000 === 0 ? i / 100000 : (Math.floor(i / 10000) + 1) / 10;
}

export function cvss3BaseScore(vector: any) {
  if (typeof vector !== 'string' || !/^CVSS:3\.[01]\//.test(vector)) return null;
  const m: Record<string, string> = Object.fromEntries(vector.split('/').slice(1).map((p: string) => p.split(':')));
  const changed = m.S === 'C';
  if (!(m.AV in W.AV) || !(m.AC in W.AC) || !(m.UI in W.UI) || !['U', 'C'].includes(m.S)) return null;
  if (!(m.C in W.CIA) || !(m.I in W.CIA) || !(m.A in W.CIA)) return null;
  const pr = { N: 0.85, L: changed ? 0.68 : 0.62, H: changed ? 0.5 : 0.27 }[m.PR];
  if (pr === undefined) return null;
  const iss = 1 - (1 - W.CIA[m.C]) * (1 - W.CIA[m.I]) * (1 - W.CIA[m.A]);
  const impact = changed ? 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 : 6.42 * iss;
  const expl = 8.22 * W.AV[m.AV] * W.AC[m.AC] * pr * W.UI[m.UI];
  if (impact <= 0) return 0;
  return roundUp1(Math.min(changed ? 1.08 * (impact + expl) : impact + expl, 10));
}

/** GHSAなどの文字の深刻度を、数値が無いときの代用点にする。 */
export function severityLabelToScore(label: any) {
  return { CRITICAL: 9.5, HIGH: 8, MODERATE: 5.5, MEDIUM: 5.5, LOW: 2.5 }[String(label ?? '').toUpperCase()] ?? null;
}
