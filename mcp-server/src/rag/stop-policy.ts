// What happens when document search yields nothing usable. Decided here, in code, so a reply
// is never silently written from general knowledge while the student believes it came from
// their documents. Fixed texts only; never interpolate query, reference or provider text.
import { normalizeRAGAnswerStyle } from "./answer-policy.ts";

export const RAG_NOT_FOUND_MESSAGE = "資料の中に、この質問に該当する記載が見つかりませんでした。質問の言葉を変えるか、資料検索の設定で対象の資料を確認してください。資料を使わずに一般知識で答えてほしいときは、回答スタイルを「補足あり」に切り替えてください。";
export const RAG_UNAVAILABLE_MESSAGE = "資料検索がうまく動かなかったため、回答を作成できませんでした。しばらくしてからもう一度お試しください。";

// The retrieval outcomes that carry evidence (or ask a question) and go on to the model.
const ANSWERABLE = new Set(["grounded", "partial", "insufficient", "clarification"]);

export type RagStop = { status: "not_found" | "unavailable"; message: string };

/**
 * `null` means the model may answer. For `source_only`, "no matching passage" stops with a
 * not-found message. For `explain`, it goes on as an ordinary answer, flagged `general` so
 * the reply says it is not from the documents. A failure of the search itself stops in both
 * styles: there is no way to tell whether the documents held the answer.
 */
export function ragStop(rag: any, answerStyle: unknown): { stop: RagStop | null; general: boolean } {
  if (ANSWERABLE.has(rag?.status)) return { stop: null, general: false };
  if (rag?.reason === "no_match") {
    if (normalizeRAGAnswerStyle(answerStyle) === "explain") return { stop: null, general: true };
    return { stop: { status: "not_found", message: RAG_NOT_FOUND_MESSAGE }, general: false };
  }
  return { stop: { status: "unavailable", message: RAG_UNAVAILABLE_MESSAGE }, general: false };
}
