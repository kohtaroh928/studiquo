// 前回の結果の記憶(git管理外)。
//   - reported: レポートの「新規/継続」の印に使う、報告済みの指摘ID
//   - lastSuccessAt: 前回、取得に失敗したデータ源が無かった時刻
//   - verdicts: LLM判定のキャッシュ(設計書 3.6)。入力のハッシュが同じで7日以内なら、エージェントを呼ばずに再利用する

import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';

const DAY = 86_400_000;

export function loadState(path: any) {
  try {
    if (existsSync(path)) {
      const s = JSON.parse(readFileSync(path, 'utf8'));
      return { lastSuccessAt: s.lastSuccessAt ?? null, reported: s.reported ?? {}, verdicts: s.verdicts ?? {} };
    }
  } catch {
    // 壊れていたら無かったことにする(全件が「新規」になり、判定のやり直しになるだけ)
  }
  return { lastSuccessAt: null, reported: {}, verdicts: {} };
}

// 同時に読まれても途中の内容を見せないよう、一時ファイルに書いてから置き換える
const write = (path: any, state: any) => {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
  renameSync(tmp, path);
};

export function markNew(findings: any, state: any) {
  return findings.map((f: any) => ({ ...f, isNew: !(f.id in state.reported) }));
}

/** 取得に失敗したデータ源が無かったときだけ保存する(不完全な結果で「報告済み」にしない)。 */
export function saveState(path: any, findings: any, now: any, previous: any) {
  const reported: Record<string, string> = {};
  for (const f of findings) reported[f.id] = previous.reported[f.id] ?? { firstSeenAt: now };
  write(path, { lastSuccessAt: now, reported, verdicts: previous.verdicts ?? {} });
}

/** 前回の成功から days 日以上空いていたら警告文を返す。一度も成功していなければ null(初回)。 */
export function gapWarning(state: any, now: any, days = 3) {
  if (!state.lastSuccessAt) return null;
  const gap = (now.getTime() - Date.parse(state.lastSuccessAt)) / DAY;
  return gap >= days ? `前回の成功から約${Math.floor(gap)}日あいています(Macが寝ていたか、アプリが閉じていた可能性があります)。` : null;
}

/** 毎週月曜はキャッシュを使わず、全件を判定し直す。 */
export function isFreshDay(now: any) {
  return now.getDay() === 1;
}

/** 判定に回す指摘(pending)と、キャッシュを使える指摘(cached)に分ける。 */
export function selectForJudgement(items: any, state: any, now: any, { fresh = false, ttlDays = 7 } = {}) {
  const pending = [];
  const cached = [];
  for (const item of items) {
    const c = state.verdicts[item.id];
    const usable = !fresh && c && c.hash === item.hash && now.getTime() - Date.parse(c.judgedAt) < ttlDays * DAY;
    if (usable) cached.push({ id: item.id, ...c.verdict });
    else pending.push(item);
  }
  return { pending, cached };
}

/** 新しく得た判定を保存する。現在の指摘に無いIDの判定は捨てる。 */
export function saveVerdicts(path: any, state: any, entries: any, liveIds: any, now: any, dropIds = []) {
  const live = new Set(liveIds);
  for (const id of dropIds) live.delete(id); // 検証で落ちたキャッシュは捨てる
  const verdicts: Record<string, unknown> = {};
  for (const [id, v] of Object.entries(state.verdicts)) if (live.has(id)) verdicts[id] = v;
  for (const { id, hash, verdict } of entries) verdicts[id] = { hash, verdict, judgedAt: now };
  write(path, { lastSuccessAt: state.lastSuccessAt, reported: state.reported, verdicts });
}
