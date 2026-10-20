import type { Asset, RankedFinding, TriageItem } from '../src/types.ts';

// テストは、確かめたい項目だけを持つ最小の指摘・判定入力を作る。実行時は引数をそのまま返す。
export function partialRanked(parts: object): RankedFinding {
  return parts as unknown as RankedFinding;
}

export function partialItem(parts: object): TriageItem {
  return parts as unknown as TriageItem;
}

export function partialAsset<T extends object>(parts: T): Asset & T {
  return parts as unknown as Asset & T;
}

export function partialRankedList(parts: object[]): RankedFinding[] {
  return parts as unknown as RankedFinding[];
}
