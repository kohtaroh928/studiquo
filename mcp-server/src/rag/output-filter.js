// Removes links and internal identifiers from an answer that was built from retrieved
// documents or an attached note (which may be a friend's shared note). Such a text can ask
// the model to end its reply with a link whose address carries other text; with no link in
// the reply there is nothing to open.
//
// This is the server's second line. The first is in the app, which opens a link only for a
// few allowed sites in a fixed shape (AILinkPolicy). This filter covers what the app does
// not see: an older app, another client, text the reader copies.
//
// It runs ONCE, on the whole reply. An earlier version filtered the stream piece by piece
// and held back the tail that might still become a link; five rounds of review kept
// finding a way to cut the stream so that two harmless pieces joined into a link. A
// filter that sees the finished text cannot be cut. The price is that these replies are
// shown when they are complete (see streamNormalizedText in ai.js).
//
// Markdown links are found the way the app finds them (RichTextParser.link(in:)): the label
// may nest brackets and span lines, a backslash skips the next character, and the target
// runs to the first ")" or whitespace. Judging is done on a view with every invisible
// character removed, because the app reads an address through zero-width spaces, joiners,
// variation selectors and tag characters.
const URL_CHARS = "A-Za-z0-9\\-._~:/?#\\[\\]@!$&'*+,;=%\\\\";
// A scheme-ful URL or a "www." host. The address is ASCII, but non-ASCII characters are part
// of it when more address follows ("https://例え.com/a", ".../日本語?d=1"), so a sentence
// that merely continues after the URL in Japanese is not swallowed. The app swaps a
// `code span` or a $math$ span for a one-character marker before it reads a link, so a
// span inside an address is part of the address, whatever is written between its marks.
// A "$" followed by a space is a plain character, not the start of a math span.
const URL_BODY = `(?:\`[^\`\\n]*\`|\\$(?!\\s)[^$\\n]*(?<!\\s)\\$|[${URL_CHARS}]|[^\\x00-\\x7F\\s]+(?=[${URL_CHARS}\`]))+`;
const URL_RE = new RegExp(`(?:https?:\\/\\/|https?:(?=[A-Za-z0-9])|www\\.(?=[A-Za-z0-9]))${URL_BODY}`, "giu");
// What is left of a malformed scheme: "https:/e.com", "https:\\e.com", "https:例え.com". The
// browser reads many of these as a normal address, so everything after "http(s):" up to a
// space or a sentence mark goes, whichever form it takes.
const URL_LOOSE_RE = /https?:(?:`[^`\n]*`|\$(?!\s)[^$\n]*(?<!\s)\$|\$|[^\s、。！？)）」』】`$])+/giu;
// A target with any scheme (https:, javascript:, mailto:, tel:, data:, "https:e.com", ...),
// a leading // or www. is a link; a plain "[0](添字)" is not.
const LINK_TARGET_RE = /^\s*(?:[a-z][a-z0-9+.-]*:|\/\/|www\.)/iu;
const REMOVED = "（リンクは表示されません）";
// Citations are attached by the server as structured data. A model that writes
// an internal identifier into the text is repeating something a document asked
// for, so identifiers are dropped: 64-hex chunk ids and "sourceId=..." forms.
const ID_FIELD_RE = /\b(?:source|chunk)[ _-]?id\s*[=:：]\s*["'「]?[A-Za-z0-9_-]{3,80}["'」]?/giu;
const HEX_ID_RE = /\b[a-f0-9]{64}\b/gu;

const isSpace = (code) => code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x3000 || (code >= 0x2000 && code <= 0x200a) || code === 0x2028 || code === 0x2029 || code === 0x202f || code === 0x205f || code === 0x1680 || code === 0xfeff;

// Every invisible character, for judging only.
const INVISIBLE_ONE = /^[\p{Cf}\p{Cc}\p{Variation_Selector}ㅤᅟᅠ⠀͏ﾠ឴឵]$/u;
function viewOf(raw) {
  let text = "";
  for (const ch of raw) {
    if (INVISIBLE_ONE.test(ch) && ch !== "\n" && ch !== "\t" && ch !== "\r") continue;
    text += ch;
  }
  return text;
}

// For every "[" the index of the "]" that closes it (nesting counted, a backslash skips
// the next character), and for every position the next ")" or whitespace at or after it
// (where a link target ends). Both are one pass, so many brackets cannot make the scan
// quadratic, and there is no length limit a long target could be padded past.
function scan(text) {
  const pairs = new Map(), stack = [];
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 0x5c) { i++; continue; } // backslash
    if (c === 0x5b) stack.push(i); // [
    else if (c === 0x5d && stack.length) pairs.set(stack.pop(), i); // ]
  }
  const stop = new Int32Array(text.length + 1);
  stop[text.length] = text.length;
  for (let i = text.length - 1; i >= 0; i--) {
    const c = text.charCodeAt(i);
    stop[i] = c === 0x29 || isSpace(c) ? i : stop[i + 1];
  }
  return { pairs, stop };
}

// The "[label](target)" starting at `i`, or null when it is not a complete link.
function linkAt(text, i, { pairs, stop }) {
  const close = pairs.get(i);
  if (close === undefined || close + 1 >= text.length || text[close + 1] !== "(") return null;
  const k = stop[close + 2];
  if (k >= text.length || text[k] !== ")") return null;
  return { label: text.slice(i + 1, close), target: text.slice(close + 2, k), end: k + 1 };
}

function stripMarkdownLinks(text, depth = 0) {
  if (!text.includes("[")) return text;
  const tables = scan(text);
  let out = "", i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === "\\") { out += text.slice(i, i + 2); i += 2; continue; }
    if (c === "[") {
      const link = linkAt(text, i, tables);
      if (link && LINK_TARGET_RE.test(link.target)) {
        if (out.endsWith("!")) out = out.slice(0, -1); // an image: keep its description
        out += depth < 8 ? stripMarkdownLinks(link.label, depth + 1) : "";
        i = link.end;
        // "javascript:alert(1)" ends at its first ")", leaving the matching one behind.
        let extra = (link.target.match(/\(/gu) ?? []).length - (link.target.match(/\)/gu) ?? []).length;
        while (extra > 0 && text[i] === ")") { i++; extra--; }
        continue;
      }
    }
    out += c;
    i++;
  }
  return out;
}

// The links and identifiers removed from `text`, which must already be free of invisible
// characters (or those characters must not matter).
export function redactLinks(text) {
  return stripMarkdownLinks(text)
    .replace(URL_RE, REMOVED)
    .replace(URL_LOOSE_RE, REMOVED)
    .replace(ID_FIELD_RE, "")
    .replace(HEX_ID_RE, "");
}

// A finished reply, filtered. When nothing had to be removed the model's own text is
// returned unchanged (emoji sequences, Persian and Hindi joiners, variant forms intact).
// When something was removed, the reply is the filtered view, so the invisible characters
// of that one reply are lost with it: a reply that carried a link is not worth keeping
// character-exact.
export function filterReply(text) {
  const view = viewOf(text);
  const filtered = redactLinks(view);
  return filtered === view ? text : filtered;
}
