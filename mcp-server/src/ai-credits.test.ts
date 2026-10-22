import assert from "node:assert/strict";
import test from "node:test";
import { consumeCredits, creditCost, PLAN_BUDGETS, MODEL_CREDITS } from "./ai-credits.ts";
import type { LooseEnv } from "./test-env.ts";
import type { Untyped } from "./test-env.ts";

function counters() {
  const used = new Map();
  return {
    used,
    getByName(name: string) {
      return {
        async take(limit: number, _seconds: string, amount = 1) {
          const next = (used.get(name) ?? 0) + amount;
          if (next > limit) return { ok: false };
          used.set(name, next);
          return { ok: true, windowEndsAt: 1 };
        },
        async give(amount = 1) { used.set(name, Math.max(0, (used.get(name) ?? 0) - amount)); },
      };
    },
  };
}

const call = (env: Untyped, overrides = {}) => consumeCredits(env, {
  accountKey: "acct", plan: "pro", kind: "chat", model: "openai-luna",
  globalBucket: "chat", globalLimit: 1_000_000, now: Date.UTC(2026, 9, 12, 3, 0, 0), ...overrides,
});

test("credit weights match the published plan: Luna 1, Sonnet/Sol 20, Terra 22, Opus 40, Astra 100", () => {
  assert.deepEqual(
    ["openai-luna", "claude-sonnet-5-5", "openai-sol", "openai-terra", "claude-opus-5-5", "openai-astra"].map(id => MODEL_CREDITS[id]),
    [1, 20, 20, 22, 40, 100],
  );
});

test("non-chat features cost more than a chat turn on the same model", () => {
  assert.equal(creditCost("chat", undefined), 1);
  assert.equal(creditCost("rubric", undefined), 2);
  assert.equal(creditCost("grade", undefined), 3);
  assert.equal(creditCost("review", undefined), 3);
  assert.equal(creditCost("chat", "some-future-model"), 100);
});

test("the published budgets are what the Worker enforces", () => {
  assert.deepEqual(PLAN_BUDGETS.standard, { perMinute: 5, fiveHours: 40, day: 60, month: 120 });
  assert.deepEqual(PLAN_BUDGETS.plus, { perMinute: 10, fiveHours: 400, day: 600, month: 1500 });
  assert.deepEqual(PLAN_BUDGETS.pro, { perMinute: 20, fiveHours: 1000, day: 1500, month: 4000 });
});

// Clears the minute / 5-hour / day counters between calls so only the month
// window is being tested.
async function spendUntilStopped(env: { RATE_COUNTER: any; }, options: {} | undefined, limit = 5000) {
  let ok = 0;
  for (let i = 0; i < limit; i += 1) {
    for (const name of [...env.RATE_COUNTER.used.keys()]) if (!name.includes(":mon:") && !name.startsWith("ai:global:")) env.RATE_COUNTER.used.delete(name);
    const result = await call(env, options);
    if (!result.ok) return { ok, window: result.window };
    ok += 1;
  }
  return { ok, window: undefined };
}

test("pro fits exactly 40 Astra calls a month", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await spendUntilStopped(env, { plan: "pro", model: "openai-astra" }), { ok: 40, window: "month" });
});

test("pro fits exactly 100 Opus calls a month", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await spendUntilStopped(env, { plan: "pro", model: "claude-opus-5-5" }), { ok: 100, window: "month" });
});

test("plus fits 75 Sonnet calls (and 1,500 Luna calls) a month", async () => {
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "plus", model: "claude-sonnet-5-5" }), { ok: 75, window: "month" });
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "plus", model: "openai-luna" }), { ok: 1500, window: "month" });
});

test("a day's Astra calls on pro stop at 15, and 10 within 5 hours", async () => {
  const env = { RATE_COUNTER: counters() };
  const burst = async () => {
    let ok = 0;
    for (let i = 0; i < 30; i += 1) {
      for (const name of [...env.RATE_COUNTER.used.keys()]) if (name.startsWith("ai:cr:min:")) env.RATE_COUNTER.used.delete(name);
      const result = await call(env, { plan: "pro", model: "openai-astra" });
      if (!result.ok) return { ok, window: result.window };
      ok += 1;
    }
    return { ok };
  };
  assert.deepEqual(await burst(), { ok: 10, window: "fiveHours" });
});

test("the month window stops spending at the monthly total", async () => {
  const env = { RATE_COUNTER: counters() };
  // Plus, Luna (1 credit): 1,500 a month. Use a new 5-hour/day/minute bucket each time
  // by varying the clock, but keep the same month.
  let ok = 0;
  let stoppedBy;
  for (let i = 0; i < 1600; i += 1) {
    const now = Date.UTC(2026, 9, 1 + (i % 28), (i * 7) % 24, i % 60, 0);
    // keep the minute/5h/day counters out of the way
    for (const name of [...env.RATE_COUNTER.used.keys()]) if (!name.includes(":mon:")) env.RATE_COUNTER.used.delete(name);
    const result = await call(env, { plan: "plus", model: "openai-luna", now });
    if (result.ok) ok += 1; else { stoppedBy = result.window; break; }
  }
  assert.equal(ok, 1500);
  assert.equal(stoppedBy, "month");
});

test("the day window follows Japan time: 14:59 UTC and 15:00 UTC are different days", async () => {
  const env = { RATE_COUNTER: counters() };
  await call(env, { plan: "plus", now: Date.UTC(2026, 9, 12, 14, 59, 0) });
  await call(env, { plan: "plus", now: Date.UTC(2026, 9, 12, 15, 0, 0) });
  const dayKeys = [...env.RATE_COUNTER.used.keys()].filter(name => name.startsWith("ai:cr:day:"));
  assert.equal(dayKeys.length, 2);
  assert.ok(dayKeys[0].includes("20261012") && dayKeys[1].includes("20261013"));
});

test("the month rolls over at midnight Japan time", async () => {
  const env = { RATE_COUNTER: counters() };
  await call(env, { plan: "plus", now: Date.UTC(2026, 9, 31, 14, 59, 0) });
  await call(env, { plan: "plus", now: Date.UTC(2026, 9, 31, 15, 0, 0) });
  const monthKeys = [...env.RATE_COUNTER.used.keys()].filter(name => name.startsWith("ai:cr:mon:"));
  assert.equal(monthKeys.length, 2);
});

test("a refusal by the month window gives back the minute, 5-hour and day credits and the global count", async () => {
  const env = { RATE_COUNTER: counters() };
  const now = Date.UTC(2026, 9, 12, 3, 0, 0);
  env.RATE_COUNTER.used.set("ai:cr:mon:202610:acct", 119); // standard month = 120
  const refused = await call(env, { plan: "standard", kind: "grade", now }); // costs 12
  assert.deepEqual(refused, { ok: false, window: "month" });
  const leftovers = [...env.RATE_COUNTER.used.entries()].filter(([name, value]) => name !== "ai:cr:mon:202610:acct" && value !== 0);
  assert.deepEqual(leftovers, []);
});

test("the service-wide cap still stops everyone, and costs the account nothing", async () => {
  const env = { RATE_COUNTER: counters() };
  env.RATE_COUNTER.used.set("ai:global:chat", 5);
  const result = await call(env, { plan: "pro", globalLimit: 5 });
  assert.deepEqual(result, { ok: false, window: "global" });
  assert.equal([...env.RATE_COUNTER.used.keys()].filter(name => name.startsWith("ai:cr:")).length, 0);
});

test("a refusal by the day window also gives back the minute and 5-hour credits", async () => {
  const env = { RATE_COUNTER: counters() };
  const now = Date.UTC(2026, 9, 12, 3, 0, 0);
  env.RATE_COUNTER.used.set("ai:cr:day:20261012:acct", 60); // standard day = 60
  assert.deepEqual(await call(env, { plan: "standard", now }), { ok: false, window: "day" }); // costs 1
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:min:acct") ?? 0, 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:5h:acct") ?? 0, 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:global:chat") ?? 0, 0);
});

test("refund() hands everything back once, and a second call does nothing", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { plan: "pro", model: "claude-opus-5-5" });
  assert.equal(result.ok, true);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:mon:202610:acct"), 40);
  await result.refund!();
  await result.refund!();
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});

test("a refund still returns the other windows when one give throws", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { plan: "pro", model: "claude-opus-5-5" });
  const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
  (env.RATE_COUNTER as { getByName: (name: string) => unknown }).getByName = (name: string) => name.startsWith("ai:cr:5h:")
    ? { async give() { throw new Error("boom"); } }
    : real(name);
  await result.refund!(); // must not throw
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:mon:202610:acct"), 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:5h:acct"), 40, "the failed give leaves only its own window held");
});

test("free has no budget at all", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await call(env, { plan: "free" }), { ok: false, window: "minute" });
});
