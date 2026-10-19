// Masks personal identifiers and secrets in an excerpt before it leaves for the
// answer model. A student's notes can hold a friend's phone number, a card
// number photographed by mistake, or a pasted key; none of it helps an answer.
// Only patterns with a low false-positive rate are used, so study content
// (dates, quantities, ids in exercises) is left alone. Returns counts, never values.
const luhn = (digits) => {
  let sum = 0, double = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let n = digits.charCodeAt(i) - 48;
    if (double) { n *= 2; if (n > 9) n -= 9; }
    sum += n; double = !double;
  }
  return sum % 10 === 0;
};

const RULES = [
  { kind: "key", label: "[鍵・トークン]", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/gu },
  { kind: "key", label: "[鍵・トークン]", re: /\b(?:sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/gu },
  { kind: "email", label: "[メールアドレス]", re: /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/gu },
  { kind: "phone", label: "[電話番号]", re: /(?<![\d-])(?:\+81[- ]?|0)\d{1,4}[- ]\d{1,4}[- ]\d{3,4}(?![\d-])/gu },
  { kind: "phone", label: "[電話番号]", re: /(?<![\d-])0[789]0\d{8}(?!\d)/gu },
  { kind: "myNumber", label: "[個人番号]", re: /(?:マイナンバー|個人番号)[^\n\d]{0,12}\d{4}[- ]?\d{4}[- ]?\d{4}/gu },
];
const CARD = /(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])/gu;

export function redactPII(value) {
  let text = String(value ?? "");
  const counts = { key: 0, email: 0, phone: 0, myNumber: 0, card: 0 };
  for (const rule of RULES) {
    text = text.replace(rule.re, () => { counts[rule.kind]++; return rule.label; });
  }
  // A long digit run is masked only if it is a plausible card number (13-19 digits, Luhn).
  text = text.replace(CARD, (match) => {
    const digits = match.replace(/[ -]/gu, "");
    if (digits.length < 13 || digits.length > 19 || !luhn(digits)) return match;
    counts.card++;
    return "[カード番号]";
  });
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  return { text, total, counts };
}
