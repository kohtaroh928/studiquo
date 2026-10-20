// Removes characters a person cannot see but a model reads: zero-width and
// bidirectional controls, Unicode tag characters (U+E0000 block, used to hide
// whole sentences), soft hyphens, BOM, C0/C1 controls, and the blank "fillers"
// (Hangul, Khmer, Braille, combining grapheme joiner) that carry no visible mark.
// Newline, tab and carriage return stay.
//
// Some invisible characters are also part of ordinary writing, so they are removed
// only where they carry no meaning:
//  - variation selectors stay after a Han character (the variant forms of names and
//    places, 葛󠄀飾; while they stay under about one in ten Han characters) or an emoji
//    (❤️, keycaps); a run of two or more, or a selector after anything else, is a
//    hidden message and goes; the England/Scotland/Wales flags keep their tag characters;
//  - ZWJ stays between emoji (👨‍👩‍👧) or Indic letters and ZWNJ stays beside Arabic and Indic letters;
//    one between ordinary letters ("h‌e‌l‌l‌o") is removed;
//  - no-break and other special spaces are written as a plain space (a pattern of two
//    kinds of space can carry a message); the ideographic space U+3000 is left alone.
// This hides nothing from the model on purpose; it only stops a document from
// carrying text the owner never saw. Returns the count, never the characters.
const HIDDEN = /[\p{Cf}\p{Cc}ㅤᅟᅠ⠀͏ﾠ឴឵]/gu;
const KEEP = new Set(["\n", "\t", "\r", "‌", "‍"]);
const SELECTOR_RUN = /\p{Variation_Selector}{2,}/gu;
const SELECTOR_AFTER_NON_HAN = /(?<!\p{Script=Han})[\u{E0100}-\u{E01EF}]/gu;
// Selectors that carry a variant form of a character: the supplementary set and the
// standard FE00-FE0D (FE0E/FE0F choose text or emoji style and are handled separately).
const IDEOGRAPHIC_SELECTOR = /[\u{E0100}-\u{E01EF}\uFE00-\uFE0D]/gu;
// The three subdivision flags (England, Scotland, Wales) are an emoji followed by tag
// characters; the tags are part of the picture, so exactly these sequences are kept.
const SUBDIVISION_FLAG = /(\u{1F3F4}(?:\u{E0067}\u{E0062}(?:\u{E0065}\u{E006E}\u{E0067}|\u{E0073}\u{E0063}\u{E0074}|\u{E0077}\u{E006C}\u{E0073}))\u{E007F})/gu;
// A name list may carry a few variant forms; one selector after most characters is a code.
const IDEOGRAPHIC_SELECTOR_SHARE = 0.1;
// ...and never more than this many in one text, however long: the share alone would let a
// long text carry a longer message.
const IDEOGRAPHIC_SELECTOR_MAX = 20;
const SELECTOR_AFTER_NON_EMOJI = /(?<![\p{Emoji}\p{Script=Han}])[︀-️]/gu;
const MONGOLIAN_SELECTOR = /[᠋-᠍᠏]/gu;
const PICTOGRAPH = "\\p{Extended_Pictographic}\\uFE0F\\u{1F3FB}-\\u{1F3FF}";
const JOINING = "\\p{Script=Arabic}\\p{Script=Devanagari}\\p{Script=Bengali}\\p{Script=Gurmukhi}\\p{Script=Gujarati}\\p{Script=Oriya}\\p{Script=Tamil}\\p{Script=Telugu}\\p{Script=Kannada}\\p{Script=Malayalam}\\p{Script=Sinhala}";
const ZWJ_OUTSIDE_EMOJI = new RegExp(`\\u200D(?![\\p{Extended_Pictographic}${JOINING}])|(?<![${PICTOGRAPH}${JOINING}])\\u200D`, "gu");
const ZWNJ_OUTSIDE_SCRIPTS = new RegExp(`\\u200C(?![${JOINING}])|(?<![${JOINING}])\\u200C`, "gu");
const SPECIAL_SPACE = /[   -   ]/gu;

export function stripInvisible(value) {
  const text = String(value ?? "");
  let removed = 0;
  const drop = (match) => { removed += Array.from(match).length; return ""; };
  // Variant-form selectors are kept only while they stay rare among the Han characters;
  // a message can be written one byte per character in them (about eight bits each).
  const han = (text.match(/\p{Script=Han}/gu) ?? []).length;
  const selectors = (text.match(IDEOGRAPHIC_SELECTOR) ?? []).length;
  const tooMany = selectors > Math.min(IDEOGRAPHIC_SELECTOR_MAX, Math.max(2, Math.floor(han * IDEOGRAPHIC_SELECTOR_SHARE)));
  const clean = (part) => part
    .replace(HIDDEN, (c) => (KEEP.has(c) ? c : drop(c)))
    .replace(SELECTOR_RUN, drop)
    .replace(tooMany ? IDEOGRAPHIC_SELECTOR : SELECTOR_AFTER_NON_HAN, drop)
    .replace(SELECTOR_AFTER_NON_EMOJI, drop)
    .replace(MONGOLIAN_SELECTOR, drop)
    .replace(ZWJ_OUTSIDE_EMOJI, drop)
    .replace(ZWNJ_OUTSIDE_SCRIPTS, drop)
    .replace(SPECIAL_SPACE, " ");
  // split() with a capture group puts each kept flag at an odd index
  const parts = text.split(SUBDIVISION_FLAG);
  return { text: parts.map((part, i) => (i % 2 === 1 ? part : clean(part))).join(""), removed };
}
