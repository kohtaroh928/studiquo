import { execFileSync } from 'node:child_process';
import { CARD_PREFIX, validateOp, type CardOp, type ExistingCard } from './cards.ts';

// GitHub Project「Studiquo タスク」(owner kohtaroh928、番号 1)を gh project で読み書きする。
// シェルを通さず(execFileSync)、書く値は cards.ts の validateOp を通ったものだけ。

export const OWNER = 'kohtaroh928';
export const NUMBER = '1';

export type Gh = (args: string[]) => string;
export const realGh: Gh = (args) => execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 120_000 });

const SINGLE_SELECT = ['状態', '作業の種類', '重要度', '領域', '担当'] as const;

/** gh の --format json は日本語のフィールド名の先頭を壊すので、キーは末尾で照合する。 */
const byKeySuffix = (item: Record<string, unknown>, suffix: string) => {
  const k = Object.keys(item).find((x) => x.endsWith(suffix));
  return k && typeof item[k] === 'string' ? (item[k] as string) : null;
};

/** gh project item-list の出力から、[脆弱性]の項目だけを取り出す(形が合わないものも title 付きで残し、cards.ts が数える)。 */
export function parseProjectItems(raw: unknown): Record<string, unknown>[] {
  const items = (raw as { items?: unknown })?.items;
  const out: Record<string, unknown>[] = [];
  for (const it of Array.isArray(items) ? (items as Record<string, unknown>[]) : []) {
    const c = (it.content ?? {}) as Record<string, unknown>;
    const title = typeof it.title === 'string' ? it.title : typeof c.title === 'string' ? c.title : null;
    if (!title || !title.normalize('NFKC').trim().startsWith(CARD_PREFIX.trim())) continue;
    out.push({
      title,
      itemId: it.id,
      draftId: c.type === 'DraftIssue' ? c.id : null,
      status: byKeySuffix(it, '態'),
      importance: byKeySuffix(it, '要度'),
    });
  }
  return out;
}

export function fetchExisting(gh: Gh = realGh) {
  return parseProjectItems(JSON.parse(gh(['project', 'item-list', NUMBER, '--owner', OWNER, '--format', 'json', '--limit', '2000'])));
}

interface Schema { projectId: string; fields: Map<string, { id: string; options: Map<string, string> }> }

export function loadSchema(gh: Gh = realGh): Schema {
  const projectId = (JSON.parse(gh(['project', 'view', NUMBER, '--owner', OWNER, '--format', 'json'])) as { id: string }).id;
  const list = JSON.parse(gh(['project', 'field-list', NUMBER, '--owner', OWNER, '--format', 'json'])) as { fields: { id: string; name: string; options?: { id: string; name: string }[] }[] };
  const fields = new Map<string, { id: string; options: Map<string, string> }>();
  for (const f of list.fields) fields.set(f.name, { id: f.id, options: new Map((f.options ?? []).map((o) => [o.name, o.id])) });
  return { projectId, fields };
}

const setSelect = (gh: Gh, sc: Schema, itemId: string, field: string, value: string) => {
  const f = sc.fields.get(field);
  const opt = f?.options.get(value);
  if (!f || !opt) throw new Error(`フィールド「${field}」の選択肢「${value}」が見つからない`);
  gh(['project', 'item-edit', '--id', itemId, '--project-id', sc.projectId, '--field-id', f.id, '--single-select-option-id', opt]);
};

const bodyOf = (next: string, history: string) => `## 次の一手\n${next}\n\n## 経緯・結果\n${history}`;

export interface ApplyResult { created: number; updated: number; commented: number; failed: number; errors: string[] }

/** 検証を通った操作だけを順に実行する。1件が失敗しても残りは続ける。 */
export function applyOps(ops: CardOp[], gh: Gh = realGh): ApplyResult {
  const r: ApplyResult = { created: 0, updated: 0, commented: 0, failed: 0, errors: [] };
  if (!ops.length) return r;
  const sc = loadSchema(gh);
  let bodies: Map<string, string> | null = null;
  for (const op of ops) {
    try {
      const problem = validateOp(op);
      if (problem) throw new Error(`検証で不採用: ${problem}`);
      const p = (op.properties ?? {}) as Record<string, string>;
      if (op.op === 'create') {
        const made = JSON.parse(gh(['project', 'item-create', NUMBER, '--owner', OWNER, '--title', p.名前, '--body', bodyOf(p.次の一手, p['経緯・結果']), '--format', 'json'])) as { id: string };
        if (!made.id) throw new Error('作成した項目のIDが返らない');
        for (const k of SINGLE_SELECT) if (p[k]) setSelect(gh, sc, made.id, k, p[k]);
        const link = sc.fields.get('リンク');
        if (link) gh(['project', 'item-edit', '--id', made.id, '--project-id', sc.projectId, '--field-id', link.id, '--text', p.リンク]);
        r.created++;
      } else if (op.op === 'update') {
        for (const k of Object.keys(p)) setSelect(gh, sc, op.itemId!, k, p[k]);
        r.updated++;
      } else if (op.op === 'comment') {
        // ドラフト項目にはコメントが無いので、本文の末尾に定型の1行を足す(最新の本文を取り直してから)
        bodies ??= new Map(allBodies(gh));
        const cur = bodies.get(op.draftId!);
        if (cur === undefined) throw new Error('追記先の項目の本文を取得できない');
        const next = `${cur.trimEnd()}\n${op.text}`;
        gh(['project', 'item-edit', '--id', op.draftId!, '--body', next]);
        bodies.set(op.draftId!, next);
        r.commented++;
      }
    } catch (e) {
      r.failed++;
      r.errors.push(`${op.op}: ${String((e as Error).message).slice(0, 120)}`);
    }
  }
  return r;
}

function allBodies(gh: Gh): [string, string][] {
  const raw = JSON.parse(gh(['project', 'item-list', NUMBER, '--owner', OWNER, '--format', 'json', '--limit', '2000'])) as { items?: { content?: { id?: string; type?: string; body?: string } }[] };
  return (raw.items ?? []).filter((i) => i.content?.type === 'DraftIssue' && i.content.id).map((i) => [i.content!.id!, i.content!.body ?? '']);
}
