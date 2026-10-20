// Notionカードの計画(設計書 3.4・3.5)。
// カードに書くのは、このファイルが組み立てた定型文だけ。脆弱性の説明文・LLMの reason・外部のURLは入れない。
// 親セッションは、ここで作った操作リスト(cards-ops.json)を「そのまま転記する」だけにする。
// 計画した操作は validateOp で厳密に検証し、通らないものは出さない。

export const CARD_PREFIX = '[脆弱性] ';

const ID_PART = String.raw`(?:CVE-\d{4}-\d{4,}|GHSA(?:-[a-z0-9]{4}){3}|JVNDB-\d{4}-\d{4,})`;
// 版は「数字で始まる版番号」だけ。英字だけの断片や文章(ハイフンでつないだ命令など)を通さない
const VER_PART = String.raw`\d{1,6}(?:\.\d{1,6}){0,3}(?:[-+][0-9A-Za-z.]{1,16})?`;
const ASSET_PART = String.raw`(?:npm:(?:@[A-Za-z0-9][A-Za-z0-9._-]{0,40}/)?[A-Za-z0-9][A-Za-z0-9._-]{0,60}|SwiftURL:github\.com/[A-Za-z0-9][A-Za-z0-9._-]{0,40}/[A-Za-z0-9][A-Za-z0-9._-]{0,60})@${VER_PART}`;
const ID_RE = new RegExp(`^${ID_PART}$`);
const ASSET_RE = new RegExp(`^${ASSET_PART}$`);
const FIXED_RE = new RegExp(`^${VER_PART}$`);
const TITLE_RE = new RegExp(String.raw`^\[脆弱性\] (${ID_PART}) (${ASSET_PART})$`);
// Notionのカードは「末尾が32桁の16進のID」のURLに限る(題名のスラッグ・/p/・?pvs=数字は許す)。他のワークスペースのページや、IDの無いURLは通さない
const NOTION_URL_RE = /^https:\/\/(?:www\.|app\.)?notion\.(?:so|com)\/(?:p\/)?(?:[A-Za-z0-9_%-]{0,150}-)?([0-9a-f]{32})(?:\?pvs=\d{1,4})?$/;
const LINK_RE = /^(https:\/\/nvd\.nist\.gov\/vuln\/detail\/CVE-\d{4}-\d{4,}|https:\/\/github\.com\/advisories\/GHSA(?:-[a-z0-9]{4}){3}|https:\/\/jvndb\.jvn\.jp\/ja\/contents\/\d{4}\/JVNDB-\d{4}-\d{4,}\.html)$/;
// 制御文字に加え、行区切り・ゼロ幅・双方向制御の文字も通さない
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f\u2028\u2029\u200b-\u200f\u202a-\u202e\u2060-\u2064\ufeff]/;

const IMPORTANCE: Record<string, string> = { 緊急: '本番を止める', 高: '高', 中: '中' };
const IMPORTANCE_ORDER = ['低', '中', '高', '本番を止める'];
const AREA: Record<string, string> = { server: 'サーバー', app: 'アプリ', tooling: '全体' };
const APPLIC: Record<string, string> = { applies: '該当', likely: 'おそらく該当', unlikely: 'おそらく非該当', not_applicable: '非該当', unknown: '不明' };
const CONF: Record<string, string> = { high: '高', medium: '中', low: '低' };
const SOURCES = ['osv', 'nvd', 'jvn'];

const CREATE_ENUMS = {
  作業の種類: ['不具合', '確認作業'],
  重要度: ['本番を止める', '高', '中'],
  領域: ['サーバー', 'アプリ', '全体'],
  担当: ['Claude', 'あなた'],
  状態: ['未着手', 'あなた待ち'],
};
const CREATE_PROPS = new Set(['名前', '作業の種類', '重要度', '領域', '担当', '状態', '次の一手', '経緯・結果', 'リンク']);
const TEXT_LIMITS: Record<string, number> = { 名前: 260, 次の一手: 400, '経緯・結果': 800 };

export function primaryId(f: any) {
  return [f.cve, ...(f.ids ?? [])].find((x) => typeof x === 'string' && ID_RE.test(x)) ?? null;
}

export function canonicalUrl(id: any) {
  if (/^CVE-/.test(id)) return `https://nvd.nist.gov/vuln/detail/${id}`;
  if (/^GHSA-/.test(id)) return `https://github.com/advisories/${id}`;
  const m = /^JVNDB-(\d{4})-\d{4,}$/.exec(id);
  return m ? `https://jvndb.jvn.jp/ja/contents/${m[1]}/${id}.html` : null;
}

/** 緊急・高は全件、中は版まで確定したものだけ。情報は作らない。 */
export function eligible(f: any) {
  return f.tier === '緊急' || f.tier === '高' || (f.tier === '中' && f.status === 'confirmed');
}

export function cardTitle(f: any) {
  const id = primaryId(f);
  return id && typeof f.asset === 'string' && ASSET_RE.test(f.asset) ? `${CARD_PREFIX}${id} ${f.asset}` : null;
}

/** カードのURLから、Notionのページ ID(32桁の16進)を取り出す。形式に合わなければ null。 */
export function extractPageId(url: any) {
  return typeof url === 'string' ? (NOTION_URL_RE.exec(url)?.[1] ?? null) : null;
}

const normTitle = (t: any) => String(t).normalize('NFKC').trim();

function createOp(f: any, today: any) {
  const id = primaryId(f);
  const url = canonicalUrl(id);
  const pkg = f.asset.slice(0, f.asset.lastIndexOf('@'));
  const fixed = (Array.isArray(f.fixed) ? f.fixed : []).filter((v: any) => typeof v === 'string' && v.length <= 24 && FIXED_RE.test(v));
  const needsCheck = f.status === 'needs-review';
  const next = [
    needsCheck ? '該当するかを確認する。' : '',
    fixed.length ? `${pkg} を ${fixed[0]} 以上へ更新する。` : '影響範囲を確認し、回避策を検討する。',
    f.needsHuman ? 'KEV掲載のため、人の確認が必要。' : '',
  ].filter(Boolean).join('');
  const cvss = typeof f.cvss === 'number' ? String(f.cvss) : '不明';
  const epss = typeof f.epss === 'number' ? `${(f.epss * 100).toFixed(1)}%` : '不明';
  const llm = f.verdict ? `${APPLIC[f.verdict.applicability] ?? '不明'}(確度${CONF[f.verdict.confidence] ?? '低'})` : 'なし';
  const sources = (f.sources ?? []).filter((x: any) => SOURCES.includes(x)).join('・') || '不明';
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

const importanceRank = (v: any) => IMPORTANCE_ORDER.indexOf(v);

export const upText = (today: any, from: any, to: any) => `${today} 重要度を ${from}→${to} に上げた(区分または根拠の変化)。`;
export const goneText = (today: any) => `${today} 検出されなくなった。更新されたかを確認して完了にする。`;
const COMMENT_RE = /^\d{4}-\d{2}-\d{2} (重要度を (低|中|高|本番を止める)→(低|中|高|本番を止める) に上げた\(区分または根拠の変化\)。|検出されなくなった。更新されたかを確認して完了にする。)$/;

/** 操作を検証する。通らなければ理由の文字列、通れば null。 */
export function validateOp(op: any) {
  const str = (v: any, max: any) => typeof v === 'string' && v.length > 0 && v.length <= max && !CONTROL_RE.test(v);
  if (op?.op === 'create') {
    const p = op.properties;
    if (!p || typeof p !== 'object') return 'properties が無い';
    for (const k of Object.keys(p)) if (!CREATE_PROPS.has(k)) return `許可していないプロパティ: ${k}`;
    const title = TITLE_RE.exec(str(p.名前, TEXT_LIMITS.名前) ? p.名前 : '');
    if (!title) return '名前の形式が違う';
    for (const [k, allowed] of Object.entries(CREATE_ENUMS)) if (!allowed.includes(p[k])) return `${k} が選択肢に無い`;
    for (const k of ['次の一手', '経緯・結果']) if (!str(p[k], TEXT_LIMITS[k])) return `${k} の形式が違う`;
    if (!LINK_RE.test(p.リンク ?? '')) return 'リンクが許可した形式ではない';
    if (p.リンク !== canonicalUrl(title[1])) return 'リンクが名前のIDと一致しない'; // 題名のIDと、リンクのIDが同じであること
    const fixedText = /^(該当するかを確認する。)?(?:(?:\S{1,120}) を (\d[0-9A-Za-z.+-]{0,23}) 以上へ更新する。|影響範囲を確認し、回避策を検討する。)(KEV掲載のため、人の確認が必要。)?$/;
    if (!fixedText.test(p.次の一手)) return '次の一手が定型文ではない';
    if (!/^\d{4}-\d{2}-\d{2} 検出。区分 (緊急|高|中)、スコア \d{1,3}、CVSS ([0-9.]{1,4}|不明)、KEV (有|無)、EPSS ([0-9.]{1,6}%|不明)。LLM判定 [^\s]{1,30}。出典 ([osvnjd・]{1,20}|不明)。 https:\/\/\S+$/.test(p['経緯・結果'])) return '経緯・結果が定型文ではない';
    return null;
  }
  if (op?.op === 'update' || op?.op === 'comment') {
    const id = extractPageId(op.url);
    if (!id) return 'カードのURLの形式が違う';
    if (op.pageId !== id) return 'pageId がURLと一致しない';
    if (op.op === 'comment') return str(op.text, 300) && COMMENT_RE.test(op.text) ? null : 'コメントが定型文ではない';
    const keys = Object.keys(op.properties ?? {});
    if (!keys.length) return '更新する項目が無い';
    for (const k of keys) {
      if (k === '重要度' && ['中', '高', '本番を止める'].includes(op.properties[k])) continue; // 下げる更新は認めない
      if (k === '状態' && op.properties[k] === '監視中') continue;
      return `許可していない更新: ${k}`;
    }
    return null;
  }
  return '操作の種類が不明';
}

/**
 * Notionから取得した既存カードを、題名・URL・状態・重要度だけに絞る。
 * 「[脆弱性]」で始まるのに形式が合わず捨てたものは dropped に数える(捨てたまま計画すると重複カードを作るため)。
 */
export function sanitizeExisting(raw: any) {
  const cards = [];
  let dropped = 0;
  for (const c of Array.isArray(raw) ? raw : []) {
    if (typeof c?.title !== 'string') continue;
    const title = normTitle(c.title);
    if (!title.startsWith(CARD_PREFIX.trim())) continue;
    if (title.length > 300 || CONTROL_RE.test(title) || !extractPageId(c.url)) {
      dropped++;
      continue;
    }
    cards.push({
      title,
      url: c.url,
      status: typeof c.status === 'string' ? c.status.slice(0, 20) : null,
      importance: typeof c.importance === 'string' ? c.importance.slice(0, 20) : null,
    });
  }
  return { cards, dropped };
}

/**
 * @param {{ranked:object[], existing:object[], today:string, incomplete:boolean, maxCreate?:number}} o
 * incomplete: 取得に失敗したデータ源がある回。「検出されなくなった」ことを根拠にカードを動かさない。
 */
export function planCards({ ranked, existing, today, incomplete, maxCreate = 10 }: any) {
  const { cards: list, dropped } = sanitizeExisting(existing);
  const cards = new Map();
  const notes = [];
  for (const c of list) {
    const prev = cards.get(c.title);
    if (!prev) cards.set(c.title, c);
    else {
      notes.push(`同じ題名のカードが複数ある: ${c.title}`);
      if (prev.status === '完了' && c.status !== '完了') cards.set(c.title, c); // 未完了の方を優先して見る
    }
  }
  // 取り込めなかった[脆弱性]のカードがあると、重複を判定できない。新規作成と「検出されなくなった」の判断は止める
  const blocked = dropped > 0;
  if (blocked) notes.push(`形式が合わず読み取れなかった[脆弱性]のカードが${dropped}件あるため、カードの新規作成と「検出されなくなった」の処理を止めた。`);

  const ops: any[] = [];
  const skipped = [];
  const push = (op: any, label: any) => {
    const problem = validateOp(op);
    if (problem) skipped.push({ target: label, reason: problem });
    else ops.push(op);
  };
  const withPage = (op: any, url: any) => ({ ...op, url, pageId: extractPageId(url) });

  const current = new Set();
  for (const f of Array.isArray(ranked) ? ranked : []) {
    try {
      const t = cardTitle(f);
      if (t) current.add(normTitle(t));
    } catch {
      // 型が違う指摘は、下のループで見送りにする
    }
  }

  const created = new Set();
  for (const f of Array.isArray(ranked) ? ranked : []) {
    try {
      if (!eligible(f)) continue;
      const title = cardTitle(f);
      if (!title) {
        skipped.push({ target: String(f.id ?? f.asset), reason: 'IDまたは資産名が定型に合わない' });
        continue;
      }
      const ex = cards.get(normTitle(title));
      if (!ex) {
        if (blocked) continue;
        if (created.has(title)) continue; // 同じ回に同じ題名の指摘が2件あっても、作るのは1枚
        if (created.size >= maxCreate) {
          skipped.push({ target: title, reason: `1回に作るカードの上限(${maxCreate}件)を超えた` });
          continue;
        }
        created.add(title);
        push(createOp(f, today), title);
      } else if (ex.status === '完了') {
        notes.push(`完了済みのカードがあるが再検出された: ${title}`);
      } else {
        if (ex.status === '監視中') notes.push(`監視中のカードが再検出された: ${title}`);
        const to = IMPORTANCE[f.tier];
        const from = ex.importance || '低';
        if (importanceRank(to) > importanceRank(from)) {
          push(withPage({ op: 'update', properties: { 重要度: to } }, ex.url), title);
          push(withPage({ op: 'comment', text: upText(today, from, to) }, ex.url), title);
        }
      }
    } catch (e) {
      skipped.push({ target: String(f?.id ?? '(不明)'), reason: `計画中に失敗: ${String((e as Error).message).slice(0, 80)}` });
    }
  }

  if (!incomplete && !blocked) {
    for (const ex of cards.values()) {
      if (!TITLE_RE.test(ex.title) || current.has(ex.title)) continue;
      if (ex.status !== '未着手' && ex.status !== '進行中') continue;
      push(withPage({ op: 'update', properties: { 状態: '監視中' } }, ex.url), ex.title);
      push(withPage({ op: 'comment', text: goneText(today) }, ex.url), ex.title);
    }
  } else if (incomplete) {
    notes.push('取得に失敗したデータ源があるため、検出されなくなったカードは動かしていない。');
  }

  const count = (k: any) => ops.filter((o) => o.op === k).length;
  return { ops, skipped, notes: [...new Set(notes)], counts: { create: count('create'), update: count('update'), comment: count('comment') } };
}

const int = (v: any) => (Number.isInteger(v) && v >= 0 && v <= 999 ? v : null);

// LLMが確度中以上で「非該当」と判定した「情報」止まりの指摘。消さず latest.md には残すが、
// 日次要約のカウントからは外す(ユーザー合意・2026-10-19)。要約から外れても判定自体は記録に残るため、
// 誤判定を見逃さないための「情報」の目的(設計書2.3)は latest.md の確認で引き続き担保する。
const judgedNotApplicable = (f: any) => f.tier === '情報' && f.verdict?.applicability === 'not_applicable' && f.verdict?.confidence !== 'low';

/** 実行の最後に返す、固定書式の要約と、通知の文言(無ければ null)。 */
export function buildSummary({ ranked, run, triage, plan, executed = {}, today, outDir }: any) {
  const tiers = ['緊急', '高', '中', '情報'];
  const visible = ranked.filter((f: any) => !judgedNotApplicable(f));
  const hidden = ranked.length - visible.length;
  const n = (t: any) => visible.filter((f: any) => f.tier === t).length;
  const fresh = visible.filter((f: any) => f.isNew).length;
  const urgentNew = ranked.filter((f: any) => f.isNew && (f.tier === '緊急' || f.kev)).length;
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
  if (hidden) lines.push(`判定済み・対象外(要約から除外): ${hidden}件 / latest.mdに記録`);
  for (const note of plan?.notes ?? []) lines.push(`注意: ${note}`);
  return { text: lines.join('\n'), notify: urgentNew ? `脆弱性監視: 緊急またはKEV掲載の新規 ${urgentNew}件。Notionのカードを確認してください` : null };
}
