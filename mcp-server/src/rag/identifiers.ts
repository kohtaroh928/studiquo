// Retrieval-only aliases. Never change stored text, model prompts or numeric values.
const units = new Set(['usd','eur','jpy','gbp','cad','aud','cny','krw','hz','khz','mhz','ghz','kg','km','cm','mm','ms','mb','gb','tb']);
function spans(value: any) {
 const text = String(value).normalize('NFKC');
 const found = [];
 // Horizontal gaps only: no joins across headings, lines, pages or field boundaries.
 const pattern = /(?<![A-Za-z0-9])([A-Za-z]{2,12})[ \t]{0,4}(\d{1,8}(?:\.\d{1,8}){0,3}[A-Za-z]{0,4})(?![A-Za-z0-9]|\.\d|[-/−]\d|年|円|秒|分|度|時|日|月|%|℃|°)/gu;
 for (const match of text.matchAll(pattern)) {
  const prefix = match[1].toLowerCase();
  if (units.has(prefix)) continue;
  const suffix = match[2].toLowerCase();
  found.push({ start: match.index, end: match.index + match[0].length, canonical: prefix + suffix, prefix, suffix });
 }
 return { text, found };
}
export function identifierAliases(value: any) {
 return [...new Set(spans(value).found.flatMap(s => [s.canonical, s.prefix, s.suffix]))];
}
export function identifierQuery(value: any) {
 const { text, found } = spans(value);
 let rest = '', cursor = 0;
 for (const span of found) { rest += text.slice(cursor, span.start) + ' '; cursor = span.end; }
 rest += text.slice(cursor);
 // Keep full decimal/suffix/leading-zero identity as one relevance requirement.
 return { rest, identities: [...new Set(found.map(s => s.canonical))] };
}

// Comparison text only. Callers keep original evidence for context and citations.
export function identifierText(value: any) {
 const { text, found } = spans(value);
 let out = '', cursor = 0;
 for (const span of found) { out += text.slice(cursor, span.start) + span.canonical; cursor = span.end; }
 return out + text.slice(cursor);
}
