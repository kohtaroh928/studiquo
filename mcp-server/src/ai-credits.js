// What one AI call costs, and how much each plan may spend, in "credits".
//
// A credit is a fixed slice of real model cost (about $0.0007, one cheap
// Luna call), so a heavy model uses many credits and a light one uses one:
// the plan screen can promise "月1,500クレジット" and the Worker's bill stays
// bounded whichever models a student picks. Prices behind the weights (per
// 1M tokens, 3,000 input + 800 output tokens assumed per call; checked on the
// providers' price pages 2026-10-12):
//   Gemini Flash-Lite  (price not checked)  1
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
import { sha256Hex } from "./auth.js";

export const DEFAULT_MODEL = "gemini-3.5-flash-lite";

export const MODEL_CREDITS = {
  "gemini-3.5-flash-lite": 1,
  "openai-luna": 1,
  "claude-sonnet-5-5": 20,
  "openai-sol": 20,
  "openai-terra": 22,
  "claude-opus-5-5": 40,
  "openai-astra": 100,
};

// Non-chat features send long prompts and images, so they cost more than a
// chat turn on the same model.
export const KIND_MULTIPLIER = { chat: 1, rubric: 2, grade: 3, review: 3 };

export const PLAN_BUDGETS = {
  free: { perMinute: 0, fiveHours: 0, day: 0, month: 0 },
  standard: { perMinute: 5, fiveHours: 10, day: 15, month: 30 },
  plus: { perMinute: 10, fiveHours: 400, day: 600, month: 1500 },
  pro: { perMinute: 20, fiveHours: 1000, day: 1500, month: 4000 },
};

const UNKNOWN_MODEL_CREDITS = 100; // never cheaper than the dearest model

export function creditCost(kind, modelId) {
  const model = MODEL_CREDITS[modelId ?? DEFAULT_MODEL] ?? UNKNOWN_MODEL_CREDITS;
  return model * (KIND_MULTIPLIER[kind] ?? 1);
}

const JST_OFFSET_MS = 9 * 3_600_000;
const pad = n => String(n).padStart(2, "0");

function windowsFor(accountHash, now) {
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

export const LIMIT_MESSAGES = {
  minute: "短い時間にたくさん送信されました。少し待ってからもう一度お試しください。",
  fiveHours: "5時間あたりのAI利用量の上限に達しました。しばらくしてからもう一度お試しください。",
  day: "今日のAI利用量の上限に達しました。明日また使えます。",
  month: "今月のAI利用量の上限に達しました。来月また使えます。上のプランでは利用量が増えます。",
  global: "現在AIが混み合っています。しばらくしてからもう一度お試しください。",
};

export async function accountCounterKey(sub, fallback) {
  return sub ? sha256Hex(`usage-account:${sub}`) : fallback;
}

/**
 * Takes `cost` credits for one call from every window, or from none: if any
 * window refuses, what the earlier ones took is given back. Also counts the
 * call against the service-wide daily cap for `globalBucket`.
 *
 * Returns `{ ok: true }` or `{ ok: false, window }` where `window` is the
 * first limit that was hit ("global" for the service-wide one).
 */
export async function consumeCredits(env, { accountKey, plan, kind, model, globalBucket, globalLimit, now = Date.now() }) {
  const budget = PLAN_BUDGETS[plan] ?? PLAN_BUDGETS.free;
  const cost = creditCost(kind, model);
  const taken = [];
  const refund = async () => {
    for (const { name, amount } of taken) await env.RATE_COUNTER.getByName(name).release(amount);
  };

  const globalName = `ai:global:${globalBucket}`;
  if (!(await env.RATE_COUNTER.getByName(globalName).bump(globalLimit, 86_400))) {
    return { ok: false, window: "global" };
  }
  taken.push({ name: globalName, amount: 1 });

  for (const window of windowsFor(accountKey, now)) {
    const amount = window.perCall ? 1 : cost;
    if (!(await env.RATE_COUNTER.getByName(window.name).bump(budget[window.limitKey], window.seconds, amount))) {
      await refund();
      return { ok: false, window: window.id };
    }
    taken.push({ name: window.name, amount });
  }
  return { ok: true };
}
