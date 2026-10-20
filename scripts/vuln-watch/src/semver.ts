// 脆弱性の版範囲判定に使う最小限のsemver。外部パッケージは使わない。

export function parseVersion(v: any) {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.\d+)*(?:-([0-9A-Za-z.-]+))?/.exec(String(v ?? '').trim());
  if (!m) return null;
  return { nums: [Number(m[1]), Number(m[2] ?? 0), Number(m[3] ?? 0)], pre: m[4] ?? null };
}

function comparePre(a: any, b: any) {
  if (a === b) return 0;
  if (a === null) return 1; // 正式版はプレリリースより新しい
  if (b === null) return -1;
  const pa = a.split('.');
  const pb = b.split('.');
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if (pa[i] === undefined) return -1;
    if (pb[i] === undefined) return 1;
    const na = /^\d+$/.test(pa[i]);
    const nb = /^\d+$/.test(pb[i]);
    if (na && nb) {
      const d = Number(pa[i]) - Number(pb[i]);
      if (d) return d < 0 ? -1 : 1;
    } else if (na !== nb) {
      return na ? -1 : 1;
    } else if (pa[i] !== pb[i]) {
      return pa[i] < pb[i] ? -1 : 1;
    }
  }
  return 0;
}

/** a<b なら負、等しければ0、a>b なら正。解釈できない版は null。 */
export function compareVersions(a: any, b: any) {
  const x = parseVersion(a);
  const y = parseVersion(b);
  if (!x || !y) return null;
  for (let i = 0; i < 3; i++) {
    if (x.nums[i] !== y.nums[i]) return x.nums[i] < y.nums[i] ? -1 : 1;
  }
  return comparePre(x.pre, y.pre);
}

/**
 * NVDのcpeMatch形式の範囲に版が入るか。
 * 範囲の指定がまったく無ければ「全版が対象」ではなく null(判断不能)を返す。
 */
export function inCpeRange(version: any, range: any) {
  const { versionStartIncluding, versionStartExcluding, versionEndIncluding, versionEndExcluding } = range;
  if (!versionStartIncluding && !versionStartExcluding && !versionEndIncluding && !versionEndExcluding) return null;
  const checks = [
    [versionStartIncluding, (c: any) => c >= 0],
    [versionStartExcluding, (c: any) => c > 0],
    [versionEndIncluding, (c: any) => c <= 0],
    [versionEndExcluding, (c: any) => c < 0],
  ];
  for (const [bound, ok] of checks) {
    if (!bound) continue;
    const c = compareVersions(version, bound);
    if (c === null) return null;
    if (!ok(c)) return false;
  }
  return true;
}
