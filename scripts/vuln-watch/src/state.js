// 前回の結果の記憶(git管理外)。レポートの「新規/継続」と、前回成功時刻を持つ。

import { existsSync, readFileSync, writeFileSync } from 'node:fs';

export function loadState(path) {
  try {
    if (existsSync(path)) {
      const s = JSON.parse(readFileSync(path, 'utf8'));
      return { lastSuccessAt: s.lastSuccessAt ?? null, reported: s.reported ?? {} };
    }
  } catch {
    // 壊れていたら無かったことにする(全件が「新規」になるだけ)
  }
  return { lastSuccessAt: null, reported: {} };
}

export function markNew(findings, state) {
  return findings.map((f) => ({ ...f, isNew: !(f.id in state.reported) }));
}

/** 取得に失敗したデータ源が無かったときだけ保存する(不完全な結果で「報告済み」にしない)。 */
export function saveState(path, findings, now, previous) {
  const reported = {};
  for (const f of findings) reported[f.id] = previous.reported[f.id] ?? { firstSeenAt: now };
  writeFileSync(path, JSON.stringify({ lastSuccessAt: now, reported }, null, 2) + '\n');
}
