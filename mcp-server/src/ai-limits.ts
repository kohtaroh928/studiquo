// Every number that bounds AI use, in one place, so they can be retuned before
// (and after) release without touching the code that enforces them.
//
// Two ways to change them:
//   - edit DEFAULT_AI_LIMITS below (needs a deploy), or
//   - set the `AI_LIMITS` variable to a JSON object holding only the values to
//     change, e.g. {"plans":{"pro":{"week":1200}},"global":{"headroom":4}}.
//     It is merged over the defaults; an unknown key or a value that is not a
//     positive number is ignored (and logged), so a typo can never lift a limit.
//
// What each part bounds:
//   plans  — one account: calls per minute, credits per 5 hours and per week.
//            Both windows start at the account's first use and last 5 hours /
//            7 days from there (RateCounter's fixed windows, counter-state.ts).
//   input  — how a long request is charged (AI-2 in
//            docs/API_SECURITY_AUDIT_2026-10-22.md): up to `freeChars` of input
//            costs the model's base credits, and every further `stepChars`
//            adds that much again. A chat sends at most `chatMaxChars`, oldest
//            turns dropped first. An image counts as `imageChars`.
//   global — the service-wide daily ceiling per plan, in dollars of AI API cost
//            (AI-3): each plan may spend, per day, `headroom` times what its
//            paying subscribers would use spreading their weekly allowance
//            evenly — never less than `floorDollarsPerDay`. It grows with the
//            number of subscribers, so growth alone does not stop the service.
//
// The app's plans screen states the per-account numbers
// (studiquo/Models/PlanAllowance.swift), so a change to `plans` must be made
// there too, or the screen promises what the Worker will not give.
import type { Env } from "./env.ts";

export type PaidPlan = "standard" | "plus" | "pro";
export const PAID_PLANS: PaidPlan[] = ["standard", "plus", "pro"];

export interface PlanBudget { perMinute: number; fiveHours: number; week: number }

export interface AILimits {
  plans: Record<PaidPlan, PlanBudget>;
  input: { freeChars: number; stepChars: number; chatMaxChars: number; imageChars: number };
  global: { dollarsPerCredit: number; headroom: number; floorDollarsPerDay: Record<PaidPlan, number> };
}

export const DEFAULT_AI_LIMITS: AILimits = {
  plans: {
    standard: { perMinute: 5, fiveHours: 10, week: 30 },
    plus: { perMinute: 10, fiveHours: 100, week: 350 },
    pro: { perMinute: 20, fiveHours: 250, week: 920 },
  },
  input: { freeChars: 12_000, stepChars: 6_000, chatMaxChars: 60_000, imageChars: 4_000 },
  global: {
    // One credit is about one cheap Luna call (ai-credits.ts's header).
    dollarsPerCredit: 0.0007,
    headroom: 3,
    floorDollarsPerDay: { standard: 5, plus: 10, pro: 15 },
  },
};

// Remembered per isolate: the variable only changes with a deploy, which
// starts new isolates.
const parsed = new WeakMap<object, AILimits>();

export function aiLimits(env: Env): AILimits {
  const raw = env.AI_LIMITS;
  if (!raw) return DEFAULT_AI_LIMITS;
  const cached = parsed.get(env);
  if (cached) return cached;
  const limits = mergeLimits(raw);
  parsed.set(env, limits);
  return limits;
}

/** Overrides from `raw` (a JSON string) laid over the defaults; anything unusable is skipped and logged. */
export function mergeLimits(raw: string): AILimits {
  const limits: AILimits = structuredClone(DEFAULT_AI_LIMITS);
  const ignored: string[] = [];
  let overrides: unknown;
  try {
    overrides = JSON.parse(raw);
  } catch {
    console.error(JSON.stringify({ message: "AI_LIMITS is not valid JSON; the defaults apply" }));
    return limits;
  }
  // Walks the defaults' shape, so only keys that exist there can be set.
  const apply = (target: Record<string, unknown>, source: unknown, path: string) => {
    if (!isObject(source)) {
      ignored.push(path || "(root)");
      return;
    }
    for (const [name, value] of Object.entries(source)) {
      const where = path ? `${path}.${name}` : name;
      // Own keys only: `in` would also accept inherited ones like "__proto__".
      if (!Object.hasOwn(target, name)) {
        ignored.push(where);
      } else if (isObject(target[name])) {
        apply(target[name] as Record<string, unknown>, value, where);
      } else if (typeof value === "number" && Number.isFinite(value) && value > 0) {
        target[name] = value;
      } else {
        ignored.push(where);
      }
    }
  };
  apply(limits as unknown as Record<string, unknown>, overrides, "");
  if (ignored.length) console.error(JSON.stringify({ message: "AI_LIMITS values ignored", keys: ignored.slice(0, 20) }));
  return limits;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * How many times the model's base credits one request costs, from how much it
 * sends: 1 up to `freeChars`, then one more for every `stepChars` (or part).
 */
export function inputMultiplier(inputChars: number, limits: AILimits = DEFAULT_AI_LIMITS) {
  const { freeChars, stepChars } = limits.input;
  const over = Math.max(0, Math.floor(inputChars) - freeChars);
  return 1 + Math.ceil(over / stepChars);
}

/** A plan's share of the service-wide daily ceiling, in credits. */
export function globalDailyCredits(plan: PaidPlan, subscribers: number, limits: AILimits = DEFAULT_AI_LIMITS) {
  const { dollarsPerCredit, headroom, floorDollarsPerDay } = limits.global;
  const floor = floorDollarsPerDay[plan] / dollarsPerCredit;
  const scaled = Math.max(0, subscribers) * (limits.plans[plan].week / 7) * headroom;
  return Math.floor(Math.max(floor, scaled));
}

// --- subscriber counts --------------------------------------------------------

const COUNT_TTL_MS = 10 * 60_000;
const counted = new WeakMap<object, { at: number; counts: Record<PaidPlan, number> }>();

/**
 * Paying accounts per plan, from the subscribers table the RevenueCat webhook
 * keeps (admin.ts), plus the accounts moved to Standard at launch. Read at most
 * once every 10 minutes per isolate. When it cannot be read the last count is
 * kept, and with none yet each plan gets only its floor.
 */
export async function subscriberCounts(env: Env, productPlans: Record<string, string>, legacyCounts: boolean, now = Date.now()) {
  const memo = counted.get(env);
  if (memo && now - memo.at < COUNT_TTL_MS) return memo.counts;
  const counts: Record<PaidPlan, number> = { standard: 0, plus: 0, pro: 0 };
  if (!env.ADMIN_DB) return counts;
  try {
    const rows = await env.ADMIN_DB.prepare(
      `SELECT product_id, COUNT(*) AS n FROM subscribers
       WHERE status IN ('active', 'billing_issue') AND (expires_at IS NULL OR expires_at <= 0 OR expires_at > ?)
       GROUP BY product_id`
    ).bind(now).all<{ product_id: string; n: number }>();
    for (const row of rows.results ?? []) {
      const plan = productPlans[row.product_id] as PaidPlan | undefined;
      if (plan && plan in counts) counts[plan] += Number(row.n) || 0;
    }
    if (legacyCounts) {
      const legacy = await env.ADMIN_DB.prepare("SELECT COUNT(*) AS n FROM legacy_standard_accounts").first<{ n: number }>();
      counts.standard += Number(legacy?.n) || 0;
    }
  } catch (error) {
    console.error(JSON.stringify({ message: "AI subscriber count failed", error: error instanceof Error ? error.message : String(error) }));
    return memo?.counts ?? counts;
  }
  counted.set(env, { at: now, counts });
  return counts;
}
