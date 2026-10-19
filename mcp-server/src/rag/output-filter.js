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
const URL_CHARS = "A-Za-z0-9\\-._~:/?#\\[\\]@!$&'*+,;=%";
// A scheme-ful URL or "www." address. The address is ASCII, but non-ASCII characters are
// part of it when more address follows ("https://例え.com/a", ".../日本語?d=1"), so a
// sentence that merely continues after the URL in Japanese is not swallowed.
const URL_RE = new RegExp(
  `(?:https?:\\/\\/|https?:(?=[A-Za-z0-9])|www\\.)(?:[${URL_CHARS}]|[^\\x00-\\x7F\\s]+(?=[${URL_CHARS}]))+`, "giu");
// "https://" immediately followed by non-ASCII text with no address after it: remove up to
// the next space or sentence mark.
const URL_NONASCII_RE = /(?:https?:\/\/|www\.)(?=[^\x00-\x7F])[^\s、。！？!?)）」』】]*/giu;
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

// For every "[" the index of the "]" that closes it (nesting counted, a backslash skips
// the next character), and for every position the next ")" or whitespace at or after it
// (where a link target ends). Both are one pass, so many brackets cannot make the scan
// quadratic, and there is no length limit a long target could be padded past.
function scan(text) {
  const pairs = new Map(), stack = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "\\") { i++; continue; }
    if (c === "[") stack.push(i);
    else if (c === "]" && stack.length) pairs.set(stack.pop(), i);
  }
  const stop = new Int32Array(text.length + 1);
  stop[text.length] = text.length;
  for (let i = text.length - 1; i >= 0; i--) stop[i] = text[i] === ")" || /\s/u.test(text[i]) ? i : stop[i + 1];
  return { pairs, stop };
}

// The "[label](target)" starting at `i`, or null; `open: true` if it could still complete.
function linkAt(text, i, { pairs, stop }) {
  const close = pairs.get(i);
  if (close === undefined) return { open: true };
  if (close + 1 >= text.length) return { open: true };
  if (text[close + 1] !== "(") return null;
  const k = stop[close + 2];
  if (k >= text.length) return { open: true };
  if (text[k] !== ")") return null;
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
      if (link && !link.open && LINK_TARGET_RE.test(link.target)) {
        if (out.endsWith("!")) out = out.slice(0, -1); // an image: keep its description
        out += depth < 8 ? stripMarkdownLinks(link.label, depth + 1) : "";
        i = link.end;
        // "javascript:alert(1)" ends at its first ")", leaving the matching one behind.
        let extra = (link.target.match(/\(/gu) ?? []).length - (link.target.match(/\)/gu) ?? []).length;
        while (extra-- > 0 && text[i] === ")") i++;
        continue;
      }
    }
    out += c;
    i++;
  }
  return out;
}

export function redactLinks(text) {
  return stripMarkdownLinks(text)
    .replace(URL_RE, REMOVED)
    .replace(URL_NONASCII_RE, REMOVED)
    .replace(ID_FIELD_RE, "")
    .replace(HEX_ID_RE, "");
}

// Where the unfinished part of `text` starts: an open "[label](target", a field name whose
// value is still arriving, or a trailing run that is, or could still become, a link or id.
function holdStart(text) {
  let start = text.length;
  const from = Math.max(0, text.length - LINK_WINDOW);
  const tables = scan(text);
  for (let i = text.indexOf("[", from); i >= 0; i = text.indexOf("[", i + 1)) {
    if (i > 0 && text[i - 1] === "\\") continue;
    const link = linkAt(text, i, tables);
    if (link?.open) { start = Math.min(start, i); break; }
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
  const run = /[A-Za-z0-9:/._~%?#[\]&=+@!$'*,;\-]*$/u.exec(text);
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

export function linkRedactor() {
  let held = "";
  return {
    push(text) {
      const all = held + text;
      let cut = holdStart(all);
      if (all.length - cut > MAX_HOLD) {
        cut = all.length - MAX_HOLD;
        // Never split a surrogate pair (an emoji or a rare kanji) at the forced cut.
        const unit = all.charCodeAt(cut);
        if (unit >= 0xdc00 && unit <= 0xdfff) cut--;
      }
      held = all.slice(cut);
      return redactLinks(all.slice(0, cut));
    },
    flush() {
      const rest = held;
      held = "";
      return redactLinks(rest);
    },
  };
}
