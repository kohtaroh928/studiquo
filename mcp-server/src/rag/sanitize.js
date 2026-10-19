// Removes characters a person cannot see but a model reads: zero-width and
// bidirectional controls, Unicode tag characters (U+E0000 block, used to hide
// whole sentences), soft hyphens, BOM, C0/C1 controls, and the blank "fillers"
// (Hangul, Khmer, Braille, combining grapheme joiner) that carry no visible mark.
// Newline, tab and carriage return stay.
//
// Some invisible characters are also part of ordinary writing, so they are removed
// only where they carry no meaning:
//  - variation selectors stay after a Han character (the variant forms of names and
//    places, 葛󠄀飾) or an emoji (❤️, keycaps); a run of two or more, or a selector
//    after anything else, is a hidden message and goes;
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
const SELECTOR_AFTER_NON_EMOJI = /(?<![\p{Emoji}\p{Script=Han}])[︀-️]/gu;
const MONGOLIAN_SELECTOR = /[᠋-᠍᠏]/gu;
const PICTOGRAPH = "\\p{Extended_Pictographic}\\uFE0F\\u{1F3FB}-\\u{1F3FF}";
const JOINING = "\\p{Script=Arabic}\\p{Script=Devanagari}\\p{Script=Bengali}\\p{Script=Gurmukhi}\\p{Script=Gujarati}\\p{Script=Oriya}\\p{Script=Tamil}\\p{Script=Telugu}\\p{Script=Kannada}\\p{Script=Malayalam}\\p{Script=Sinhala}";
const ZWJ_OUTSIDE_EMOJI = new RegExp(`\\u200D(?![\\p{Extended_Pictographic}${JOINING}])|(?<![${PICTOGRAPH}${JOINING}])\\u200D`, "gu");
const ZWNJ_OUTSIDE_SCRIPTS = new RegExp(`\\u200C(?![${JOINING}])|(?<![${JOINING}])\\u200C`, "gu");
const SPECIAL_SPACE = /[   -   ]/gu;

export function stripInvisible(value) {
  let removed = 0;
  const drop = (match) => { removed += Array.from(match).length; return ""; };
  const clean = String(value ?? "")
    .replace(HIDDEN, (c) => (KEEP.has(c) ? c : drop(c)))
    .replace(SELECTOR_RUN, drop)
    .replace(SELECTOR_AFTER_NON_HAN, drop)
    .replace(SELECTOR_AFTER_NON_EMOJI, drop)
    .replace(MONGOLIAN_SELECTOR, drop)
    .replace(ZWJ_OUTSIDE_EMOJI, drop)
    .replace(ZWNJ_OUTSIDE_SCRIPTS, drop)
    .replace(SPECIAL_SPACE, " ");
  return { text: clean, removed };
}
