// What one AI call costs, and how much each plan may spend, in "credits".
//
// A credit is a fixed slice of real model cost (about $0.0007, one cheap
// Luna call), so a heavy model uses many credits and a light one uses one:
// the plan screen can promise "週350クレジット" and the Worker's bill stays
// bounded whichever models a student picks. Prices behind the weights (per
// 1M tokens, 3,000 input + 800 output tokens assumed per call — a longer input
// costs more, see creditCost; checked on the providers' price pages 2026-10-12):
//   GPT Luna   $0.10 / $0.50                1
//   Sonnet 5.5 $2 / $10                    20
//   GPT Sol    $2 / $10                    20
//   GPT Terra  $2 / $12                    22
//   Opus 5.5   $4 / $20                    40
//   GPT Astra  $10 / $50                  100
// When a provider changes a price or a model is swapped, change the weight
// here — nothing else needs to move.
//
// Every plan is limited over three windows at once, so a week's allowance
// cannot be spent in one burst: calls per minute, credits per 5 hours and per
// week, both counted from the account's first use. They are counted per account
// (not per device or per session), under a hash of the account id. The numbers
// themselves, and how a long input is charged, live in ai-limits.ts.
import { sha256Hex } from "./auth.ts";
import type { Env } from "./env.ts";
import { DEFAULT_AI_LIMITS, inputMultiplier, type AILimits, type PlanBudget } from "./ai-limits.ts";

export const DEFAULT_MODEL = "openai-luna";

export const MODEL_CREDITS: Record<string, number> = {
  "openai-luna": 1,
  "claude-sonnet-5-5": 20,
  "openai-sol": 20,
  "openai-terra": 22,
  "claude-opus-5-5": 40,
  "openai-astra": 100,
};

// Non-chat features send long prompts and images, so they cost more than a
// chat turn on the same model.
export const KIND_MULTIPLIER: Record<string, number> = { chat: 1, rubric: 2, grade: 3, review: 3 };

const NO_BUDGET: PlanBudget = { perMinute: 0, fiveHours: 0, week: 0 };

/** What `plan` may spend; free (and anything unknown) gets nothing. */
export function planBudget(plan: string, limits: AILimits = DEFAULT_AI_LIMITS): PlanBudget {
  return (limits.plans as Record<string, PlanBudget>)[plan] ?? NO_BUDGET;
}

const UNKNOWN_MODEL_CREDITS = 100; // never cheaper than the dearest model

/**
 * Credits for one call: the model's weight, times the feature's, times how many
 * `freeChars` worth of input it sends (ai-limits.ts), so a long request costs
 * what it costs.
 */
export function creditCost(kind: string, modelId: string | undefined, inputChars = 0, limits: AILimits = DEFAULT_AI_LIMITS) {
  const model = MODEL_CREDITS[modelId ?? DEFAULT_MODEL] ?? UNKNOWN_MODEL_CREDITS;
  return model * (KIND_MULTIPLIER[kind] ?? 1) * inputMultiplier(inputChars, limits);
}

/**
 * The most input (in characters) a `kind` call on `model` can send and still
 * cost no more than the plan's 5-hour and weekly allowances; 0 when even the
 * shortest call costs more.
 */
export function affordableInputChars(plan: string, kind: string, model: string | undefined, limits: AILimits = DEFAULT_AI_LIMITS) {
  const budget = planBudget(plan, limits);
  const base = creditCost(kind, model, 0, limits);
  const steps = Math.floor(Math.min(budget.fiveHours, budget.week) / base);
  if (steps < 1) return 0;
  return limits.input.freeChars + (steps - 1) * limits.input.stepChars;
}

// The 5-hour counter got a new name with the move to weekly limits
// (2026-10-22): the old one may hold more than the new, smaller allowance.
function windowsFor(accountHash: string): { id: string; limitKey: keyof PlanBudget; name: string; seconds: number; perCall?: boolean }[] {
  return [
    { id: "minute", limitKey: "perMinute", name: `ai:cr:min:${accountHash}`, seconds: 60, perCall: true },
    { id: "fiveHours", limitKey: "fiveHours", name: `ai:cr:5h2:${accountHash}`, seconds: 5 * 3600 },
    { id: "week", limitKey: "week", name: `ai:cr:wk:${accountHash}`, seconds: 7 * 86_400 },
  ];
}

export const LIMIT_MESSAGES: Record<string, string> = {
  minute: "短い時間にたくさん送信されました。少し待ってからもう一度お試しください。",
  fiveHours: "5時間あたりのAI利用量の上限に達しました。しばらくしてからもう一度お試しください。",
  input: "入力が長すぎるため、このプランでは送れません。会話を新しく始めるか、内容を短くしてください。",
  week: "1週間あたりのAI利用量の上限に達しました。上限は最初に使ってから7日でリセットされます。上のプランでは利用量が増えます。",
  global: "現在AIが混み合っています。しばらくしてからもう一度お試しください。",
};

export async function accountCounterKey(sub: string | undefined, fallback: string) {
  return sub ? sha256Hex(`usage-account:${sub}`) : fallback;
}

/**
 * Takes `cost` credits for one call from every window, or from none: if any
 * window refuses, what the earlier ones took is given back. Also takes the same
 * credits from the plan's service-wide daily ceiling, `globalLimit`.
 *
 * The account's own windows are taken first and the service-wide ceiling last,
 * so an account over its own limits never takes from everyone's.
 *
 * Returns `{ ok: true, refund }` or `{ ok: false, window }` where `window` is
 * the first limit that was hit ("global" for the plan's service-wide one, and
 * "input" for a call dearer than a whole 5-hour or weekly allowance, which
 * takes nothing and could never pass). `refund()`
 * hands the credits back, for a call that fails before producing anything.
 */
/** What one call asks of the credit windows. */
export interface CreditRequest {
  accountKey: string;
  plan: string;
  /** The feature (`chat`, `rubric`, ...). */
  kind: string;
  model: string;
  /** Characters of input the call sends (images counted as ai-limits.ts says). */
  inputChars?: number;
  /** The plan's service-wide credits per day (ai-limits.ts's globalDailyCredits). */
  globalLimit: number;
  limits?: AILimits;
}

/** `ok: true` carries `refund`; `ok: false` carries the `window` that refused. (One shape, not a union: the test program is not strict, and does not narrow a union.) */
export interface CreditResult { ok: boolean; window?: string; refund?: () => Promise<void>; reserve?: (inputChars: number) => Promise<CreditResult> }

export async function consumeCredits(env: Env, { accountKey, plan, kind, model, inputChars = 0, globalLimit, limits = DEFAULT_AI_LIMITS }: CreditRequest): Promise<CreditResult> {
  const budget = planBudget(plan, limits);
  const initialCost = creditCost(kind, model, inputChars, limits);
  const taken: { name: string; amount: number; windowEndsAt: number }[] = [];
  // Retries retain the highest amount already reserved; the minute is taken once.
  let reservedCost = 0;
  let refunded = false;
  // Serialize adjustments and refunds for this request. Each counter still enforces
  // its own limit atomically across separate requests.
  let pending: Promise<unknown> = Promise.resolve();
  const serial = <T>(operation: () => Promise<T>): Promise<T> => {
    const next = pending.then(operation);
    pending = next.catch(() => {});
    return next;
  };
  const give = async (items: typeof taken) => {
    const results = await Promise.allSettled(items.map(({ name, amount, windowEndsAt }) =>
      Promise.resolve().then(() => env.RATE_COUNTER.getByName(name).give(amount, windowEndsAt))));
    const failed = results.filter(result => result.status === "rejected").length;
    if (failed) console.error(JSON.stringify({ event: "ai_credit_refund_failed", failed }));
  };
  const refund = () => serial(async () => {
    if (refunded) return;
    refunded = true;
    await give(taken);
  });

  if (budget.perMinute <= 0) return { ok: false, window: "minute" };
  const takeTo = async (cost: number, initial: boolean): Promise<CreditResult> => {
    if (refunded) throw new Error("Cannot reserve refunded credits");
    if (cost > Math.min(budget.fiveHours, budget.week)) return { ok: false, window: "input" };
    const delta = Math.max(0, cost - reservedCost);
    if (!initial && delta === 0) return { ok: true };
    const batch: typeof taken = [];
    try {
      for (const window of windowsFor(accountKey)) {
        if (window.perCall && !initial) continue;
        const amount = window.perCall ? 1 : delta;
        const result = await env.RATE_COUNTER.getByName(window.name).take(budget[window.limitKey], window.seconds, amount);
        if (!result.ok) {
          await give(batch);
          return { ok: false, window: window.id };
        }
        batch.push({ name: window.name, amount, windowEndsAt: result.windowEndsAt as number });
      }
      const globalName = `ai:global:${plan}`;
      const globalTake = await env.RATE_COUNTER.getByName(globalName).take(globalLimit, 86_400, delta);
      if (!globalTake.ok) {
        await give(batch);
        console.error(JSON.stringify({ message: "AI global ceiling reached", plan, limit: globalLimit }));
        return { ok: false, window: "global" };
      }
      batch.push({ name: globalName, amount: delta, windowEndsAt: globalTake.windowEndsAt as number });
      taken.push(...batch);
      reservedCost = Math.max(reservedCost, cost);
      return { ok: true };
    } catch (error) {
      await give(batch);
      throw error;
    }
  };
  const first = await takeTo(initialCost, true);
  if (!first.ok) return first;
  return { ok: true, refund, reserve: chars => serial(() => takeTo(creditCost(kind, model, chars, limits), false)) };
}

/**
 * What is left of the plan's tightest credit window (five hours or week),
 * without spending anything — the figure the app shows as "remaining".
 * The per-minute window is a burst guard, not an allowance, so it is skipped.
 */
export async function creditUsage(env: Env, { accountKey, plan, limits = DEFAULT_AI_LIMITS }: Pick<CreditRequest, "accountKey" | "plan" | "limits">) {
  const budget = planBudget(plan, limits);
  let tightest = null;
  for (const window of windowsFor(accountKey)) {
    if (window.perCall) continue;
    const limit = budget[window.limitKey];
    const usage = await env.RATE_COUNTER.getByName(window.name).usage(limit, window.seconds);
    if (!tightest || usage.remaining < tightest.remaining) tightest = usage;
  }
  return tightest;
}
