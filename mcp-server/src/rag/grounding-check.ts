// Rule-based check of a finished answer against what the model was shown
// (stage A of docs/RAG_GROUNDING_VERIFICATION_PLAN.md). It only counts: numbers
// and model-number-like tokens in the answer that appear nowhere in the
// excerpts or the question. The count goes to the log (stage B, shadow mode);
// the answer is never changed. Numbers derived by arithmetic (3 x 5000 = 15000)
// are legitimately absent, so a nonzero count is a signal to look, not a verdict.
const normalize = (text: any) => String(text ?? "").normalize("NFKC").replace(/(?<=\d),(?=\d{3}\b)/gu, "");
const NUMBER = /\d+(?:\.\d+)?/gu;
const MODEL_TOKEN = /\b[A-Za-z]{1,6}[-_]?\d{2,}[A-Za-z0-9-]*\b/gu;

function numbersOf(text: any) {
  // "2026年10月20日" style dates and one-digit numbers are too common to be informative.
  return new Set((text.match(NUMBER) ?? []).filter((n: any) => n.replace(".", "").length >= 2));
}

export function groundingCheck(answer: any, shown: any) {
  const a = normalize(answer), s = normalize(shown);
  // Digits inside a model number are judged as part of the token, not as figures.
  const shownNumbers = numbersOf(s.replace(MODEL_TOKEN, " "));
  const answerNumbers = [...numbersOf(a.replace(MODEL_TOKEN, " "))];
  const ungroundedNumbers = answerNumbers.filter((n) => !shownNumbers.has(n));
  const shownTokens = new Set((s.match(MODEL_TOKEN) ?? []).map((t) => t.toLowerCase()));
  const answerTokens = [...new Set((a.match(MODEL_TOKEN) ?? []).map((t) => t.toLowerCase()))];
  const ungroundedTokens = answerTokens.filter((t) => !shownTokens.has(t));
  return {
    checkedNumbers: answerNumbers.length, ungroundedNumbers: ungroundedNumbers.length,
    checkedTokens: answerTokens.length, ungroundedTokens: ungroundedTokens.length,
  };
}
