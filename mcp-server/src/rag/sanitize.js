// Removes characters a person cannot see but a model reads: zero-width and
// bidirectional controls, Unicode tag characters (U+E0000 block, used to hide
// whole sentences), soft hyphens, BOM and C0/C1 controls. Newline, tab and
// carriage return stay. U+200C/U+200D stay too: scripts and emoji need them.
// This hides nothing from the model on purpose; it only stops a document from
// carrying text the owner never saw. Returns the count, never the characters.
const HIDDEN = /[\p{Cf}\p{Cc}]/gu;
const KEEP = new Set(["\n", "\t", "\r", "‌", "‍"]);

export function stripInvisible(value) {
  const text = String(value ?? "");
  let removed = 0;
  const clean = text.replace(HIDDEN, (c) => (KEEP.has(c) ? c : (removed++, "")));
  return { text: clean, removed };
}
