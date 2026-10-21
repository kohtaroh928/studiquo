// The shape retrieve() hands to the chat prompt. See docs/RAG_PROMPT_CONTRACT.md.
export const RAG_STATUSES = Object.freeze(["grounded", "partial", "insufficient", "clarification", "fallback"]);
// Why retrieval produced no usable context. Internal and log-only: it never
// changes the answer and never contains question or document text.
export const EMPTY_REASONS = Object.freeze([
  "disabled", "not_configured", "invalid_query", "invalid_scope", "rate_limited",
  "no_match", "deadline", "auth_failed", "timeout", "error",
  "clarification", "insufficient", // paired with the status of the same name
]);

// Which check emptied the result (log-only, like `reason`). Fixed codes: never a question or a document word.
// `requirements` the asked detail (price, formula, ...) is missing; `quantity` the asked unit has no number;
// `term_katakana` / `term_latin` / `term_both` a word of the question is absent from the whole library;
// `no_candidates` / `no_references` nothing relevant was found or nothing usable survived.
export const EMPTY_DETAILS = Object.freeze([
  "requirements", "quantity", "term_katakana", "term_latin", "term_both", "no_candidates", "no_references",
]);

// Fresh object per call: callers mutate the result (status), so a shared
// constant would leak state between requests. `reason` and `truncated` are
// non-enumerable like `authorization`, so equality checks and spreads that
// existed before them still see the original three fields.
export function emptyRetrieval(reason: any, extra: any = {}, detail?: string) {
  const result = { context: "", citations: [], ...extra };
  Object.defineProperty(result, "reason", { value: reason, configurable: true });
  if (detail !== undefined) Object.defineProperty(result, "detail", { value: detail, configurable: true });
  return result;
}

// Guarantees the contract shape. Anything else becomes ordinary chat
// ("fallback"), which is also what an unknown status already produced.
export function normalizeRetrieval(value: any) {
  const ok = value && typeof value === "object" && typeof value.context === "string" &&
    Array.isArray(value.citations);
  if (!ok) return emptyRetrieval("error", { status: "fallback" });
  if (!RAG_STATUSES.includes(value.status)) value.status = "fallback";
  return value;
}
