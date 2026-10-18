// Notionカードの計画(設計書 3.4・3.5)。
// カードに書くのは、このファイルが組み立てた定型文だけ。脆弱性の説明文・LLMの reason・外部のURLは入れない。
// 親セッションは、ここで作った操作リスト(cards-ops.json)を「そのまま転記する」だけにする。
// 計画した操作は validateOp で厳密に検証し、通らないものは出さない。

export const CARD_PREFIX = '[脆弱性] ';

const ID_RE = /^(CVE-\d{4}-\d{4,}|GHSA(-[a-z0-9]{4}){3}|JVNDB-\d{4}-\d{4,})$/;
const ASSET_RE = /^(npm|SwiftURL):[A-Za-z0-9@._/+-]{1,120}@[0-9A-Za-z.+-]{1,40}$/;
const VERSION_RE = /^[0-9A-Za-z.+-]{1,40}$/;
const TITLE_RE = /^\[脆弱性\] (CVE-\d{4}-\d{4,}|GHSA(-[a-z0-9]{4}){3}|JVNDB-\d{4}-\d{4,}) \S{1,200}$/;
const NOTION_URL_RE = /^https:\/\/(www\.|app\.)?notion\.(so|com)\/[A-Za-z0-9/_-]{8,200}(\?[A-Za-z0-9=&_-]{0,100})?$/;
const LINK_RE = /^(https:\/\/nvd\.nist\.gov\/vuln\/detail\/CVE-\d{4}-\d{4,}|https:\/\/github\.com\/advisories\/GHSA(-[a-z0-9]{4}){3}|https:\/\/jvndb\.jvn\.jp\/ja\/contents\/\d{4}\/JVNDB-\d{4}-\d{4,}\.html)$/;
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

const IMPORTANCE = { 緊急: '本番を止める', 高: '高', 中: '中' };
const IMPORTANCE_ORDER = ['低', '中', '高', '本番を止める'];
const AREA = { server: 'サーバー', app: 'アプリ', tooling: '全体' };
const APPLIC = { applies: '該当', likely: 'おそらく該当', unlikely: 'おそらく非該当', not_applicable: '非該当', unknown: '不明' };
const CONF = { high: '高', medium: '中', low: '低' };
const SOURCES = ['osv', 'nvd', 'jvn'];

const CREATE_ENUMS = {
  作業の種類: ['不具合', '確認作業'],
  重要度: ['本番を止める', '高', '中'],
  領域: ['サーバー', 'アプリ', '全体'],
  担当: ['Claude', 'あなた'],
  状態: ['未着手', 'あなた待ち'],
};
const CREATE_PROPS = new Set(['名前', '作業の種類', '重要度', '領域', '担当', '状態', '次の一手', '経緯・結果', 'リンク']);
const TEXT_LIMITS = { 名前: 260, 次の一手: 400, '経緯・結果': 800 };

export function primaryId(f) {
  return [f.cve, ...(f.ids ?? [])].find((x) => typeof x === 'string' && ID_RE.test(x)) ?? null;
}

export function canonicalUrl(id) {
  if (/^CVE-/.test(id)) return `https://nvd.nist.gov/vuln/detail/${id}`;
  if (/^GHSA-/.test(id)) return `https://github.com/advisories/${id}`;
  const m = /^JVNDB-(\d{4})-\d{4,}$/.exec(id);
  return m ? `https://jvndb.jvn.jp/ja/contents/${m[1]}/${id}.html` : null;
}

/** 緊急・高は全件、中は版まで確定したものだけ。情報は作らない。 */
export function eligible(f) {
  return f.tier === '緊急' || f.tier === '高' || (f.tier === '中' && f.status === 'confirmed');
}

export function cardTitle(f) {
  const id = primaryId(f);
  return id && ASSET_RE.test(f.asset) ? `${CARD_PREFIX}${id} ${f.asset}` : null;
}

function createOp(f, today) {
  const id = primaryId(f);
  const url = canonicalUrl(id);
  const pkg = f.asset.slice(0, f.asset.lastIndexOf('@'));
  const fixed = (Array.isArray(f.fixed) ? f.fixed : []).filter((v) => typeof v === 'string' && VERSION_RE.test(v));
  const needsCheck = f.status === 'needs-review';
  const next = [
    needsCheck ? '該当するかを確認する。' : '',
    fixed.length ? `${pkg} を ${fixed[0]} 以上へ更新する。` : '影響範囲を確認し、回避策を検討する。',
    f.needsHuman ? 'KEV掲載のため、人の確認が必要。' : '',
  ].filter(Boolean).join('');
  const cvss = typeof f.cvss === 'number' ? String(f.cvss) : '不明';
  const epss = typeof f.epss === 'number' ? `${(f.epss * 100).toFixed(1)}%` : '不明';
  const llm = f.verdict ? `${APPLIC[f.verdict.applicability] ?? '不明'}(確度${CONF[f.verdict.confidence] ?? '低'})` : 'なし';
  const sources = (f.sources ?? []).filter((x) => SOURCES.includes(x)).join('・') || '不明';
  const history = `${today} 検出。区分 ${f.tier}、スコア ${Number(f.score)}、CVSS ${cvss}、KEV ${f.kev ? '有' : '無'}、EPSS ${epss}。LLM判定 ${llm}。出典 ${sources}。 ${url}`;
  return {
    op: 'create',
    properties: {
      名前: cardTitle(f),
      作業の種類: needsCheck ? '確認作業' : '不具合',
      重要度: IMPORTANCE[f.tier],
      領域: AREA[f.exposure] ?? '全体',
      担当: f.needsHuman ? 'あなた' : 'Claude',
      状態: f.needsHuman ? 'あなた待ち' : '未着手',
      次の一手: next,
      '経緯・結果': history,
      リンク: url,
    },
  };
}

const importanceRank = (v) => IMPORTANCE_ORDER.indexOf(v);

export const upText = (today, from, to) => `${today} 重要度を ${from}→${to} に上げた(区分または根拠の変化)。`;
export const goneText = (today) => `${today} 検出されなくなった。更新されたかを確認して完了にする。`;
const COMMENT_RE = /^\d{4}-\d{2}-\d{2} (重要度を (低|中|高|本番を止める)→(低|中|高|本番を止める) に上げた\(区分または根拠の変化\)。|検出されなくなった。更新されたかを確認して完了にする。)$/;

/** 操作を検証する。通らなければ理由の文字列、通れば null。 */
export function validateOp(op) {
  const str = (v, max) => typeof v === 'string' && v.length > 0 && v.length <= max && !CONTROL_RE.test(v);
  if (op?.op === 'create') {
    const p = op.properties;
    if (!p || typeof p !== 'object') return 'properties が無い';
    for (const k of Object.keys(p)) if (!CREATE_PROPS.has(k)) return `許可していないプロパティ: ${k}`;
    if (!str(p.名前, TEXT_LIMITS.名前) || !TITLE_RE.test(p.名前)) return '名前の形式が違う';
    for (const [k, allowed] of Object.entries(CREATE_ENUMS)) if (!allowed.includes(p[k])) return `${k} が選択肢に無い`;
    for (const k of ['次の一手', '経緯・結果']) if (!str(p[k], TEXT_LIMITS[k])) return `${k} の形式が違う`;
    if (!LINK_RE.test(p.リンク ?? '')) return 'リンクが許可した形式ではない';
    return null;
  }
  if (op?.op === 'update') {
    if (!NOTION_URL_RE.test(op.url ?? '')) return 'カードのURLの形式が違う';
    const keys = Object.keys(op.properties ?? {});
    if (!keys.length) return '更新する項目が無い';
    for (const k of keys) {
      if (k === '重要度' && ['中', '高', '本番を止める'].includes(op.properties[k])) continue; // 下げる更新は認めない
      if (k === '状態' && op.properties[k] === '監視中') continue;
      return `許可していない更新: ${k}`;
    }
    return null;
  }
  if (op?.op === 'comment') {
    if (!NOTION_URL_RE.test(op.url ?? '')) return 'カードのURLの形式が違う';
    return str(op.text, 300) && COMMENT_RE.test(op.text) ? null : 'コメントが定型文ではない';
  }
  return '操作の種類が不明';
}

/** Notionから取得した既存カードを、題名・URL・状態・重要度だけに絞る。 */
export function sanitizeExisting(raw) {
  const out = [];
  for (const c of Array.isArray(raw) ? raw : []) {
    if (typeof c?.title !== 'string' || !c.title.startsWith(CARD_PREFIX) || c.title.length > 300 || CONTROL_RE.test(c.title)) continue;
    if (!NOTION_URL_RE.test(c.url ?? '')) continue;
    out.push({
      title: c.title,
      url: c.url,
      status: typeof c.status === 'string' ? c.status.slice(0, 20) : null,
      importance: typeof c.importance === 'string' ? c.importance.slice(0, 20) : null,
    });
  }
  return out;
}

/**
 * @param {{ranked:object[], existing:object[], today:string, incomplete:boolean, maxCreate?:number}} o
 * incomplete: 取得に失敗したデータ源がある回。「検出されなくなった」ことを根拠にカードを動かさない。
 */
export function planCards({ ranked, existing, today, incomplete, maxCreate = 10 }) {
  const cards = new Map();
  for (const c of sanitizeExisting(existing)) if (!cards.has(c.title)) cards.set(c.title, c);

  const ops = [];
  const skipped = [];
  const notes = [];
  const push = (op, label) => {
    const problem = validateOp(op);
    if (problem) skipped.push({ target: label, reason: problem });
    else ops.push(op);
  };

  const current = new Set(ranked.map(cardTitle).filter(Boolean)); // 区分にかかわらず、今回検出されたもの
  let created = 0;
  for (const f of ranked) {
    if (!eligible(f)) continue;
    const title = cardTitle(f);
    if (!title) {
      skipped.push({ target: String(f.id ?? f.asset), reason: 'IDまたは資産名が定型に合わない' });
      continue;
    }
    const ex = cards.get(title);
    if (!ex) {
      if (created >= maxCreate) {
        skipped.push({ target: title, reason: `1回に作るカードの上限(${maxCreate}件)を超えた` });
        continue;
      }
      created++;
      push(createOp(f, today), title);
    } else if (ex.status === '完了') {
      notes.push(`完了済みのカードがあるが再検出された: ${title}`);
    } else {
      if (ex.status === '監視中') notes.push(`監視中のカードが再検出された: ${title}`);
      const to = IMPORTANCE[f.tier];
      if (importanceRank(to) > importanceRank(ex.importance)) {
        push({ op: 'update', url: ex.url, properties: { 重要度: to } }, title);
        push({ op: 'comment', url: ex.url, text: upText(today, ex.importance ?? '低', to) }, title);
      }
    }
  }

  if (!incomplete) {
    for (const ex of cards.values()) {
      if (!TITLE_RE.test(ex.title) || current.has(ex.title)) continue;
      if (ex.status !== '未着手' && ex.status !== '進行中') continue;
      push({ op: 'update', url: ex.url, properties: { 状態: '監視中' } }, ex.title);
      push({ op: 'comment', url: ex.url, text: goneText(today) }, ex.title);
    }
  } else {
    notes.push('取得に失敗したデータ源があるため、検出されなくなったカードは動かしていない。');
  }

  const count = (k) => ops.filter((o) => o.op === k).length;
  return { ops, skipped, notes, counts: { create: count('create'), update: count('update'), comment: count('comment') } };
}

const int = (v) => (Number.isInteger(v) && v >= 0 && v <= 999 ? v : null);

/** 実行の最後に返す、固定書式の要約と、通知の文言(無ければ null)。 */
export function buildSummary({ ranked, run, triage, plan, executed = {}, today, outDir }) {
  const tiers = ['緊急', '高', '中', '情報'];
  const n = (t) => ranked.filter((f) => f.tier === t).length;
  const fresh = ranked.filter((f) => f.isNew).length;
  const urgentNew = ranked.filter((f) => f.isNew && (f.tier === '緊急' || f.kev)).length;
  const errors = run.sourceErrors?.length ?? 0;
  const ex = Object.fromEntries(['created', 'updated', 'commented', 'failed'].map((k) => [k, int(executed[k])]));
  const lines = [
    `脆弱性監視 ${today}`,
    `検出: ${tiers.map((t) => `${t} ${n(t)}`).join(' / ')}(新規 ${fresh}件)`,
    `LLM判定: ${triage ? `${triage.status}(判定対象 ${triage.total ?? '-'}件、判定 ${triage.accepted ?? 0}件、採用しなかった ${triage.rejected?.length ?? 0}件)` : '未実施'}`,
    `カード計画: 作成 ${plan?.counts.create ?? 0} / 更新 ${plan?.counts.update ?? 0} / コメント ${plan?.counts.comment ?? 0} / 見送り ${plan?.skipped.length ?? 0}`,
    `カード実行: ${Object.values(ex).every((v) => v === null) ? '未報告' : `作成 ${ex.created ?? '-'} / 更新 ${ex.updated ?? '-'} / コメント ${ex.commented ?? '-'} / 失敗 ${ex.failed ?? '-'}`}`,
    `取得失敗: ${errors ? `${errors}件(結果は不完全)` : 'なし'}`,
    `レポート: ${outDir}/latest.md`,
  ];
  for (const note of plan?.notes ?? []) lines.push(`注意: ${note}`);
  return { text: lines.join('\n'), notify: urgentNew ? `脆弱性監視: 緊急またはKEV掲載の新規 ${urgentNew}件。Notionのカードを確認してください` : null };
}
