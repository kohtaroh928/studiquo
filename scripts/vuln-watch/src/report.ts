// Markdownレポート。外部の文章(脆弱性の説明)はそのまま出すが、命令として扱わないよう整形だけする。

import { TIERS } from './score.ts';

const EXPOSURE: Record<string, string> = { server: 'サーバー(Workerに同梱)', app: 'アプリ(iPadに同梱)', tooling: '開発ツールのみ' };

const APPLIC: Record<string, string> = { applies: '該当', likely: 'おそらく該当', unlikely: 'おそらく非該当', not_applicable: '非該当', unknown: '不明' };
const CONF: Record<string, string> = { high: '高', medium: '中', low: '低' };
const ACT: Record<string, string> = { update: '更新する', workaround: '回避策を取る', monitor: '様子を見る', none: '対応不要' };

const clean = (s: any, n = 200) => String(s ?? '').replace(/[\r\n]+/g, ' ').replace(/[<>`|]/g, '').trim().slice(0, n);

function item(f: any) {
  const id = f.cve ?? f.ids[0];
  const lines = [`### ${id} — ${f.asset}${f.isNew === undefined ? '' : f.isNew ? ' 【新規】' : ' (継続)'}`];
  const lowered = f.tierBefore && f.tierBefore !== f.tier ? `(機械判定は${f.tierBefore}、LLM判定で1段階下げた)` : '';
  lines.push(`- 優先度: **${f.tier}**(スコア ${f.score}/100)${lowered}${f.status === 'needs-review' ? ' / 該当は未確定(要確認)' : ''}${f.needsHuman ? ' / **要人間確認**(KEV掲載のため、LLMが非該当としても区分を保っている)' : ''}`);
  lines.push(`- 概要: ${clean(f.summary) || '(説明なし)'}`);
  if (f.titleJa && f.titleJa !== f.summary) lines.push(`- 日本語題名(JVN): ${clean(f.titleJa)}`);
  const bits = [f.cvss === null ? 'CVSS: 不明' : `CVSS ${f.cvss}(${f.cvssSource})`];
  if (f.epss !== null) bits.push(`EPSS ${(f.epss * 100).toFixed(1)}%`);
  if (f.kev) bits.push(`**CISA KEV掲載**${f.kev.dueDate ? `(対応期限 ${f.kev.dueDate})` : ''}`);
  lines.push(`- 根拠: ${bits.join(' / ')}`);
  lines.push(`- 影響範囲: ${EXPOSURE[f.exposure] ?? f.exposure}${f.sensitive ? ' / 認証・課金・個人情報に関わる依存' : ''}${f.usage ? ` / 用途: ${clean(f.usage, 80)}` : ''}`);
  lines.push(`- 対応: ${f.fixed ? `修正版 ${f.fixed.join(', ')} へ更新` : '修正版の情報なし(回避策・影響範囲の確認が必要)'}`);
  // OSVのaliasにはBIT-などディストリ別の別名が大量に付くので、CVE・GHSAだけ出す
  const shown = f.ids.filter((x: any) => /^(CVE|GHSA|JVNDB)-/.test(x));
  lines.push(`- 出典: ${f.sources.join(', ')} / ID: ${(shown.length ? shown : f.ids.slice(0, 3)).join(', ')}`);
  if (f.verdict) {
    const v = f.verdict;
    lines.push(`- LLM判定: **${APPLIC[v.applicability]}**(確度 ${CONF[v.confidence]}) / 推奨: ${ACT[v.action]}`);
    lines.push(`  - 理由: ${clean(v.reason, 300)}`);
    if (v.evidence.length) lines.push(`  - 根拠: ${v.evidence.map((e: any) => `${e.type}:${clean(e.ref, 120)}`).join(' , ')}`);
    if (v.unverifiedEvidence) lines.push(`  - 検証できなかった根拠: ${v.unverifiedEvidence}件(採用していない)`);
  }
  if (f.references.length) lines.push(`- 参照: ${f.references.slice(0, 3).join(' , ')}`);
  return lines.join('\n');
}

export function renderReport({ ranked, inventory, unmatchable = [], warnings = [], sourceErrors = [], generatedAt, triage = null }: any) {
  const count = Object.fromEntries(TIERS.map((t) => [t, ranked.filter((f: any) => f.tier === t).length]));
  const out = [`# 脆弱性監視レポート`, ''];
  out.push(`- 生成: ${generatedAt}`);
  out.push(`- 監視対象: ${inventory.length}件(npm ${inventory.filter((a: any) => a.ecosystem === 'npm').length} / Swift ${inventory.filter((a: any) => a.ecosystem === 'SwiftURL').length})`);
  out.push(`- 検出: ${TIERS.map((t) => `${t} ${count[t]}`).join(' / ')}`);
  out.push('- 範囲: NVD・OSV・JVN iPedia・CISA KEV・EPSS。ライブラリのみ。');
  if (triage?.status === 'applied') out.push(`- LLM判定: 判定対象${triage.total ?? '?'}件のうち${triage.accepted}件に判定が返り、反映${triage.rejected.length ? `(検証で採用しなかった判定 ${triage.rejected.length}件、末尾に一覧)` : ''}`);
  else if (triage?.status === 'idle') out.push('- LLM判定: 判定に回す指摘はありません。');
  else out.push('- **LLM判定なし**: 区分は機械判定のみです。「要確認」の指摘は未判定のままです。');
  if (triage?.redactions) out.push(`- **判定の理由に鍵やトークンらしい文字列が${triage.redactions}件含まれていたため、伏せ字にしました。** エージェントが秘密のファイルを読んだ可能性があります。`);
  if (sourceErrors.length) out.push('', '> **取得に失敗したデータ源があります。この結果は不完全です。**', ...sourceErrors.map((e: any) => `> - ${clean(e, 300)}`));
  if (warnings.length) out.push('', ...warnings.map((w: any) => `> ${clean(w, 300)}`));
  out.push('');

  for (const tier of TIERS.slice(0, 3)) {
    const list = ranked.filter((f: any) => f.tier === tier);
    out.push(`## ${tier}(${list.length}件)`, '');
    out.push(list.length ? list.map(item).join('\n\n') : '該当なし。', '');
  }

  const info = ranked.filter((f: any) => f.tier === '情報');
  out.push(`## 情報(${info.length}件)`, '');
  if (info.length) {
    out.push('| ID | 対象 | CVSS | 備考 |', '|---|---|---|---|');
    for (const f of info) out.push(`| ${f.cve ?? f.ids[0]} | ${f.asset} | ${f.cvss ?? '-'} | ${f.status === 'needs-review' ? '要確認' : clean(f.summary, 60)} |`);
  } else out.push('該当なし。');
  out.push('');

  if (triage?.rejected?.length) {
    out.push('## 採用しなかったLLM判定', '', '検証規則(設計書 2.3)に合わなかったもの。区分は機械判定のままです。', '');
    for (const r of triage.rejected) out.push(`- ${clean(r.id, 40)}: ${clean(r.reason, 120)}`);
    out.push('');
  }

  if (unmatchable.length) {
    out.push('## 照合できなかった対象', '', '版が固定されていない(リビジョン指定など)ため、版による照合ができません。手動での確認が必要です。', '');
    for (const a of unmatchable) out.push(`- ${a.ecosystem}:${a.name}${a.revision ? ` (revision ${a.revision.slice(0, 10)})` : ''}`);
    out.push('');
  }
  return out.join('\n');
}
