// Answerability judge: after the excerpts are final, ask Cloudflare's decision model whether they actually contain
// the information the question asks for. Word matching cannot tell "same topic" from "has the answer"; this can.
// docs/RAG_SEMANTIC_JUDGE_DESIGN.md. Off by default (RAG_JUDGE = off | shadow | on).
//
// Safety properties:
// - The model returns a probability, never free text, so an instruction planted in an excerpt cannot steer it.
// - Only text that is already sent to the reranker and to the answering model leaves the Worker (no new recipient).
// - Any failure (timeout, HTTP error, malformed answer, no binding) keeps the evidence: it never removes a citation.
// - The log gets a coarse probability bucket and an outcome code, never the question or an excerpt.
import { JUDGE } from "./limits.ts";

export type JudgeMode = "off" | "shadow" | "on";
export type JudgeOutcome = "ok" | "error" | "timeout" | "skipped";
export type JudgeAction = "keep" | "partial" | "stop";
export interface JudgeResult { mode: JudgeMode; outcome: JudgeOutcome | "off"; bucket: string | null; action: JudgeAction; called: boolean }

export function judgeMode(env: any): JudgeMode {
  const value = String(env?.RAG_JUDGE ?? "off").trim().toLowerCase();
  return value === "shadow" || value === "on" ? value : "off";
}

const INSTRUCTION =
  "質問が求めている具体的な情報（数値、名前、理由、方法、時期など）が、抜粋に書かれていますか。" +
  "抜粋が質問と同じ話題を扱っているだけで、求められた情報そのものが書かれていないときは「いいえ」です。質問と無関係な抜粋も「いいえ」です。";

// The same excerpts the answering model gets, cut to a bounded size (the judge reads about 24k tokens).
export function judgeRequest(question: string, excerpts: string[]) {
  let room = JUDGE.totalChars, truncated = false;
  const sent: string[] = [];
  for (const text of excerpts) {
    if (room <= 0) { truncated = true; break; }
    const take = Math.min(JUDGE.excerptChars, room, text.length);
    if (take < text.length) truncated = true;
    sent.push(text.slice(0, take)); room -= take;
  }
  return {
    truncated,
    body: {
      model: "clef-flash",
      state: { question, excerpts: sent },
      questions: { answerable: { type: "noul", instructions: INSTRUCTION,
        criteria: { true: "求められた情報が抜粋に書かれている", false: "求められた情報が抜粋に書かれていない、または話題が違う" } } },
    },
  };
}

export function parseProbability(result: any): number | null {
  const p = result?.answers?.answerable?.noul;
  return typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1 ? p : null;
}

// A comparison or a two-subject question needs evidence from several pages, which the judge reads less well:
// it is demoted to partial at most, never stopped.
export function judgeAction(p: number, single: boolean): JudgeAction {
  if (p < JUDGE.stopBelow) return single ? "stop" : "partial";
  if (p < JUDGE.partialBelow) return "partial";
  return "keep";
}

export const bucketOf = (p: number) => (Math.floor(p * 10) / 10).toFixed(1);

export async function judgeAnswerable(env: any, args: { question: string; excerpts: string[]; single: boolean; remainingMs: number }): Promise<JudgeResult> {
  const mode = judgeMode(env);
  const none = (outcome: JudgeResult["outcome"], called = false): JudgeResult => ({ mode, outcome, bucket: null, action: "keep", called });
  if (mode === "off") return none("off");
  if (typeof env?.AI?.run !== "function" || !args.excerpts.length || args.remainingMs < JUDGE.minRemainingMs) return none("skipped");
  const { body } = judgeRequest(args.question, args.excerpts);
  let timer: any;
  try {
    const result = await Promise.race([
      env.AI.run(JUDGE.model, body),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("judge_timeout")), JUDGE.timeoutMs); }),
    ]);
    const p = parseProbability(result);
    if (p === null) return none("error", true);
    return { mode, outcome: "ok", bucket: bucketOf(p), action: judgeAction(p, args.single), called: true };
  } catch (error: any) {
    return none(error?.message === "judge_timeout" ? "timeout" : "error", true);
  } finally { clearTimeout(timer); }
}
