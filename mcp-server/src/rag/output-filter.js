// Removes links and internal identifiers from an answer that was built from retrieved
// documents. A document can ask the model to end its reply with a link whose address
// carries other excerpts; with no link in the answer there is nothing to tap.
// The app also refuses to open links in such answers (RichMessageView.allowLinks), but a
// reply built only from an attached note carries no retrieval status, so this
// server-side half is the only defence there, and for any other client.
//
// Markdown links are found the way the app finds them (RichTextParser.link(in:)):
// the label may nest brackets and span lines, a backslash skips the next character, and
// the target runs to the first ")" or whitespace. A filter that read links differently
// from the app would let a link through that only the app understands.
//
// Text arrives in pieces, so a link can be split across two pieces. `push` holds back
// the tail that could still turn into a link or an identifier and releases it once it
// cannot (or on `flush`). Held text is bounded, so a stray "[" or a long run of letters
// delays output a little but never blocks it.
const URL_CHARS = "A-Za-z0-9\\-._~:/?#\\[\\]@!$&'*+,;=%\\\\";
// A scheme-ful URL or a "www." host. The address is ASCII, but non-ASCII characters are part
// of it when more address follows ("https://例え.com/a", ".../日本語?d=1"), so a sentence
// that merely continues after the URL in Japanese is not swallowed. The app swaps a
// `code span` or a $math$ span for a one-character marker before it reads a link, so a
// span inside an address is part of the address, whatever is written between its marks.
const URL_BODY = `(?:\`[^\`\\n]*\`|\\$(?!\\s)[^$\\n]*(?<!\\s)\\$|[${URL_CHARS}]|[^\\x00-\\x7F\\s]+(?=[${URL_CHARS}\`]))+`;
const URL_RE = new RegExp(`(?:https?:\\/\\/|https?:(?=[A-Za-z0-9])|www\\.(?=[A-Za-z0-9]))${URL_BODY}`, "giu");
// What is left of a malformed scheme: "https:/e.com", "https:\\e.com", "https:例え.com". The
// browser reads many of these as a normal address, so everything after "http(s):" up to a
// space or a sentence mark goes, whichever form it takes.
const URL_LOOSE_RE = /https?:(?:`[^`\n]*`|\$(?!\s)[^$\n]*(?<!\s)\$|\$|[^\s、。！？)）」』】`$])+/giu;
// A target with any scheme (https:, javascript:, mailto:, tel:, data:, "https:e.com", ...),
// a leading // or www. is a link; a plain "[0](添字)" is not.
const LINK_TARGET_RE = /^\s*(?:[a-z][a-z0-9+.-]*:|\/\/|www\.)/iu;
const MAX_HOLD = 600;
const LINK_WINDOW = 1500; // how far back an unfinished "[label](target" is looked for
const REMOVED = "（リンクは表示されません）";
// Citations are attached by the server as structured data. A model that writes
// an internal identifier into the text is repeating something a document asked
// for, so identifiers are dropped: 64-hex chunk ids and "sourceId=..." forms.
const ID_FIELD_RE = /\b(?:source|chunk)[ _-]?id\s*[=:：]\s*["'「]?[A-Za-z0-9_-]{3,80}["'」]?/giu;
const HEX_ID_RE = /\b[a-f0-9]{64}\b/gu;
const ID_PREFIXES = ["sourceid", "source_id", "source-id", "source id", "chunkid", "chunk_id", "chunk-id", "chunk id"];

const isSpace = (code) => code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x3000 || (code >= 0x2000 && code <= 0x200a) || code === 0x2028 || code === 0x2029 || code === 0x202f || code === 0x205f || code === 0x1680 || code === 0xfeff;

// Every invisible character, for judging only. The app reads an address through zero-width
// spaces, joiners, variation selectors and tag characters, so the filter must too; but the
// text it lets through is the model's own, unchanged (an emoji sequence or a Persian word
// that happens to be cut mid-way must not lose its joiner).
const INVISIBLE_ONE = /^[\p{Cf}\p{Cc}\p{Variation_Selector}\u3164\u115F\u1160\u2800\u034F\uFFA0\u17B4\u17B5]$/u;
function makeView(raw) {
  let text = "";
  const map = []; // map[i] = index in `raw` of view character i; map[text.length] = raw.length
  for (let i = 0; i < raw.length;) {
    const ch = String.fromCodePoint(raw.codePointAt(i));
    if (INVISIBLE_ONE.test(ch) && ch !== "\n" && ch !== "\t" && ch !== "\r") { i += ch.length; continue; }
    text += ch;
    for (let k = 0; k < ch.length; k++) map.push(i + k);
    i += ch.length;
  }
  map.push(raw.length);
  return { text, map };
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

// The "[label](target)" starting at `i`, or null; `open: true` if it could still complete.
function linkAt(text, i, { pairs, stop }) {
  const close = pairs.get(i);
  if (close === undefined) return { open: true, phase: "label" };
  if (close + 1 >= text.length) return { open: true, phase: "bracket" };
  if (text[close + 1] !== "(") return null;
  const k = stop[close + 2];
  if (k >= text.length) return { open: true, phase: "target" };
  if (text[k] !== ")") return null;
  return { label: text.slice(i + 1, close), target: text.slice(close + 2, k), end: k + 1 };
}

// `state.owed` collects ")" that belong to a removed link ("javascript:alert(1)" ends at
// its first ")") but had not arrived yet when the segment ended.
function stripMarkdownLinks(text, state, depth = 0) {
  if (!text.includes("[")) return text;
  const tables = scan(text);
  let out = "", i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === "\\") { out += text.slice(i, i + 2); i += 2; continue; }
    if (c === "[") {
      const link = linkAt(text, i, tables);
      if (link && !link.open && LINK_TARGET_RE.test(link.target)) {
        if (out.endsWith("!")) out = out.slice(0, -1); // an image: keep its description
        out += depth < 8 ? stripMarkdownLinks(link.label, state, depth + 1) : "";
        i = link.end;
        let extra = (link.target.match(/\(/gu) ?? []).length - (link.target.match(/\)/gu) ?? []).length;
        while (extra > 0 && text[i] === ")") { i++; extra--; }
        if (extra > 0 && i >= text.length && depth === 0) state.owed = extra;
        continue;
      }
    }
    out += c;
    i++;
  }
  return out;
}

function filterSegment(text) {
  const state = { owed: 0 };
  const out = stripMarkdownLinks(text, state)
    .replace(URL_RE, REMOVED)
    .replace(URL_LOOSE_RE, REMOVED)
    .replace(ID_FIELD_RE, "")
    .replace(HEX_ID_RE, "");
  return { text: out, owed: state.owed };
}

export function redactLinks(text) {
  return filterSegment(text).text;
}

const URL_REACHES_END = new RegExp(`(?:https?:|www\\.)${URL_BODY.replace(/\)\+$/u, ")*")}(?:\`[^\`\\n]*|\\$(?!\\s)[^$\\n]*)?$`, "iuy");

// The same for the loose form ("https:例え.com"): anything but a space or a sentence mark continues it.
const URL_LOOSE_REACHES_END = /https?:(?:`[^`\n]*`|\$(?!\s)[^$\n]*(?<!\s)\$|\$|[^\s、。！？)）」』】`$])*(?:`[^`\n]*|\$(?!\s)[^$\n]*)?$/iuy;

// Whether the "[" at `i` is escaped: an odd number of backslashes right before it.
function escaped(text, i) {
  let n = 0;
  while (i - 1 - n >= 0 && text[i - 1 - n] === "\\") n++;
  return n % 2 === 1;
}

// Where the unfinished part of `text` starts: an open "[label](target", a field name whose
// value is still arriving, or a trailing run that is, or could still become, a link or id.
function holdStart(text) {
  let start = text.length;
  const from = Math.max(0, text.length - LINK_WINDOW);
  const firstBracket = text.indexOf("[", from);
  const tables = firstBracket >= 0 ? scan(text) : null; // most text has no bracket: skip the scan
  for (let i = firstBracket; i >= 0; i = text.indexOf("[", i + 1)) {
    if (escaped(text, i)) continue;
    const link = linkAt(text, i, tables);
    if (link?.open) { start = Math.min(start, i); break; }
  }
  // An address that runs up to the end of the text (a `code span` or $math$ span in it counts,
  // open or closed: the app reads a span as part of the address) may still be continuing.
  for (const m of [...text.slice(from).matchAll(/https?:|www\./giu)].slice(-4)) {
    URL_REACHES_END.lastIndex = from + m.index;
    URL_LOOSE_REACHES_END.lastIndex = from + m.index;
    if (URL_REACHES_END.test(text) || URL_LOOSE_REACHES_END.test(text)) { start = Math.min(start, from + m.index); break; }
  }
  // The field name, its separator and its value arrive in separate pieces ("source", " ",
  // "id", " = ", "abc"); hold from the name until the value is complete so the field and its
  // value are removed together. Both shapes are tried and the earlier start wins, otherwise
  // a value that itself ends in "source" or "chunk" would be cut at that word.
  for (const shape of [
    /(?:source|chunk)(?:[ _-]?(?:i|id)?)?\s*$/iu,
    /(?:source|chunk)[ _-]?id\s*(?:[=:：]\s*["'「]?[A-Za-z0-9_-]{0,80}\s?)?$/iu,
  ]) {
    const field = shape.exec(text);
    if (field) start = Math.min(start, field.index);
  }
  const run = /[A-Za-z0-9:/._~%?#[\]&=+@!$'*,;`\\-]*$/u.exec(text);
  if (run) {
    for (let i = 0; i < run[0].length; i++) {
      const tail = run[0].slice(i).toLowerCase();
      if ("https://".startsWith(tail) || "http:".startsWith(tail) || "www.".startsWith(tail) ||
          /^(?:https?:|www\.)/u.test(tail) ||
          ID_PREFIXES.some((prefix) => prefix.startsWith(tail) || tail.startsWith(prefix)) ||
          /^[a-f0-9]+$/u.test(tail)) {
        start = Math.min(start, run.index + i);
        break;
      }
    }
  }
  return start;
}

// What is thrown away, one character at a time, when a link or an address has grown past
// what can be held. It follows the same shapes the filter removes, so the rest of the
// construct disappears with its start instead of leaking out in small pieces.
function suppressor(mode) {
  let depth = 1, skip = false, span = "", pendingDollar = false;
  return {
    // Returns the text after the construct; `done` says the construct has ended.
    feed(text) {
      for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (mode === "url") {
          if (pendingDollar) {
            pendingDollar = false;
            // "$" followed by a space is a plain character, not the start of a math span
            if (isSpace(ch.charCodeAt(0))) { this.done = true; return text.slice(i); }
            span = "$";
          }
          if (span) { if (ch === span || ch === "\n") span = ""; continue; }
          if (ch === "`") { span = ch; continue; }
          if (ch === "$") { pendingDollar = true; continue; }
          // Same end as the loose form of an address: a space or a sentence mark. A long address
          // may carry non-ASCII characters inside it ("https:例え.com?d=…"), and what follows
          // them is still part of what the browser opens.
          if (!isSpace(ch.charCodeAt(0)) && !"、。！？)）」』】".includes(ch)) continue;
          this.done = true; return text.slice(i);
        }
        if (mode === "label") {
          if (skip) { skip = false; continue; }
          if (ch === "\\") { skip = true; continue; }
          if (ch === "[") depth++;
          else if (ch === "]" && --depth === 0) mode = "afterLabel";
          continue;
        }
        if (mode === "afterLabel") {
          if (ch !== "(") { this.done = true; return text.slice(i); }
          mode = "target"; continue;
        }
        // target: ends at the first ")" (taken) or whitespace (left in the text)
        if (ch === ")") { this.done = true; return text.slice(i + 1); }
        if (isSpace(ch.charCodeAt(0))) { this.done = true; return text.slice(i); }
      }
      return "";
    },
    done: false,
  };
}

export function linkRedactor() {
  let held = "", owed = 0, suppress = null;
  // The text to send for a segment: the model's own text when nothing in it was filtered,
  // otherwise the filtered view.
  const emit = (view, rawSegment) => {
    const segment = filterSegment(view);
    owed = segment.owed;
    return segment.text === view ? rawSegment : segment.text;
  };
  return {
    push(piece) {
      let text = piece;
      if (suppress) {
        text = suppress.feed(makeView(text).text);
        if (!suppress.done) return "";
        suppress = null;
      }
      while (owed > 0 && text.startsWith(")")) { text = text.slice(1); owed--; }
      const all = held + text;
      const view = makeView(all);
      let cut = holdStart(view.text);
      if (view.text.length - cut > MAX_HOLD) {
        const heldPart = view.text.slice(cut);
        const isUrl = /^(?:https?:|www\.)/iu.test(heldPart);
        // A stray "[" (an interval like [0, 1)) or a bracket followed by ordinary prose is text
        // and is released as such. Only a link that has a scheme in its target is dropped.
        let schemeTarget = false;
        if (heldPart[0] === "[") {
          const tables = scan(heldPart);
          const close = tables.pairs.get(0);
          schemeTarget = linkAt(heldPart, 0, tables)?.phase === "target" && LINK_TARGET_RE.test(heldPart.slice(close + 2));
        }
        if (isUrl || schemeTarget) {
          // A link or address longer than anything real: drop it, and keep dropping what
          // follows of the same construct. Releasing it in pieces would let it through.
          const kept = emit(view.text.slice(0, cut), all.slice(0, view.map[cut]));
          const dropping = suppressor(isUrl ? "url" : "label");
          // The dropped part may have opened a code span or a link label; the suppressor
          // must start in the state it left off in.
          const rest = dropping.feed(isUrl ? heldPart : heldPart.slice(1));
          held = "";
          if (dropping.done) { held = rest; } else suppress = dropping;
          return kept + REMOVED;
        }
        cut = view.text.length - MAX_HOLD;
        // Never split a surrogate pair (an emoji or a rare kanji) at the forced cut.
        const unit = view.text.charCodeAt(cut);
        if (unit >= 0xdc00 && unit <= 0xdfff) cut--;
      }
      held = all.slice(view.map[cut]);
      return emit(view.text.slice(0, cut), all.slice(0, view.map[cut]));
    },
    flush() {
      const rest = held;
      held = "";
      if (suppress) return "";
      const view = makeView(rest).text;
      return emit(view, rest);
    },
  };
}
