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
// A URL is made of ASCII characters, so it ends where Japanese text begins: the
// sentence after "https://x.com/を参照してください" is not part of the address.
const URL_RE = /(?:https?:\/\/|www\.)[A-Za-z0-9\-._~:/?#[\]@!$&'*+,;=%]+/giu;
// "[label](target)" and "![alt](target)". A target with any scheme (https:, javascript:,
// mailto:, tel:, data:, ...) or starting with // is a link; a plain "[0](添字)" is not.
const MD_LINK_RE = /!?\[([^\]\n]*)\]\(\s*([^)\n]*)\)/gu;
const LINK_TARGET_RE = /^\s*(?:[a-z][a-z0-9+.-]*:|\/\/)/iu;
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
    .replace(MD_LINK_RE, (whole, label, target) => (LINK_TARGET_RE.test(target) || /^\s*www\./iu.test(target) ? label : whole))
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
  // The field name, its separator and its value arrive in separate pieces ("source", " ",
  // "id", " = ", "abc"); hold from the name until the value is complete so the field and
  // its value are removed together instead of the name leaving first.
  const field = /(?:source|chunk)(?:[ _-]?(?:i|id)?)?\s*$|(?:source|chunk)[ _-]?id\s*(?:[=:：]\s*["'「]?[A-Za-z0-9_-]{0,80})?$/iu.exec(text);
  if (field) start = Math.min(start, field.index);
  const run = /[A-Za-z0-9:/._~%?#[\]&=+@!$'*,;\-]*$/u.exec(text);
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
