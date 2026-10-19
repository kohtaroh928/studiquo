// Removes links and internal identifiers from an answer that was built from retrieved documents. A
// document can ask the model to end its reply with a link whose address
// carries other excerpts; with no link in the answer there is nothing to tap.
// The app also refuses to open links in such answers (RichMessageView.allowLinks);
// this is the server-side half, for any client.
//
// Text arrives in pieces, so a link can be split across two pieces. `push`
// holds back the tail that could still turn into a link and releases it once
// it cannot (or on `flush`). Held text is bounded, so a long run of letters
// delays output a little but never blocks it.
const URL_RE = /(?:https?:\/\/|www\.)[^\s<>"'）」』】]+/giu;
const MD_LINK_RE = /\[([^\]\n]*)\]\(\s*[^)\n]*\)/gu;
const MAX_HOLD = 600;
const REMOVED = "（リンクは表示されません）";
// Citations are attached by the server as structured data. A model that writes
// an internal identifier into the text is repeating something a document asked
// for, so identifiers are dropped: 64-hex chunk ids and "sourceId=..." forms.
const ID_FIELD_RE = /\b(?:source|chunk)[ _-]?id\s*[=:：]\s*["'「]?[A-Za-z0-9_-]{3,80}["'」]?/giu;
const HEX_ID_RE = /\b[a-f0-9]{64}\b/gu;
const ID_PREFIXES = ["sourceid", "source_id", "source-id", "source id", "chunkid", "chunk_id", "chunk-id", "chunk id"];

export function redactLinks(text) {
  return text
    .replace(MD_LINK_RE, (whole, label) => (/(?:https?:|www\.|\/\/)/iu.test(whole) ? label : whole))
    .replace(URL_RE, REMOVED)
    .replace(ID_FIELD_RE, "")
    .replace(HEX_ID_RE, "");
}

// Where the unfinished part of `text` starts: an open "[label](" , or a trailing
// run of characters that a URL is made of.
function holdStart(text) {
  const bracket = text.lastIndexOf("[");
  let start = text.length;
  if (bracket >= 0 && !text.slice(bracket).includes("\n") && !/\]\([^)]*\)/u.test(text.slice(bracket))) start = bracket;
  // "chunk_id:" ends before the space that precedes its value; keep them together.
  const field = /(?:source|chunk)[ _-]?id\s*[=:：]\s*["'「]?$/iu.exec(text);
  if (field) start = Math.min(start, field.index);
  const run = /[A-Za-z0-9:/._~%?#&=+@!$'*,;\-]*$/u.exec(text);
  if (run) {
    // Hold only a tail that is, or could still become, a link or an internal id.
    for (let i = 0; i < run[0].length; i++) {
      const tail = run[0].slice(i).toLowerCase();
      if ("https://".startsWith(tail) || "www.".startsWith(tail) || /^(?:https?:\/\/|www\.)/u.test(tail) ||
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
      if (all.length - cut > MAX_HOLD) cut = all.length - MAX_HOLD;
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
