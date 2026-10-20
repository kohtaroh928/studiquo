// Masks personal identifiers and secrets in an excerpt before it leaves for the
// answer model. A student's notes can hold a friend's phone number, a card
// number photographed by mistake, or a pasted key; none of it helps an answer.
// Only patterns with a low false-positive rate are used, so study content
// (dates, quantities, ids in exercises) is left alone. Returns counts, never values.
//
// Matching runs on an NFKC-normalized view of the text (full-width digits, letters
// and symbols read as ASCII, which Japanese notes use constantly); every match is
// mapped back to the original characters, so text outside a match is untouched.
const luhn = (digits: any) => {
  let sum = 0, double = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let n = digits.charCodeAt(i) - 48;
    if (double) { n *= 2; if (n > 9) n -= 9; }
    sum += n; double = !double;
  }
  return sum % 10 === 0;
};
const digitsOf = (text: any) => text.replace(/\D/gu, "");

// A Japanese number has 10 or 11 digits (03-1234-5678, 090-1234-5678, 0120-123-456),
// or 9-10 digits after +81. A date such as 03-14-2023 or a run such as 05 10 100 has
// the same shape but the wrong digit count, and is left alone.
const phoneOk = (match: any) => {
  // "+81 (0)90-1234-5678": the (0) is the trunk prefix written in brackets, not a digit of the number.
  // Domestic "(0)90…" keeps its 0; "+81 (0)90…" drops it (the country code replaces the trunk 0).
  match = match.replace(/\(0\)/u, match.startsWith("+") ? "" : "0");
  const d = digitsOf(match);
  return match.startsWith("+") ? d.startsWith("81") && d.length >= 11 && d.length <= 12 : d.startsWith("0") && (d.length === 10 || d.length === 11);
};

// Separators between the groups of a number. The long-vowel mark ー is one of them (notes
// write 03ー1234ー5678), but it is NOT a boundary: "サーバー090-1234-5678" is a number
// that follows a katakana word, not the continuation of a longer digit run.
const DASH = "\\-\u2010-\u2015\u2212\u30FC";
const NOT_BEFORE_OR_AFTER = "\\-\u2010-\u2015\u2212";
const RULES = [
  { kind: "key", label: "[鍵・トークン]", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/gu },
  { kind: "key", label: "[鍵・トークン]", re: /\b(?:sk-[A-Za-z0-9_-]{20,}|sk_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/gu },
  { kind: "key", label: "[鍵・トークン]", re: /\bBearer\s+[A-Za-z0-9._~+/=-]{20,}/giu },
  { kind: "key", label: "[鍵・トークン]", re: /(?:api[_-]?key|secret(?:[_-]?key)?|access[_-]?token|auth[_-]?token|passw(?:or)?d|パスワード|秘密鍵)\s*[=:]\s*["']?[A-Za-z0-9._~+/=!@#$%^&*-]{8,}["']?/giu },
  { kind: "email", label: "[メールアドレス]", re: /(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/gu },
  // Separators: hyphen, spaces and the dash-like marks that notes mix in (‐ ‑ ‒ – — ― − ー).
  { kind: "phone", label: "[電話番号]", re: new RegExp(`(?<![\\d${NOT_BEFORE_OR_AFTER}])(?:\\+81[${DASH}\\s]?(?:\\(0\\)[${DASH}\\s]?)?\\d[\\d\\s${DASH}]{7,12}\\d|0\\d{1,4}[${DASH}\\s]\\d{1,4}[${DASH}\\s]\\d{3,4})(?![\\d${NOT_BEFORE_OR_AFTER}])`, "gu"), accept: phoneOk },
  // (03)1234-5678, (090)1234-5678: the area code in brackets first
  { kind: "phone", label: "[電話番号]", re: new RegExp(`(?<![\\d${NOT_BEFORE_OR_AFTER}])\\(0\\d{1,4}\\)[${DASH}\\s]?\\d{1,4}[${DASH}\\s]\\d{3,4}(?![\\d${NOT_BEFORE_OR_AFTER}])`, "gu"), accept: phoneOk },
  // (0)90-1234-5678 and 0(90)1234-5678: the trunk 0 or the area code in brackets
  { kind: "phone", label: "[電話番号]", re: new RegExp(`(?<![\\d${NOT_BEFORE_OR_AFTER}])\\(0\\)\\d{1,4}[${DASH}\\s]\\d{1,4}[${DASH}\\s]\\d{3,4}(?![\\d${NOT_BEFORE_OR_AFTER}])`, "gu"), accept: phoneOk },
  { kind: "phone", label: "[電話番号]", re: new RegExp(`(?<![\\d${NOT_BEFORE_OR_AFTER}])0\\(\\d{1,4}\\)\\d{1,4}[${DASH}\\s]\\d{3,4}(?![\\d${NOT_BEFORE_OR_AFTER}])`, "gu"), accept: phoneOk },
  // 090.1234.5678
  { kind: "phone", label: "[電話番号]", re: /(?<![\d.-])0\d{1,4}\.\d{1,4}\.\d{3,4}(?![\d.-])/gu, accept: phoneOk },
  // 03(1234)5678
  { kind: "phone", label: "[電話番号]", re: /(?<![\d-])0\d{1,4}\(\d{1,4}\)\d{3,4}(?!\d)/gu, accept: phoneOk },
  { kind: "phone", label: "[電話番号]", re: /(?<![\d-])0[789]0\d{8}(?!\d)/gu },
  { kind: "myNumber", label: "[個人番号]", re: /(?:マイナンバー|個人番号)[^\n\d]{0,12}\d{4}[- ]?\d{4}[- ]?\d{4}/gu },
  // A long digit run is a card number only if it is plausible (13-19 digits, Luhn).
  { kind: "card", label: "[カード番号]", re: /(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])/gu,
    accept: (match: any) => { const d = digitsOf(match); return d.length >= 13 && d.length <= 19 && luhn(d); } },
];

export function redactPII(value: any) {
  const original = String(value ?? "");
  // Normalize one code point at a time so every normalized character knows where it came from.
  const chars = Array.from(original);
  let view = "";
  const origin: any[] = []; // origin[i] = index into `chars` of the character that produced view[i]
  chars.forEach((ch, index) => {
    // A circled or superscript digit (①, ²) is not a digit of a number: left as it is, it
    // cannot glue itself to the digits beside it.
    const n = /\p{No}/u.test(ch) ? ch : ch.normalize("NFKC");
    for (let k = 0; k < n.length; k++) origin.push(index);
    view += n;
  });
  const counts: any = { key: 0, email: 0, phone: 0, myNumber: 0, card: 0 };
  const taken = new Array(view.length).fill(false);
  const hits = []; // { from, to } in `chars` indexes, plus the label
  for (const rule of RULES) {
    for (const m of view.matchAll(rule.re)) {
      const start = m.index, end = start + m[0].length;
      if (rule.accept && !rule.accept(m[0])) continue;
      if (taken.slice(start, end).some(Boolean)) continue;
      for (let i = start; i < end; i++) taken[i] = true;
      counts[rule.kind]++;
      hits.push({ from: origin[start], to: origin[end - 1], label: rule.label });
    }
  }
  hits.sort((a, b) => b.from - a.from);
  for (const hit of hits) chars.splice(hit.from, hit.to - hit.from + 1, hit.label);
  const total = Object.values(counts).reduce((a: any, b: any) => a + b, 0);
  return { text: total ? chars.join("") : original, total, counts };
}
