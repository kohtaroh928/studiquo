import { identifierAliases } from './identifiers.ts';
// Approximate multilingual tokens, preserving original punctuation and whitespace.
// A tokenizer approximation is intentional; model-specific token counts vary.
export function tokens(text: any) {
  return (
    text.match(
      /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|[\p{L}\p{N}]+|[^\p{L}\p{N}\s]|\s+/gu,
    ) ?? []
  );
}
export function tokenCount(text: any) {
  return tokens(text).filter((t: any) => !/^\s+$/.test(t)).length;
}
export function chunkPage(text: any, target = 400, overlap = 65) {
  const blocks = String(text)
    .replace(/\r\n?/g, "\n")
    .split(/(?<=\n\n)|(?<=[。！？.!?])/u)
    .filter(Boolean);
  const units = [];
  for (const block of blocks) {
    const ts = tokens(block);
    let current = "",
      count = 0;
    for (const t of ts) {
      current += t;
      if (!/^\s+$/.test(t)) count++;
      if (count >= 420) {
        units.push(current);
        current = "";
        count = 0;
      }
    }
    if (current) units.push(current);
  }
  const chunks = [];
  let current = "";
  let count = 0;
  const tail = (text: any) => {
    const ts = tokens(text);
    let n = 0,
      i = ts.length;
    while (i > 0 && n < overlap) {
      i--;
      if (!/^\s+$/.test(ts[i])) n++;
    }
    return ts.slice(i).join("");
  };
  for (const unit of units) {
    const n = tokenCount(unit);
    if (count >= 300 && count + n > 500) {
      chunks.push(current);
      current = tail(current);
      count = tokenCount(current);
    }
    // Oversized structural units were split at token boundaries above.
    if (count + n > 500 && count > overlap) {
      chunks.push(current);
      current = tail(current);
      count = tokenCount(current);
    }
    current += unit;
    count += n;
    if (count >= target) {
      chunks.push(current);
      current = tail(current);
      count = tokenCount(current);
    }
  }
  if (current && (chunks.length === 0 || count > overlap)) chunks.push(current);
  return chunks;
}
// Relevance tokens keep whole non-Japanese words even when Japanese follows them.
// The stored FTS v2 representation is deliberately unchanged; queries also emit
// its legacy bigrams so existing sources need no migration or re-embedding.
function tokensFromRuns(runs: any) {
  const out: any[] = [];
  for (const run of runs) {
    if (/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(run)) {
      const chars: any[] = Array.from(run as any);
      if (chars.length === 1) out.push(run);
      for (let i = 0; i < chars.length - 1; i++) out.push(chars[i] + chars[i + 1]);
    } else out.push(run);
  }
  return out;
}
function legacySearchTokens(text: any) {
  return tokensFromRuns(String(text).normalize("NFKC").toLowerCase().match(
    /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]+|[\p{L}\p{N}]+/gu,
  ) ?? []);
}
export function searchTokens(text: any) {
  return tokensFromRuns(String(text).normalize("NFKC").toLowerCase().match(
    /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]+|(?:(?![\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])[\p{L}\p{N}])+/gu,
  ) ?? []);
}
export const searchText = (text: any) => legacySearchTokens(text).join(" ");
export const matchQuery = (text: any) =>
  [...new Set([...searchTokens(text), ...identifierAliases(text).flatMap(searchTokens), ...legacySearchTokens(text)])]
    .slice(0, 64)
    .map((t) => '"' + t + '"')
    .join(" OR ");

export const INDEX_FORMAT_VERSION = 2;
// Carry the page heading and nearest section into each child's search input.
// No cross-page lookup or LLM-generated metadata.
export function contextualChildren(pageText: any, title: any) {
  const normalized = String(pageText).replace(/\r\n?/g, '\n');
  const headings: any[] = [];
  let offset = 0;
  for (const line of normalized.split('\n')) {
    const value = line.trim().replace(/^#{1,6}\s+/u, '');
    if (value && value.length <= 60 && tokenCount(value) <= 35 && !/[。！？.!?]$/u.test(value)) headings.push({ text: value, offset });
    offset += line.length + 1;
  }
  const pageHeading = headings[0]?.text ?? '';
  let cursor = 0;
  return chunkPage(normalized).map(text => {
    const position = normalized.indexOf(text, cursor);
    if (position >= 0) cursor = position;
    const section = headings.filter(h => h.offset <= cursor).at(-1)?.text ?? pageHeading;
    const headingContext = [...new Set([pageHeading, section].filter(Boolean))].join(' / ').slice(0, 180);
    const embeddingText = JSON.stringify({ title: String(title).slice(0, 300), headings: headingContext, text });
    return { text, headingContext, embeddingText };
  });
}
