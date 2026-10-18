import test from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions, inCpeRange } from '../src/semver.js';
import { cvss3BaseScore, severityLabelToScore } from '../src/cvss.js';
import { swiftUrlName, parseNpmLock, parseSwiftResolved, applyManual, dedupe } from '../src/inventory.js';
import { matchCve, nvdHintFor } from '../src/nvd.js';
import { queryOsv, osvFindings, fixedVersionFor } from '../src/osv.js';
import { scoreFinding, tierFor, mergeFindings, rank } from '../src/score.js';
import { renderReport } from '../src/report.js';
import { createClient } from '../src/http.js';

test('semver: 比較とプレリリース', () => {
  assert.equal(compareVersions('1.2.3', '1.2.3'), 0);
  assert.ok(compareVersions('1.10.0', '1.9.9') > 0);
  assert.ok(compareVersions('2.0.0-rc.1', '2.0.0') < 0);
  assert.ok(compareVersions('2.0.0-rc.2', '2.0.0-rc.10') < 0);
  assert.equal(compareVersions('abc', '1.0.0'), null);
});

test('semver: CPE範囲。範囲が無ければ判断不能(null)', () => {
  assert.equal(inCpeRange('5.10.0', { versionEndExcluding: '5.11.0' }), true);
  assert.equal(inCpeRange('5.11.0', { versionEndExcluding: '5.11.0' }), false);
  assert.equal(inCpeRange('4.0.0', { versionStartIncluding: '5.0.0' }), false);
  assert.equal(inCpeRange('5.0.0', {}), null);
});

test('cvss: 既知のベクトルのスコア', () => {
  assert.equal(cvss3BaseScore('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H'), 10);
  assert.equal(cvss3BaseScore('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H'), 9.8);
  assert.equal(cvss3BaseScore('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N'), 0);
  assert.equal(cvss3BaseScore('CVSS:4.0/AV:N/AC:L'), null);
  assert.equal(severityLabelToScore('moderate'), 5.5);
});

test('inventory: SwiftURL名はスキームと.gitを除く', () => {
  assert.equal(swiftUrlName('https://github.com/google/GoogleSignIn-iOS.git'), 'github.com/google/GoogleSignIn-iOS');
  assert.equal(swiftUrlName('git@github.com:a/b.git'), 'github.com/a/b');
});

test('inventory: package-lockのdevはtooling、直接依存を判別', () => {
  const lock = {
    packages: {
      '': { name: 'x' },
      'node_modules/jose': { version: '5.10.0' },
      'node_modules/esbuild': { version: '0.25.0', dev: true },
      'node_modules/a/node_modules/jose': { version: '4.0.0' },
    },
  };
  const items = parseNpmLock(lock, { dependencies: { jose: '^5' }, devDependencies: { esbuild: '^0.25' } });
  const by = (n, v) => items.find((i) => i.name === n && i.version === v);
  assert.equal(by('jose', '5.10.0').exposure, 'server');
  assert.equal(by('jose', '5.10.0').direct, true);
  assert.equal(by('jose', '4.0.0').direct, false); // 入れ子は間接依存
  assert.equal(by('esbuild', '0.25.0').exposure, 'tooling');
});

test('inventory: Package.resolved(v2)とリビジョン固定', () => {
  const items = parseSwiftResolved({
    version: 2,
    pins: [
      { identity: 'purchases-ios', location: 'https://github.com/RevenueCat/purchases-ios.git', state: { version: '5.92.0', revision: 'abc' } },
      { identity: 'swiftmath', location: 'https://github.com/mgriebling/SwiftMath', state: { revision: '1d2c908' } },
    ],
  });
  assert.equal(items[0].name, 'github.com/RevenueCat/purchases-ios');
  assert.equal(items[0].version, '5.92.0');
  assert.equal(items[1].version, null);
  const merged = applyManual(items, { assets: { 'SwiftURL:purchases-ios': { sensitive: true } } });
  assert.equal(merged[0].sensitive, true);
  assert.equal(merged[1].sensitive, false);
});

test('inventory: 同じ版がruntimeとdevの両方にあればruntimeを優先', () => {
  const out = dedupe([
    { ecosystem: 'npm', name: 'a', version: '1.0.0', exposure: 'tooling' },
    { ecosystem: 'npm', name: 'a', version: '1.0.0', exposure: 'server' },
  ]);
  assert.equal(out.length, 1);
  assert.equal(out[0].exposure, 'server');
});

const cveWith = (cpeMatch) => ({ id: 'CVE-2099-0001', configurations: [{ nodes: [{ cpeMatch }] }] });
const asset = { ecosystem: 'npm', name: 'jose', version: '5.10.0' };

test('nvd: vendor指定+範囲内のみ「確定」、それ以外は「要確認」、範囲外は無関係', () => {
  const hint = { products: ['jose'], vendors: ['panva'] };
  const m = (extra, vendor = 'panva') => cveWith([{ vulnerable: true, criteria: `cpe:2.3:a:${vendor}:jose:*:*:*:*:*:node.js:*:*`, ...extra }]);
  assert.equal(matchCve(m({ versionEndExcluding: '5.11.0' }), asset, hint), 'affected');
  assert.equal(matchCve(m({ versionEndExcluding: '5.0.0' }), asset, hint), null);
  assert.equal(matchCve(m({}), asset, hint), 'review'); // 範囲が無い=判断不能
  assert.equal(matchCve(m({ versionEndExcluding: '5.11.0' }, 'other'), asset, hint), null);
  assert.equal(matchCve(m({ versionEndExcluding: '5.11.0' }), asset, { products: ['jose'] }), 'review'); // vendor指定なし
});

test('nvd: 間接依存はNVDを引かない', () => {
  assert.equal(nvdHintFor({ ecosystem: 'npm', name: 'x', direct: false }), null);
  assert.deepEqual(nvdHintFor({ ecosystem: 'npm', name: '@a/b', direct: true }), { keyword: 'b', products: ['b'] });
});

const fakeFetch = (routes) => async (url, init) => {
  for (const [pat, body] of routes) {
    if (url.includes(pat)) return { ok: true, status: 200, json: async () => (typeof body === 'function' ? body(init) : body) };
  }
  return { ok: false, status: 404, json: async () => ({}) };
};

test('osv: 問い合わせ→詳細取得→修正版と点数の抽出。取り下げは除外', async () => {
  const vuln = {
    id: 'GHSA-aaaa',
    aliases: ['CVE-2099-0002'],
    summary: 'bad thing',
    severity: [{ type: 'CVSS_V3', score: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H' }],
    affected: [{ package: { name: 'jose', ecosystem: 'npm' }, ranges: [{ type: 'SEMVER', events: [{ introduced: '0' }, { fixed: '5.11.0' }] }] }],
    references: [{ url: 'https://example.com/a' }],
  };
  const withdrawn = { id: 'GHSA-bbbb', withdrawn: '2099-01-01T00:00:00Z' };
  const client = createClient({
    fetchImpl: fakeFetch([
      ['querybatch', { results: [{ vulns: [{ id: 'GHSA-aaaa' }, { id: 'GHSA-bbbb' }] }, {}] }],
      ['/vulns/GHSA-aaaa', vuln],
      ['/vulns/GHSA-bbbb', withdrawn],
    ]),
  });
  const assets = [asset, { ecosystem: 'SwiftURL', name: 'github.com/x/y', version: null, revision: 'abc' }];
  const res = await queryOsv(client, assets);
  assert.equal(res.skipped.length, 1);
  const f = osvFindings(res);
  assert.equal(f.length, 1);
  assert.equal(f[0].cve, 'CVE-2099-0002');
  assert.equal(f[0].cvss, 9.8);
  assert.deepEqual(f[0].fixed, ['5.11.0']);
  assert.equal(f[0].status, 'confirmed');
  assert.equal(fixedVersionFor(vuln, { name: 'other', ecosystem: 'npm' }), null);
});

test('http: 4xxは再試行せず失敗、5xxは再試行して成功', async () => {
  let calls = 0;
  const flaky = createClient({
    sleep: async () => {},
    fetchImpl: async () => (++calls < 3 ? { ok: false, status: 503 } : { ok: true, status: 200, json: async () => ({ ok: 1 }) }),
  });
  assert.deepEqual(await flaky.json('https://example.com/x'), { ok: 1 });
  assert.equal(calls, 3);
  let c2 = 0;
  const bad = createClient({ sleep: async () => {}, fetchImpl: async () => (c2++, { ok: false, status: 404 }) });
  await assert.rejects(bad.json('https://example.com/y'), /HTTP 404/);
  assert.equal(c2, 1);
});

const base = { cvss: 9.8, epss: 0, kev: false, exposure: 'server', sensitive: false, status: 'confirmed' };

test('score: 影響範囲・加点・KEVで順位が変わる', () => {
  assert.equal(scoreFinding(base), 59);
  assert.ok(scoreFinding({ ...base, exposure: 'tooling' }) < scoreFinding({ ...base, exposure: 'app' }));
  assert.equal(scoreFinding({ ...base, sensitive: true }), 69);
  assert.equal(scoreFinding({ ...base, kev: true, sensitive: true }), 99);
  assert.equal(scoreFinding({ ...base, cvss: null }), 30);
});

test('score: 区分。KEVは緊急、未確定は中が上限(KEVなら高)', () => {
  assert.equal(tierFor({ ...base, kev: true }, 60), '緊急');
  assert.equal(tierFor(base, 59), '高');
  assert.equal(tierFor(base, 40), '中');
  assert.equal(tierFor(base, 10), '情報');
  assert.equal(tierFor({ ...base, status: 'needs-review' }, 90), '中');
  assert.equal(tierFor({ ...base, status: 'needs-review', kev: true }, 90), '高');
});

test('merge+rank: OSVとNVDを同じCVE・資産で1件にし、KEVで最上位へ', () => {
  const key = 'npm:jose@5.10.0';
  const a = { ids: ['GHSA-x', 'CVE-2099-1'], cve: 'CVE-2099-1', sources: ['osv'], asset: key, summary: 's', cvss: 7, cvssSource: '深刻度ラベル HIGH からの代用値', fixed: ['5.11.0'], status: 'confirmed', references: [] };
  const b = { ids: ['CVE-2099-1'], cve: 'CVE-2099-1', sources: ['nvd'], asset: key, summary: '', cvss: 8.1, cvssSource: 'NVD CVSS V31', fixed: null, status: 'needs-review', references: [] };
  const c = { ...a, ids: ['CVE-2099-2'], cve: 'CVE-2099-2', cvss: 9.9 };
  const merged = mergeFindings([a, b, c]);
  assert.equal(merged.length, 2);
  const one = merged.find((m) => m.cve === 'CVE-2099-1');
  assert.deepEqual(one.sources.sort(), ['nvd', 'osv']);
  assert.equal(one.cvss, 8.1); // NVDの数値を優先
  assert.equal(one.status, 'confirmed');
  assert.deepEqual(one.fixed, ['5.11.0']);

  const ranked = rank(merged, {
    assetsByKey: new Map([[key, { exposure: 'server', sensitive: true }]]),
    kev: new Map([['CVE-2099-1', { dueDate: '2099-01-01' }]]),
    epss: new Map(),
  });
  assert.equal(ranked[0].cve, 'CVE-2099-1');
  assert.equal(ranked[0].tier, '緊急');
});

test('report: 区分ごとに出力し、取得失敗は警告に出す。説明文の記号は除く', () => {
  const ranked = [
    { tier: '緊急', score: 100, cve: 'CVE-2099-1', ids: ['CVE-2099-1'], asset: 'npm:jose@5.10.0', summary: '<script>`x`|', cvss: 9.8, cvssSource: 'NVD', epss: 0.5, kev: { dueDate: '2099-01-01' }, exposure: 'server', sensitive: true, usage: 'JWT', fixed: ['5.11.0'], sources: ['osv'], references: ['https://e.com'], status: 'confirmed' },
    { tier: '情報', score: 5, cve: 'CVE-2099-3', ids: ['CVE-2099-3'], asset: 'npm:z@1.0.0', summary: 'low', cvss: 2, cvssSource: 'NVD', epss: null, kev: null, exposure: 'tooling', fixed: null, sources: ['osv'], references: [], status: 'confirmed' },
  ];
  const md = renderReport({ ranked, inventory: [{ ecosystem: 'npm' }], unmatchable: [{ ecosystem: 'SwiftURL', name: 'github.com/x/y', revision: 'abcdef1234567' }], sourceErrors: ['OSV: 落ちた'], generatedAt: 'T' });
  assert.match(md, /## 緊急\(1件\)/);
  assert.match(md, /CISA KEV掲載/);
  assert.match(md, /取得に失敗したデータ源/);
  assert.match(md, /照合できなかった対象/);
  assert.ok(!md.includes('<script>'));
});
