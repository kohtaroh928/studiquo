// JVN iPedia (MyJVN API): 日本語の題名・概要とJVNDB番号を得る。
// ライブラリではNVD・OSVを超える補完にはなりにくい(設計書 2.1)ので、
//  - 既存の指摘とCVE番号が一致したら、JVNDB番号と日本語題名を足すだけ
//  - 新規に見つけたものは常に「要確認」にして、LLM判定に回す
// 応答はXML。外部入力なので、エンティティ展開をしない最小の読み取りで必要なタグだけ取る。

import { assetKey } from './osv.ts';
import { nvdHintFor } from './nvd.ts';

const BASE = 'https://jvndb.jvn.jp/myjvn';
const PAGE = 50;

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

export function decodeXml(s: any) {
  return String(s)
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&(#x[0-9a-fA-F]+|#\d+|[a-z]+);/g, (m, e) => {
      if (e[0] === '#') {
        const code = e[1] === 'x' ? parseInt(e.slice(2), 16) : Number(e.slice(1));
        return Number.isFinite(code) && code > 8 && code < 0x110000 ? String.fromCodePoint(code) : '';
      }
      return ENTITIES[e] ?? m;
    });
}

const tag = (block: any, name: any) => {
  const m = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`).exec(block);
  return m ? decodeXml(m[1]).trim() : null;
};

const attr = (openTag: any, name: any) => {
  const m = new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(openTag);
  return m ? decodeXml(m[1]) : null;
};

/** getVulnOverviewList の応答から、項目と総件数を取り出す。 */
export function parseOverview(xml: any) {
  const items = [];
  for (const m of String(xml).matchAll(/<item\s[^>]*>([\s\S]*?)<\/item>/g)) {
    const b = m[1];
    const jvndb = tag(b, 'sec:identifier');
    if (!jvndb || !/^JVNDB-\d{4}-\d+$/.test(jvndb)) continue;
    const cves = [...b.matchAll(/<sec:references\s([^>]*)>/g)]
      .filter((r) => attr(r[1], 'source') === 'CVE')
      .map((r) => attr(r[1], 'id'))
      .filter((id) => /^CVE-\d{4}-\d{4,}$/.test(id ?? ''));
    const cpes = [...b.matchAll(/<sec:cpe\s[^>]*>([^<]*)<\/sec:cpe>/g)].map((r) => {
      const p = decodeXml(r[1]).trim().split(':'); // cpe:/a:vendor:product[:version]
      return { part: p[1]?.replace('/', ''), vendor: p[2]?.toLowerCase() ?? '', product: p[3]?.toLowerCase() ?? '', version: p[4] ?? null };
    });
    const cvssTag = /<sec:cvss\s([^>]*)\/?>/.exec(b);
    const rawScore = cvssTag ? attr(cvssTag[1], 'score') : null;
    const score = rawScore === null || rawScore === '' ? NaN : Number(rawScore);
    items.push({
      jvndb,
      cves: [...new Set(cves)],
      cpes,
      titleJa: tag(b, 'title'),
      description: tag(b, 'description'),
      link: tag(b, 'link'),
      cvss: Number.isFinite(score) ? score : null,
      cvssVersion: cvssTag ? attr(cvssTag[1], 'version') : null,
      published: tag(b, 'dcterms:issued') ?? tag(b, 'dc:date'),
    });
  }
  const st = /<status:Status\s([^>]*)\/?>/.exec(xml);
  const total = st && /^\d+$/.test(attr(st[1], 'totalRes') ?? '') ? Number(attr(st[1], 'totalRes')) : null;
  return {
    items,
    total: total ?? 0,
    // Statusが無い・件数が数字でない応答(HTMLのエラーページ、途中で切れた応答)は正常な「0件」ではない
    ok: Boolean(st) && total !== null,
    errCd: st ? attr(st[1], 'errCd') : null,
    errMsg: st ? attr(st[1], 'errMsg') : null,
  };
}

const norm = (s: any) => String(s).toLowerCase().replace(/[-_\s]/g, '');

/**
 * 項目が資産に関係しそうか。'cpe'=CPEのproductがヒントと一致 / 'text'=CPE無しで題名・概要に語がある / null=無関係。
 * CPEがあって一致しないもの(例: npmのjoseに対するGo JOSE)は捨てる。
 */
export function relevance(item: any, hint: any) {
  const products = (hint.products ?? []).map(norm);
  const vendors = (hint.vendors ?? []).map(norm);
  const apps = item.cpes.filter((c: any) => c.part === 'a');
  if (apps.length) {
    const hit = apps.some((c: any) => products.includes(norm(c.product)) && (vendors.length === 0 || vendors.includes(norm(c.vendor))));
    return hit ? 'cpe' : null;
  }
  // 短い語(zodなど)が別の単語の一部に当たらないよう、語の境界で探す
  const words = String(hint.keyword ?? '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  if (!words.length) return null;
  const hay = `${item.titleJa ?? ''} ${item.description ?? ''}`.toLowerCase();
  const re = new RegExp(`(^|[^a-z0-9])${words.join('[^a-z0-9]+')}($|[^a-z0-9])`);
  return re.test(hay) ? 'text' : null;
}

async function fetchAll(client: any, keyword: any, { maxPages = 4 } = {}) {
  const all = [];
  let start = 1;
  let total = 0;
  for (let page = 0; page < maxPages; page++) {
    const url =
      `${BASE}?method=getVulnOverviewList&feed=hnd&keyword=${encodeURIComponent(keyword)}` +
      `&rangeDatePublic=n&rangeDatePublished=n&rangeDateFirstPublished=n&lang=ja&maxCountItem=${PAGE}&startItem=${start}`;
    const parsed = parseOverview(await client.text(url, { minGapMs: 1000 }));
    if (parsed.errCd) throw new Error(`JVN: ${parsed.errCd} ${parsed.errMsg ?? ''}`.trim());
    if (!parsed.ok) throw new Error('JVN: 応答がJVNの形式ではありません(エラーページか、途中で切れた応答)');
    all.push(...parsed.items);
    total = parsed.total;
    start += PAGE;
    if (start > parsed.total || parsed.items.length === 0) break;
  }
  return { items: all, truncated: total > all.length && all.length >= PAGE * maxPages, total };
}

/** 1項目×CVE番号ごとに指摘を作る。CVE番号が無ければJVNDB番号で1件。 */
export function jvnFindings(item: any, asset: any, via: any) {
  const base = {
    sources: ['jvn'],
    asset: assetKey(asset),
    // 概要文には「バージョン4.1.4より前」のような版の範囲が書かれていることが多く、LLMが版を突き合わせる材料になる
    summary: item.description || item.titleJa || '',
    titleJa: item.titleJa,
    jvndb: item.jvndb,
    cvss: item.cvss,
    cvssSource: item.cvss === null ? null : `JVN CVSS v${item.cvssVersion ?? '?'}`,
    fixed: null,
    status: 'needs-review', // JVNの概要には版が無い。範囲は概要文を見てLLMが判定する
    matchedBy: via,
    references: item.link ? [item.link] : [],
    published: item.published,
  };
  const ids = (cve: any) => [...new Set([item.jvndb, ...(cve ? [cve] : [])])];
  return item.cves.length
    ? item.cves.map((cve: any) => ({ ...base, ids: ids(cve), cve }))
    : [{ ...base, ids: ids(null), cve: null }];
}

export async function queryJvn(client: any, assets: any, { onWarning = (_message: string) => {} } = {}) {
  const findings = [];
  for (const asset of assets) {
    const hint = nvdHintFor(asset);
    if (!hint || !asset.version) continue;
    const keyword = hint.jvn?.keyword ?? hint.keyword;
    const { items, truncated, total } = await fetchAll(client, keyword);
    if (truncated) onWarning(`JVN: 「${keyword}」は${total}件あり、先頭${items.length}件までしか読んでいません(キーワードを絞ってください)`);
    for (const item of items) {
      const via = relevance(item, { ...hint, keyword });
      if (via) findings.push(...jvnFindings(item, asset, via));
    }
  }
  return findings;
}
