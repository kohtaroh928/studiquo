import { searchTokens } from './chunking.ts';
import { identifierQuery } from './identifiers.ts';
import { RELEVANCE } from './limits.ts';

// Keep the real question unchanged: this cleanup is only for keyword/lexical search.
function searchableQuestion(text: any) {
  const informative = (prefix: any) => {
    const compact = prefix.replace(/\s/gu, '');
    return (compact.length >= 2 || /^[\p{Script=Han}]$/u.test(compact)) &&
      !/^(?:これ|それ|あれ|どれ|この|その|あの|この(?:現象|こと|もの)|その(?:現象|こと|もの))$/u.test(compact);
  };
  const ending = /^(.*\S)(?:の(?:名前|名称)|になる(?:しくみ|仕組み))(?:は|を)?[\s。？！?]*$/u.exec(text);
  if (ending && informative(ending[1])) return ending[1];
  const calculation = /^(.*\S)(?:どれほど|どのくらい|どれだけ)かを求める式(?:は|を)?[\s。？！?]*$/u.exec(text);
  if (calculation && informative(calculation[1])) return `${calculation[1]}求める式`;
  return text;
}

// Remove request wording, not subject terms. Keep bigrams for OCR tolerance and synonyms via vectors.
export function importantText(query: any) {
  return searchableQuestion(String(query).normalize('NFKC'))
    .replace(/(?:この|その|あの)(?:資料|ページ|内容)(?:に|で|の|を|は)?/gu, ' ')
    .replace(/(?:資料|ページ|内容)(?:に|で|の|を|は)/gu, ' ')
    .replace(/もっと詳しく(?=説明(?:してください|して)|教えて(?:ください)?|解説(?:してください|して)|ください|[\s。？！?]|$)/gu, ' ')
    .replace(/説明(?:してください|して|(?=[。？！?]|$))|教えて(?:ください)?|比較(?:してください|して|(?=[。？！?]|$))|詳しく|ください|どうして|どのように|どうやって|なぜ|どんな|どの|という|について|それぞれ|とは|ですか|なのか|です|ます/gu, ' ')
    .replace(/[。？！?「」『』]/gu, ' ').trim();
}
export function importantTokens(query: any) {
  const { rest, identities } = identifierQuery(importantText(query));
  return [...new Set([...searchTokens(rest), ...identities])].filter(t =>
    !new Set(['して','しく','いは','のは','には','から','とは','する','れる','いる','ある','ない','それ','これ','こと','もの']).has(t));
}
export function relevanceEvidence(candidate: any, query: any) {
  const wanted = importantTokens(query);
  const body = `${candidate.title ?? ''}\n${candidate.heading_context ?? ''}\n${candidate.text}`.normalize('NFKC').toLowerCase();
  const present = new Set([...searchTokens(body), ...identifierQuery(body).identities]);
  const overlap = wanted.length ? wanted.filter(t => present.has(t) || (/^[\p{Script=Han}]$/u.test(t) && body.includes(t))).length / wanted.length : 0;
  const score = Number.isFinite(candidate.vectorScore) ? candidate.vectorScore : null;
  // A named subject followed by a category (e.g. ルミナ草) must not be
  // replaced by another name in that category just because predicates match.
  // Limit this check to explicit mixed-script subjects, not general synonyms.
  const names = [...String(query).normalize('NFKC').matchAll(/([ァ-ヶー]{2,24})([\p{Script=Han}]{1,4})(?=の|は|が|を|と|について)/gu)];
  const local = `${candidate.heading_context ?? ''}\n${candidate.text}`.normalize('NFKC');
  const localNames = [...local.matchAll(/([ァ-ヶー]{2,24})([\p{Script=Han}]{1,4})(?=の|は|が|を|と|[。\s]|$)/gu)];
  const anchored = names.length === 0 || names.some(m => localNames.some(other => other[1] === m[1] && other[2] === m[2]));
  const conflicting = !anchored && names.some(m =>
    localNames.some(other => other[2] === m[2] && other[1] !== m[1]));
  // Initial multi-signal operating point, not a probability of factual correctness.
  // Validate/calibrate on independent Japanese/OCR/negative sets before enabling production.
  const accepted = !conflicting && ((anchored && overlap >= RELEVANCE.anchoredOverlap && (score === null || score >= RELEVANCE.anchoredScore)) ||
    (overlap >= RELEVANCE.looseOverlap && score !== null && score >= RELEVANCE.looseScore) ||
    (score !== null && score >= RELEVANCE.topRankScore && candidate.vectorRank <= RELEVANCE.topRank));
  return { accepted, lexicalCoverage: overlap, vectorScore: score };
}
