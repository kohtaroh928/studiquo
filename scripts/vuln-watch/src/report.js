// Markdownレポート。外部の文章(脆弱性の説明)はそのまま出すが、命令として扱わないよう整形だけする。

import { TIERS } from './score.js';

const EXPOSURE = { server: 'サーバー(Workerに同梱)', app: 'アプリ(iPadに同梱)', tooling: '開発ツールのみ' };

const clean = (s, n = 200) => String(s ?? '').replace(/[\r\n]+/g, ' ').replace(/[<>`|]/g, '').trim().slice(0, n);

function item(f) {
  const id = f.cve ?? f.ids[0];
  const lines = [`### ${id} — ${f.asset}`];
  lines.push(`- 優先度: **${f.tier}**(スコア ${f.score}/100)${f.status === 'needs-review' ? ' / 該当は未確定(要確認)' : ''}`);
  lines.push(`- 概要: ${clean(f.summary) || '(説明なし)'}`);
  const bits = [f.cvss === null ? 'CVSS: 不明' : `CVSS ${f.cvss}(${f.cvssSource})`];
  if (f.epss !== null) bits.push(`EPSS ${(f.epss * 100).toFixed(1)}%`);
  if (f.kev) bits.push(`**CISA KEV掲載**${f.kev.dueDate ? `(対応期限 ${f.kev.dueDate})` : ''}`);
  lines.push(`- 根拠: ${bits.join(' / ')}`);
  lines.push(`- 影響範囲: ${EXPOSURE[f.exposure] ?? f.exposure}${f.sensitive ? ' / 認証・課金・個人情報に関わる依存' : ''}${f.usage ? ` / 用途: ${clean(f.usage, 80)}` : ''}`);
  lines.push(`- 対応: ${f.fixed ? `修正版 ${f.fixed.join(', ')} へ更新` : '修正版の情報なし(回避策・影響範囲の確認が必要)'}`);
  // OSVのaliasにはBIT-などディストリ別の別名が大量に付くので、CVE・GHSAだけ出す
  const shown = f.ids.filter((x) => /^(CVE|GHSA|JVNDB)-/.test(x));
  lines.push(`- 出典: ${f.sources.join(', ')} / ID: ${(shown.length ? shown : f.ids.slice(0, 3)).join(', ')}`);
  if (f.references.length) lines.push(`- 参照: ${f.references.slice(0, 3).join(' , ')}`);
  return lines.join('\n');
}

export function renderReport({ ranked, inventory, unmatchable = [], warnings = [], sourceErrors = [], generatedAt }) {
  const count = Object.fromEntries(TIERS.map((t) => [t, ranked.filter((f) => f.tier === t).length]));
  const out = [`# 脆弱性監視レポート`, ''];
  out.push(`- 生成: ${generatedAt}`);
  out.push(`- 監視対象: ${inventory.length}件(npm ${inventory.filter((a) => a.ecosystem === 'npm').length} / Swift ${inventory.filter((a) => a.ecosystem === 'SwiftURL').length})`);
  out.push(`- 検出: ${TIERS.map((t) => `${t} ${count[t]}`).join(' / ')}`);
  out.push('- 範囲: NVD・OSV・CISA KEV・EPSS(JVNは未対応)。ライブラリのみ。');
  if (sourceErrors.length) out.push('', '> **取得に失敗したデータ源があります。この結果は不完全です。**', ...sourceErrors.map((e) => `> - ${clean(e, 300)}`));
  if (warnings.length) out.push('', ...warnings.map((w) => `> ${clean(w, 300)}`));
  out.push('');

  for (const tier of TIERS.slice(0, 3)) {
    const list = ranked.filter((f) => f.tier === tier);
    out.push(`## ${tier}(${list.length}件)`, '');
    out.push(list.length ? list.map(item).join('\n\n') : '該当なし。', '');
  }

  const info = ranked.filter((f) => f.tier === '情報');
  out.push(`## 情報(${info.length}件)`, '');
  if (info.length) {
    out.push('| ID | 対象 | CVSS | 備考 |', '|---|---|---|---|');
    for (const f of info) out.push(`| ${f.cve ?? f.ids[0]} | ${f.asset} | ${f.cvss ?? '-'} | ${f.status === 'needs-review' ? '要確認' : clean(f.summary, 60)} |`);
  } else out.push('該当なし。');
  out.push('');

  if (unmatchable.length) {
    out.push('## 照合できなかった対象', '', '版が固定されていない(リビジョン指定など)ため、版による照合ができません。手動での確認が必要です。', '');
    for (const a of unmatchable) out.push(`- ${a.ecosystem}:${a.name}${a.revision ? ` (revision ${a.revision.slice(0, 10)})` : ''}`);
    out.push('');
  }
  return out.join('\n');
}
