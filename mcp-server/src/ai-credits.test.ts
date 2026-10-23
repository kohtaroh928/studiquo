import assert from "node:assert/strict";
import test from "node:test";
import { affordableInputChars, consumeCredits, creditCost, planBudget, MODEL_CREDITS } from "./ai-credits.ts";
import { mergeLimits } from "./ai-limits.ts";
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
  globalLimit: 1_000_000, ...overrides,
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
  assert.deepEqual(planBudget("standard"), { perMinute: 5, fiveHours: 10, week: 30 });
  assert.deepEqual(planBudget("plus"), { perMinute: 10, fiveHours: 100, week: 350 });
  assert.deepEqual(planBudget("pro"), { perMinute: 20, fiveHours: 250, week: 920 });
  assert.deepEqual(planBudget("free"), { perMinute: 0, fiveHours: 0, week: 0 });
  assert.deepEqual(planBudget("something-else"), { perMinute: 0, fiveHours: 0, week: 0 });
});

test("a long input costs more: free up to 12,000 characters, then once more per 6,000", () => {
  assert.equal(creditCost("chat", "openai-luna", 0), 1);
  assert.equal(creditCost("chat", "openai-luna", 12_000), 1);
  assert.equal(creditCost("chat", "openai-luna", 12_001), 2);
  assert.equal(creditCost("chat", "openai-luna", 18_000), 2);
  assert.equal(creditCost("chat", "openai-luna", 18_001), 3);
  assert.equal(creditCost("chat", "openai-luna", 60_000), 9);
  assert.equal(creditCost("chat", "openai-astra", 60_000), 900);
  assert.equal(creditCost("grade", "openai-luna", 74_000), 3 * 12);
});

// Clears the minute and 5-hour counters between calls so only the week
// window is being tested.
async function spendUntilStopped(env: { RATE_COUNTER: any; }, options: {} | undefined, limit = 5000) {
  let ok = 0;
  for (let i = 0; i < limit; i += 1) {
    for (const name of [...env.RATE_COUNTER.used.keys()]) if (!name.startsWith("ai:cr:wk:") && !name.startsWith("ai:global:")) env.RATE_COUNTER.used.delete(name);
    const result = await call(env, options);
    if (!result.ok) return { ok, window: result.window };
    ok += 1;
  }
  return { ok, window: undefined };
}

test("pro fits 9 Astra calls a week", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await spendUntilStopped(env, { plan: "pro", model: "openai-astra" }), { ok: 9, window: "week" });
});

test("plus fits 17 Sol calls (and 350 Luna calls) a week", async () => {
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "plus", model: "openai-sol" }), { ok: 17, window: "week" });
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "plus", model: "openai-luna" }), { ok: 350, window: "week" });
});

test("standard fits 30 Luna chat turns a week", async () => {
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "standard" }), { ok: 30, window: "week" });
});

test("a request costing more than the 5-hour allowance is refused as too long, taking nothing", async () => {
  // 60,000 characters on Astra cost 900, more than pro's 250 per 5 hours: it
  // could never be sent, so it is not refused as "wait for the window".
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await call(env, { plan: "pro", model: "openai-astra", inputChars: 60_000 }), { ok: false, window: "input" });
  assert.equal(env.RATE_COUNTER.used.size, 0);
  // Luna stays usable for the same long input: 9 credits.
  assert.equal((await call({ RATE_COUNTER: counters() }, { plan: "pro", inputChars: 60_000 })).ok, true);
  // Exactly the 5-hour allowance is still sendable.
  assert.equal((await call({ RATE_COUNTER: counters() }, { plan: "standard", inputChars: affordableInputChars("standard", "chat", "openai-luna") })).ok, true);
});

test("the most input a plan can pay for, per model and feature", () => {
  // pro, Astra: 250 / 100 = 2 steps -> 12,000 + 6,000.
  assert.equal(affordableInputChars("pro", "chat", "openai-astra"), 18_000);
  // standard, Luna chat: 10 steps -> 12,000 + 9 x 6,000.
  assert.equal(affordableInputChars("standard", "chat", "openai-luna"), 66_000);
  // standard, grading (x3): 3 steps.
  assert.equal(affordableInputChars("standard", "grade", "openai-luna"), 24_000);
  assert.equal(affordableInputChars("free", "chat", "openai-luna"), 0);
  for (const [plan, kind, model] of [["pro", "chat", "openai-astra"], ["plus", "chat", "openai-sol"], ["standard", "grade", "openai-luna"]]) {
    const most = affordableInputChars(plan, kind, model);
    assert.ok(creditCost(kind, model, most) <= planBudget(plan).fiveHours, `${plan} ${kind} ${model} fits`);
    assert.ok(creditCost(kind, model, most + 1) > planBudget(plan).fiveHours, `${plan} ${kind} ${model} is the most`);
  }
});

test("Astra calls on pro stop at 2 within 5 hours", async () => {
  const env = { RATE_COUNTER: counters() };
  let ok = 0;
  let window;
  for (let i = 0; i < 30; i += 1) {
    for (const name of [...env.RATE_COUNTER.used.keys()]) if (name.startsWith("ai:cr:min:")) env.RATE_COUNTER.used.delete(name);
    const result = await call(env, { plan: "pro", model: "openai-astra" });
    if (!result.ok) { window = result.window; break; }
    ok += 1;
  }
  assert.deepEqual({ ok, window }, { ok: 2, window: "fiveHours" });
});

test("a refusal by the week window gives back the minute and 5-hour credits and the global ones", async () => {
  const env = { RATE_COUNTER: counters() };
  env.RATE_COUNTER.used.set("ai:cr:wk:acct", 29); // standard week = 30
  const refused = await call(env, { plan: "standard", kind: "review" }); // costs 3
  assert.deepEqual(refused, { ok: false, window: "week" });
  const leftovers = [...env.RATE_COUNTER.used.entries()].filter(([name, value]) => name !== "ai:cr:wk:acct" && value !== 0);
  assert.deepEqual(leftovers, []);
});

test("the plan's service-wide ceiling stops its users, and costs the account nothing", async () => {
  const env = { RATE_COUNTER: counters() };
  env.RATE_COUNTER.used.set("ai:global:pro", 5);
  const result = await call(env, { plan: "pro", globalLimit: 5 });
  assert.deepEqual(result, { ok: false, window: "global" });
  assert.ok([...env.RATE_COUNTER.used.entries()].filter(([name]) => name.startsWith("ai:cr:")).every(([, value]) => value === 0));
});

test("an account over its own limits takes nothing from the service-wide ceiling", async () => {
  const env = { RATE_COUNTER: counters() };
  env.RATE_COUNTER.used.set("ai:cr:wk:acct", 30); // standard week = 30
  assert.deepEqual(await call(env, { plan: "standard" }), { ok: false, window: "week" });
  assert.equal(env.RATE_COUNTER.used.get("ai:global:standard") ?? 0, 0);
});

test("the service-wide ceiling counts credits, not calls, and is kept per plan", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.equal((await call(env, { plan: "pro", model: "openai-astra" })).ok, true);
  assert.equal(env.RATE_COUNTER.used.get("ai:global:pro"), 100);
  assert.equal((await call(env, { plan: "plus", model: "openai-sol", accountKey: "other" })).ok, true);
  assert.equal(env.RATE_COUNTER.used.get("ai:global:plus"), 20);
  // Pro's ceiling being full does not stop plus.
  env.RATE_COUNTER.used.set("ai:global:pro", 1_000_000);
  assert.deepEqual(await call(env, { plan: "pro", accountKey: "third" }), { ok: false, window: "global" });
  assert.equal((await call(env, { plan: "plus", accountKey: "fourth" })).ok, true);
});

test("a refusal by the 5-hour window also gives back the minute credits and the global ones", async () => {
  const env = { RATE_COUNTER: counters() };
  env.RATE_COUNTER.used.set("ai:cr:5h2:acct", 10); // standard 5 hours = 10
  assert.deepEqual(await call(env, { plan: "standard" }), { ok: false, window: "fiveHours" }); // costs 1
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:min:acct") ?? 0, 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:global:standard") ?? 0, 0);
});

test("refund() hands everything back once, and a second call does nothing", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { plan: "pro", model: "claude-opus-5-5", inputChars: 20_000 });
  assert.equal(result.ok, true);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:wk:acct"), 40 * 3);
  await result.refund!();
  await result.refund!();
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});

test("a refund still returns the other windows when one give throws", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { plan: "pro", model: "claude-opus-5-5" });
  const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
  (env.RATE_COUNTER as { getByName: (name: string) => unknown }).getByName = (name: string) => name.startsWith("ai:cr:5h2:")
    ? { async give() { throw new Error("boom"); } }
    : real(name);
  await result.refund!(); // must not throw
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:wk:acct"), 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:5h2:acct"), 40, "the failed give leaves only its own window held");
});

test("free has no budget at all, and takes nothing from the service-wide ceiling", async () => {
  const env = { RATE_COUNTER: counters() };
  assert.deepEqual(await call(env, { plan: "free" }), { ok: false, window: "minute" });
  assert.equal(env.RATE_COUNTER.used.size, 0);
});

test("budgets set through AI_LIMITS are the ones enforced", async () => {
  const limits = mergeLimits(JSON.stringify({ plans: { standard: { week: 3 } } }));
  assert.deepEqual(await spendUntilStopped({ RATE_COUNTER: counters() }, { plan: "standard", limits }), { ok: 3, window: "week" });
});


test("additional input reserves only the difference once, including concurrent retries", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env);
  const [a, b, c] = await Promise.all([result.reserve!(12001), result.reserve!(18001), result.reserve!(12001)]);
  assert.ok(a.ok && b.ok && c.ok);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:min:acct"), 1);
  for (const name of ["ai:cr:5h2:acct", "ai:cr:wk:acct", "ai:global:pro"]) assert.equal(env.RATE_COUNTER.used.get(name), 3);
  await Promise.all([result.refund!(), result.refund!()]);
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});

test("additional reservations refuse each exhausted window and roll back partial takes", async () => {
  for (const [name, limit, expected] of [["ai:cr:5h2:acct", 10, "fiveHours"], ["ai:cr:wk:acct", 30, "week"], ["ai:global:standard", 5, "global"]] as const) {
    const env = { RATE_COUNTER: counters() };
    const result = await call(env, { plan: "standard", globalLimit: 5 });
    env.RATE_COUNTER.used.set(name, limit);
    assert.equal((await result.reserve!(12001)).window, expected);
    assert.equal(env.RATE_COUNTER.used.get("ai:cr:min:acct"), 1);
    for (const other of ["ai:cr:5h2:acct", "ai:cr:wk:acct", "ai:global:standard"]) if (other !== name) assert.equal(env.RATE_COUNTER.used.get(other), 1);
    await result.refund!();
  }
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { plan: "standard" });
  assert.equal((await result.reserve!(66001)).window, "input");
  await result.refund!();
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});

test("exceptions during initial and additional takes return already acquired windows", async () => {
  for (const additional of [false, true]) {
    const env = { RATE_COUNTER: counters() };
    const result = additional ? await call(env) : null;
    const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
    env.RATE_COUNTER.getByName = (name: string) => name.startsWith("ai:cr:wk:") ? { ...real(name), async take() { throw new Error("counter unavailable"); } } : real(name);
    await assert.rejects(additional ? result!.reserve!(12001) : call(env), /counter unavailable/);
    if (result) await result.refund!();
    assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
  }
});


test("refund failures are counted without identifying the account or exposing errors", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env, { accountKey: "private-account" });
  const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
  env.RATE_COUNTER.getByName = (name: string) => name.startsWith("ai:cr:wk:")
    ? { ...real(name), async give() { throw new Error("private error"); } } : real(name);
  const original = console.error, logs: string[] = [];
  console.error = (...args: unknown[]) => { logs.push(args.join(" ")); };
  try { await result.refund!(); } finally { console.error = original; }
  assert.deepEqual(logs.map(line => JSON.parse(line)), [{ event: "ai_credit_refund_failed", failed: 1 }]);
  assert.equal(env.RATE_COUNTER.used.get("ai:global:pro"), 0);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:wk:private-account"), 1);
});

test("smaller references on retry retain the highest previously reserved cost", async () => {
  const env = { RATE_COUNTER: counters() };
  const result = await call(env);
  assert.equal((await result.reserve!(18001)).ok, true);
  assert.equal((await result.reserve!(1)).ok, true);
  assert.equal(env.RATE_COUNTER.used.get("ai:cr:min:acct"), 1);
  for (const name of ["ai:cr:5h2:acct", "ai:cr:wk:acct", "ai:global:pro"]) assert.equal(env.RATE_COUNTER.used.get(name), 3);
  await result.refund!();
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});


// Pending contract: the existing counter API has no operation IDs, so a lost
// response cannot be distinguished from an operation that never happened.
test.todo("a take written before its response is lost must not leak a reservation", async () => {
  const env = { RATE_COUNTER: counters() };
  const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
  env.RATE_COUNTER.getByName = (name: string) => {
    const counter = real(name);
    return name.startsWith("ai:cr:wk:") ? { ...counter, async take(limit: number, seconds: string, amount: number) {
      await counter.take(limit, seconds, amount);
      throw new Error("response lost after write");
    } } : counter;
  };
  await assert.rejects(call(env), /response lost/);
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});

test.todo("a temporary give failure during partial refusal must remain recoverable", async () => {
  const env = { RATE_COUNTER: counters() };
  const real = env.RATE_COUNTER.getByName.bind(env.RATE_COUNTER);
  let failed = false;
  env.RATE_COUNTER.getByName = (name: string) => {
    const counter = real(name);
    if (name.startsWith("ai:cr:wk:")) return { ...counter, async take() { return { ok: false }; } };
    if (name.startsWith("ai:cr:5h2:")) return { ...counter, async give(amount: number) {
      if (!failed) { failed = true; throw new Error("temporary"); }
      await counter.give(amount);
    } };
    return counter;
  };
  assert.equal((await call(env)).window, "week");
  assert.ok([...env.RATE_COUNTER.used.values()].every(value => value === 0));
});
