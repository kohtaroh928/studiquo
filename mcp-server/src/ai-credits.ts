// What one AI call costs, and how much each plan may spend, in "credits".
//
// A credit is a fixed slice of real model cost (about $0.0007, one cheap
// Luna call), so a heavy model uses many credits and a light one uses one:
// the plan screen can promise "月1,500クレジット" and the Worker's bill stays
// bounded whichever models a student picks. Prices behind the weights (per
// 1M tokens, 3,000 input + 800 output tokens assumed per call; checked on the
// providers' price pages 2026-10-12):
//   GPT Luna   $0.10 / $0.50                1
//   Sonnet 5.5 $2 / $10                    20
//   GPT Sol    $2 / $10                    20
//   GPT Terra  $2 / $12                    22
//   Opus 5.5   $4 / $20                    40
//   GPT Astra  $10 / $50                  100
// When a provider changes a price or a model is swapped, change the weight
// here — nothing else needs to move.
//
// Every plan is limited over four windows at once, so a month's allowance
// cannot be spent in one burst: calls per minute, credits per 5 hours, per
// day (Japan time) and per month (Japan time). They are counted per account
// (not per device or per session), under a hash of the account id.
import { sha256Hex } from "./auth.ts";
import type { Env } from "./env.ts";

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

export const PLAN_BUDGETS: Record<string, Record<string, number>> = {
  free: { perMinute: 0, fiveHours: 0, day: 0, month: 0 },
  // Standard is sized as "about 120 Luna chat turns a month" (1 credit each).
  standard: { perMinute: 5, fiveHours: 40, day: 60, month: 120 },
  plus: { perMinute: 10, fiveHours: 400, day: 600, month: 1500 },
  pro: { perMinute: 20, fiveHours: 1000, day: 1500, month: 4000 },
};

const UNKNOWN_MODEL_CREDITS = 100; // never cheaper than the dearest model

export function creditCost(kind: string, modelId: string) {
  const model = MODEL_CREDITS[modelId ?? DEFAULT_MODEL] ?? UNKNOWN_MODEL_CREDITS;
  return model * (KIND_MULTIPLIER[kind] ?? 1);
}

const JST_OFFSET_MS = 9 * 3_600_000;
const pad = (n: number) => String(n).padStart(2, "0");

function windowsFor(accountHash: any, now: number) {
  const jst = new Date(now + JST_OFFSET_MS);
  const month = `${jst.getUTCFullYear()}${pad(jst.getUTCMonth() + 1)}`;
  const day = `${month}${pad(jst.getUTCDate())}`;
  // Day and month counters are named by their calendar period, so the window
  // length only needs to outlive the period (and lets the storage be reclaimed).
  return [
    { id: "minute", limitKey: "perMinute", name: `ai:cr:min:${accountHash}`, seconds: 60, perCall: true },
    { id: "fiveHours", limitKey: "fiveHours", name: `ai:cr:5h:${accountHash}`, seconds: 5 * 3600 },
    { id: "day", limitKey: "day", name: `ai:cr:day:${day}:${accountHash}`, seconds: 2 * 86_400 },
    { id: "month", limitKey: "month", name: `ai:cr:mon:${month}:${accountHash}`, seconds: 40 * 86_400 },
  ];
}

export const LIMIT_MESSAGES: Record<string, string> = {
  minute: "短い時間にたくさん送信されました。少し待ってからもう一度お試しください。",
  fiveHours: "5時間あたりのAI利用量の上限に達しました。しばらくしてからもう一度お試しください。",
  day: "今日のAI利用量の上限に達しました。明日また使えます。",
  month: "今月のAI利用量の上限に達しました。来月また使えます。上のプランでは利用量が増えます。",
  global: "現在AIが混み合っています。しばらくしてからもう一度お試しください。",
};

export async function accountCounterKey(sub: string | undefined, fallback: string) {
  return sub ? sha256Hex(`usage-account:${sub}`) : fallback;
}

/**
 * Takes `cost` credits for one call from every window, or from none: if any
 * window refuses, what the earlier ones took is given back. Also counts the
 * call against the service-wide daily cap for `globalBucket`.
 *
 * Returns `{ ok: true, refund }` or `{ ok: false, window }` where `window` is
 * the first limit that was hit ("global" for the service-wide one). `refund()`
 * hands the credits back, for a call that fails before producing anything.
 */
export async function consumeCredits(env: Env, { accountKey, plan, kind, model, globalBucket, globalLimit, now = Date.now() }: any) {
  const budget = PLAN_BUDGETS[plan] ?? PLAN_BUDGETS.free;
  const cost = creditCost(kind, model);
  const taken: { name: string; amount: number; windowEndsAt: number }[] = [];
  // Every give is attempted even if one fails, and each goes back to the exact
  // window it was taken from. Safe to call once; a second call does nothing.
  let refunded = false;
  const refund = async () => {
    if (refunded) return;
    refunded = true;
    await Promise.allSettled(taken.map(({ name, amount, windowEndsAt }) =>
      env.RATE_COUNTER.getByName(name).give(amount, windowEndsAt)));
  };

  const globalName = `ai:global:${globalBucket}`;
  const globalTake = await env.RATE_COUNTER.getByName(globalName).take(globalLimit, 86_400, 1);
  if (!globalTake.ok) return { ok: false, window: "global" };
  taken.push({ name: globalName, amount: 1, windowEndsAt: globalTake.windowEndsAt as number });

  for (const window of windowsFor(accountKey, now)) {
    const amount = window.perCall ? 1 : cost;
    const result = await env.RATE_COUNTER.getByName(window.name).take(budget[window.limitKey], window.seconds, amount);
    if (!result.ok) {
      await refund();
      return { ok: false, window: window.id };
    }
    taken.push({ name: window.name, amount, windowEndsAt: result.windowEndsAt as number });
  }
  return { ok: true, refund };
}

/**
 * What is left of the plan's tightest credit window (day, five hours or
 * month), without spending anything — the figure the app shows as "remaining".
 * The per-minute window is a burst guard, not an allowance, so it is skipped.
 */
export async function creditUsage(env: Env, { accountKey, plan, now = Date.now() }: any) {
  const budget = PLAN_BUDGETS[plan] ?? PLAN_BUDGETS.free;
  let tightest = null;
  for (const window of windowsFor(accountKey, now)) {
    if (window.perCall) continue;
    const limit = budget[window.limitKey];
    const usage = await env.RATE_COUNTER.getByName(window.name).usage(limit, window.seconds);
    if (!tightest || usage.remaining < tightest.remaining) tightest = usage;
  }
  return tightest;
}
