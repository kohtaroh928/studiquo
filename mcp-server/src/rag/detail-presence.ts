// Two narrow checks that the selected excerpts can answer what the question
// actually asks for. A matching topic is not enough: "the pass rate of X"
// needs a rate, and a question about a term the library never mentions has no
// evidence at all. Neither check judges truth or completeness, and both only
// ever remove references, never add them. Nothing here reads titles or metadata.
const NUMBER = '[\\d〇零一二三四五六七八九十百千万]';
const amount = (unit: string) => new RegExp(`${NUMBER}[\\d.,]*\\s*${unit}`, 'u');

// "何%" and friends: what the question asks for, and the form that would answer it.
// Longer units come first in the list only for readability; every entry is tested.
const ASKED_UNITS: { ask: RegExp; have: RegExp }[] = [
  { ask: /何\s*(?:%|パーセント|割)/u, have: amount('(?:%|パーセント|割)') },
  { ask: /何\s*件(?![かも])/u, have: amount('件') },
  { ask: /何\s*(?:人|名)(?![かも])/u, have: amount('(?:人|名)') },
  { ask: /何\s*回(?![かも])/u, have: amount('回') },
  { ask: /何\s*(?:個|台|枚|本)(?![かも])/u, have: amount('(?:個|台|枚|本)') },
  { ask: /何\s*倍(?![かも])/u, have: amount('倍') },
  { ask: /何\s*年(?![かも])/u, have: amount('年') },
  { ask: /何\s*日(?![かも])/u, have: amount('日') },
  { ask: /何\s*時間(?![かも])/u, have: amount('時間') },
  { ask: /何\s*分(?![かも])/u, have: amount('分') },
  { ask: /何\s*秒(?![かも])/u, have: amount('秒') },
  { ask: /何\s*歳(?![かも])/u, have: amount('歳') },
  // Degrees: temperature signs are written several ways in extracted text.
  { ask: /何\s*度(?![かも])/u, have: new RegExp(`${NUMBER}[\\d.,]*\\s*(?:度|°|˚|\\u030a)`, 'u') },
  { ask: /何\s*(?:hpa|ヘクトパスカル)/iu, have: amount('(?:hpa|ヘクトパスカル)') },
  { ask: /何\s*m\s*\/\s*s/iu, have: amount('m\\s*\\/\\s*s') },
  { ask: /何\s*km(?![a-z])/iu, have: amount('km(?![a-z])') },
  { ask: /何\s*(?:kt|ノット)/iu, have: amount('(?:kt|ノット)') },
  { ask: /何\s*kg/iu, have: amount('kg') },
  { ask: /何\s*cm/iu, have: amount('cm') },
  { ask: /何\s*mm/iu, have: amount('mm') },
  { ask: /何\s*m(?![a-z\/])/iu, have: amount('m(?![a-z\\/])') },
];
// No unit named: any number in the excerpts is the weakest sign that a quantity is given.
const ASKED_QUANTITY = /いくつ|どれ(?:くらい|ぐらい|ほど|だけ)|どの(?:くらい|ぐらい)/u;
const ANY_NUMBER = new RegExp(NUMBER, 'u');

const fold = (text: unknown) => String(text).normalize('NFKC').toLowerCase();

// Does the evidence contain the kind of number the question asks for?
// Several asked units are alternatives: one matching unit is enough.
export function quantityEvidencePresent(query: unknown, evidence: unknown) {
  const ask = fold(query);
  const text = fold(evidence);
  const asked = ASKED_UNITS.filter(u => u.ask.test(ask));
  if (asked.length) return asked.some(u => u.have.test(text));
  if (ASKED_QUANTITY.test(ask)) return ANY_NUMBER.test(text);
  return true;
}

// Loanwords that are often swapped for a synonym; their absence proves nothing.
const GENERIC_KATAKANA = new Set([
  'メカニズム', 'プロセス', 'イメージ', 'ポイント', 'パターン', 'タイプ', 'ケース', 'モデル', 'システム',
  'データ', 'ルール', 'レベル', 'テーマ', 'ヒント', 'サンプル', 'メリット', 'デメリット', 'ステップ',
  'フロー', 'コツ', 'ツール', 'アプリ', 'ページ', 'ノート', 'ファイル', 'フォルダ', 'ベース',
  'スケール', 'タイミング', 'バランス', 'シンプル', 'ベスト', 'ランキング', 'リスト', 'テスト',
]);
// A trailing long-vowel mark is optional in Japanese loanwords (コンピュータ / コンピューター).
const stem = (term: string) => term.replace(/ー+$/u, '');

// Katakana words long enough to be a specific subject (≥3 characters).
export function distinctiveTerms(query: unknown) {
  const found = String(query).normalize('NFKC').match(/[ァ-ヶー]{3,}/gu) ?? [];
  return [...new Set(found.filter(t => !GENERIC_KATAKANA.has(t) && stem(t).length >= 2))];
}

// Terms the question names that none of the given texts contains.
export function termsMissingFrom(query: unknown, texts: unknown[]) {
  const haystack = texts.map(fold).join('\n');
  return distinctiveTerms(query).filter(t => !haystack.includes(fold(stem(t))));
}

export const searchStem = stem;
