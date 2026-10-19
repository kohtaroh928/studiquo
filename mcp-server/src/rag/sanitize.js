// Removes characters a person cannot see but a model reads: zero-width and
// bidirectional controls, Unicode tag characters (U+E0000 block, used to hide
// whole sentences), soft hyphens, BOM, C0/C1 controls, variation selectors,
// and the blank "fillers" (Hangul/Braille/combining grapheme joiner) that carry
// no visible mark. Newline, tab and carriage return stay. A single U+200C/U+200D
// stays too (scripts and emoji need one), but two or more in a row are removed:
// that is the shape of a hidden message written in joiners.
// This hides nothing from the model on purpose; it only stops a document from
// carrying text the owner never saw. Returns the count, never the characters.
const HIDDEN = /[\p{Cf}\p{Cc}\p{Variation_Selector}ㅤᅟᅠ⠀͏]/gu;
const KEEP = new Set(["\n", "\t", "\r", "‌", "‍"]);
const JOINER_RUN = /[‌‍]{2,}/gu;

export function stripInvisible(value) {
  const text = String(value ?? "");
  let removed = 0;
  const clean = text.replace(HIDDEN, (c) => (KEEP.has(c) ? c : (removed++, "")))
    .replace(JOINER_RUN, (run) => { removed += run.length; return ""; });
  return { text: clean, removed };
}
