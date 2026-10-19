// Removes links from an answer that was built from retrieved documents. A
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

export function redactLinks(text) {
  return text
    .replace(MD_LINK_RE, (whole, label) => (/(?:https?:|www\.|\/\/)/iu.test(whole) ? label : whole))
    .replace(URL_RE, REMOVED);
}

// Where the unfinished part of `text` starts: an open "[label](" , or a trailing
// run of characters that a URL is made of.
function holdStart(text) {
  const bracket = text.lastIndexOf("[");
  let start = text.length;
  if (bracket >= 0 && !text.slice(bracket).includes("\n") && !/\]\([^)]*\)/u.test(text.slice(bracket))) start = bracket;
  const run = /[A-Za-z0-9:/._~%?#&=+@!$'*,;\-]*$/u.exec(text);
  if (run) {
    // Hold only a tail that is, or could still become, the start of a link.
    for (let i = 0; i < run[0].length; i++) {
      const tail = run[0].slice(i).toLowerCase();
      if ("https://".startsWith(tail) || "www.".startsWith(tail) || /^(?:https?:\/\/|www\.)/u.test(tail)) {
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
