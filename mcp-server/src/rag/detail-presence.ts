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
  // Money: any scale answers a question about money (5826億円 answers 何万円), so the scale is optional on both sides.
  { ask: /何\s*(?:[億万千兆])?\s*(?:円|ドル)(?![かも])/u, have: amount('(?:[億万千兆])?\\s*(?:円|ドル)') },
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

export type Excerpt = { text: string; primary?: boolean };

// Words that are unit names, not what the question is about.
const UNIT_WORDS = new Set(['hpa', 'kt', 'knot', 'km', 'kg', 'cm', 'mm']);

// Words that are not about the subject of a question even when written in Latin letters.
const GENERIC_LATIN = new Set(['the', 'and', 'for', 'how', 'what', 'why', 'url', 'http', 'https', 'www', 'com', 'pdf', 'html', 'faq']);

// Latin-letter words of 3+ letters (product names, programs, places). Lowercased: case never matters.
// Only the letters count: a model number such as "ABC12.3" is written with or without a space
// ("ABC 12.3") and must not be missed for that.
export function distinctiveLatinTerms(query: unknown) {
  const found = fold(query).match(/[a-z]{3,}/gu) ?? [];
  return [...new Set(found.filter(t => !UNIT_WORDS.has(t) && !GENERIC_LATIN.has(t)))];
}

// Latin and katakana words that name what the question is about (a storm, a person, a device).
function subjectTokens(query: unknown) {
  return [...new Set([...distinctiveLatinTerms(query), ...distinctiveTerms(query).map(t => fold(stem(t)))])];
}

// Does the evidence contain the kind of number the question asks for?
// Several asked units are alternatives: one matching unit is enough.
// `tied` also requires that number to sit in the top-ranked excerpt or in an excerpt that
// names the question's subject, so a unit on an unrelated page cannot stand in for the answer.
// Pass a plain string, or excerpts in rank order with the first marked `primary`.
export function quantityEvidencePresent(query: unknown, evidence: string | Excerpt[], options: { tied?: boolean } = {}) {
  const ask = fold(query);
  const excerpts: Excerpt[] = typeof evidence === 'string' ? [{ text: evidence, primary: true }] : evidence;
  const folded = excerpts.map(e => ({ text: fold(e.text), primary: !!e.primary }));
  const asked = ASKED_UNITS.filter(u => u.ask.test(ask));
  if (asked.length) {
    const carrying = folded.filter(e => asked.some(u => u.have.test(e.text)));
    if (!carrying.length) return false;
    if (!options.tied) return true;
    const subjects = subjectTokens(query);
    return carrying.some(e => e.primary || subjects.some(t => e.text.includes(t)));
  }
  if (ASKED_QUANTITY.test(ask)) return folded.some(e => ANY_NUMBER.test(e.text));
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

// Katakana and Latin-letter terms the question names that none of the given texts contains.
export function termsMissingFrom(query: unknown, texts: unknown[]) {
  const haystack = texts.map(fold).join('\n');
  const katakana = distinctiveTerms(query).filter(t => !haystack.includes(fold(stem(t))));
  const latin = distinctiveLatinTerms(query).filter(t => !haystack.includes(t));
  return [...katakana, ...latin];
}

// The question with the given words removed, for judging how much of the rest the excerpts cover.
export function withoutTerms(query: unknown, terms: string[]) {
  return terms.reduce((q, t) => q.split(fold(t)).join(' ').split(t).join(' '), fold(query));
}

export const searchStem = stem;

// Which kind of word was missing, as a fixed log code: katakana words, Latin-letter words, or both.
export function missingTermsDetail(terms: string[]) {
  const katakana = terms.some(t => /[\u30A1-\u30F6\u30FC]/u.test(t));
  const latin = terms.some(t => /^[a-z]+$/u.test(t));
  return katakana && latin ? 'term_both' : latin ? 'term_latin' : 'term_katakana';
}
