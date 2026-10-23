import assert from "node:assert/strict";
import test from "node:test";
import { aiLimits, DEFAULT_AI_LIMITS, globalDailyCredits, inputMultiplier, mergeLimits, subscriberCounts } from "./ai-limits.ts";
import { PRODUCT_PLAN_MAP } from "./entitlements.ts";
import { partialEnv } from "./test-env.ts";

async function quietlyAsync<T>(work: () => Promise<T>) {
  const original = console.error;
  const logged: string[] = [];
  console.error = (line: string) => { logged.push(line); };
  try {
    return { result: await work(), logged };
  } finally {
    console.error = original;
  }
}

function quietly<T>(work: () => T) {
  const original = console.error;
  const logged: string[] = [];
  console.error = (line: string) => { logged.push(line); };
  try {
    return { result: work(), logged };
  } finally {
    console.error = original;
  }
}

test("with AI_LIMITS unset the defaults apply", () => {
  assert.equal(aiLimits(partialEnv({})), DEFAULT_AI_LIMITS);
});

test("AI_LIMITS changes only the values it names", () => {
  const limits = mergeLimits(JSON.stringify({ plans: { pro: { week: 1200 } }, global: { headroom: 4, floorDollarsPerDay: { plus: 20 } } }));
  assert.equal(limits.plans.pro.week, 1200);
  assert.equal(limits.plans.pro.fiveHours, DEFAULT_AI_LIMITS.plans.pro.fiveHours);
  assert.deepEqual(limits.plans.standard, DEFAULT_AI_LIMITS.plans.standard);
  assert.equal(limits.global.headroom, 4);
  assert.equal(limits.global.floorDollarsPerDay.plus, 20);
  assert.equal(limits.global.floorDollarsPerDay.pro, DEFAULT_AI_LIMITS.global.floorDollarsPerDay.pro);
  assert.equal(DEFAULT_AI_LIMITS.plans.pro.week, 920, "the defaults themselves are untouched");
});

test("a typo, a zero, a negative or a non-number in AI_LIMITS is ignored and logged, never lifting a limit", () => {
  const { result: limits, logged } = quietly(() => mergeLimits(JSON.stringify({
    plans: { pro: { weekk: 99999, fiveHours: 0, week: -1, perMinute: "50" }, free: { week: 100 } },
    input: { chatMaxChars: Infinity, stepChars: null },
    global: "lots",
  })));
  assert.deepEqual(limits, DEFAULT_AI_LIMITS);
  const keys = JSON.parse(logged[0]).keys;
  for (const key of ["plans.pro.weekk", "plans.pro.fiveHours", "plans.pro.week", "plans.pro.perMinute", "plans.free", "input.stepChars", "global"]) {
    assert.ok(keys.includes(key), key);
  }
});

test("AI_LIMITS that is not JSON leaves the defaults, and says so", () => {
  const { result, logged } = quietly(() => mergeLimits("{plans:"));
  assert.deepEqual(result, DEFAULT_AI_LIMITS);
  assert.match(logged[0], /not valid JSON/);
});

test("the input multiplier follows the configured steps", () => {
  const limits = mergeLimits(JSON.stringify({ input: { freeChars: 1000, stepChars: 500 } }));
  assert.equal(inputMultiplier(1000, limits), 1);
  assert.equal(inputMultiplier(1001, limits), 2);
  assert.equal(inputMultiplier(2000, limits), 3);
  assert.equal(inputMultiplier(-5, limits), 1);
});

test("the service-wide ceiling never drops below the floor", () => {
  // $15 a day for pro at $0.0007 a credit.
  assert.equal(globalDailyCredits("pro", 0), Math.floor(15 / 0.0007));
  assert.equal(globalDailyCredits("standard", 0), Math.floor(5 / 0.0007));
});

test("the service-wide ceiling grows with subscribers: headroom x their even daily use", () => {
  // 1,000 pro subscribers: 1,000 x 920/7 x 3 = 394,285 credits (~$276 a day).
  assert.equal(globalDailyCredits("pro", 1000), Math.floor(1000 * (920 / 7) * 3));
  // and with the headroom raised through AI_LIMITS.
  const limits = mergeLimits(JSON.stringify({ global: { headroom: 5 } }));
  assert.equal(globalDailyCredits("pro", 1000, limits), Math.floor(1000 * (920 / 7) * 5));
});

test("one account at its whole week in a day cannot use up even the floor", () => {
  for (const plan of ["standard", "plus", "pro"] as const) {
    assert.ok(globalDailyCredits(plan, 0) > DEFAULT_AI_LIMITS.plans[plan].week * 5, plan);
  }
});

function fakeDB({ rows = [] as { product_id: string; n: number }[], legacy = 0, fail = false } = {}) {
  const calls: string[] = [];
  return {
    calls,
    prepare(sql: string) {
      calls.push(sql);
      const statement = {
        bind() { return statement; },
        async all() {
          if (fail) throw new Error("D1 down");
          return { results: rows };
        },
        async first() {
          if (fail) throw new Error("D1 down");
          return { n: legacy };
        },
      };
      return statement;
    },
  };
}

test("subscribers are counted per plan from the product ids, legacy accounts as standard only with the paywall on", async () => {
  const rows = [
    { product_id: "com.yabuko.studiquo.pro.monthly", n: 3 },
    { product_id: "com.yabuko.studiquo.pro.yearly", n: 2 },
    { product_id: "com.yabuko.studiquo.plus.monthly", n: 4 },
    { product_id: "com.yabuko.studiquo.standard.yearly", n: 7 },
    { product_id: "com.example.unknown", n: 100 },
  ];
  assert.deepEqual(await subscriberCounts(partialEnv({ ADMIN_DB: fakeDB({ rows, legacy: 10 }) }), PRODUCT_PLAN_MAP, true), { standard: 17, plus: 4, pro: 5 });
  assert.deepEqual(await subscriberCounts(partialEnv({ ADMIN_DB: fakeDB({ rows, legacy: 10 }) }), PRODUCT_PLAN_MAP, false), { standard: 7, plus: 4, pro: 5 });
});

test("the count is read at most once every 10 minutes", async () => {
  const db = fakeDB({ rows: [{ product_id: "com.yabuko.studiquo.pro.monthly", n: 1 }] });
  const env = partialEnv({ ADMIN_DB: db });
  const now = 1_000_000_000;
  await subscriberCounts(env, PRODUCT_PLAN_MAP, false, now);
  await subscriberCounts(env, PRODUCT_PLAN_MAP, false, now + 9 * 60_000);
  assert.equal(db.calls.length, 1);
  await subscriberCounts(env, PRODUCT_PLAN_MAP, false, now + 11 * 60_000);
  assert.equal(db.calls.length, 2);
});

test("when D1 cannot be read the last count is kept, and with none every plan gets only its floor", async () => {
  const env = partialEnv({ ADMIN_DB: fakeDB({ rows: [{ product_id: "com.yabuko.studiquo.pro.monthly", n: 8 }] }) });
  const now = 2_000_000_000;
  assert.deepEqual(await subscriberCounts(env, PRODUCT_PLAN_MAP, false, now), { standard: 0, plus: 0, pro: 8 });
  (env as { ADMIN_DB: unknown }).ADMIN_DB = fakeDB({ fail: true });
  const { result, logged } = await quietlyAsync(() => subscriberCounts(env, PRODUCT_PLAN_MAP, false, now + 20 * 60_000));
  assert.deepEqual(result, { standard: 0, plus: 0, pro: 8 });
  assert.match(logged[0], /subscriber count failed/);

  const fresh = partialEnv({ ADMIN_DB: fakeDB({ fail: true }) });
  const { result: none } = await quietlyAsync(() => subscriberCounts(fresh, PRODUCT_PLAN_MAP, false, now));
  assert.deepEqual(none, { standard: 0, plus: 0, pro: 0 });
});

test("AI_LIMITS cannot reach past the defaults through inherited keys", () => {
  const { result: limits } = quietly(() => mergeLimits('{"__proto__":{"toString":5},"plans":{"constructor":{"prototype":{"polluted":1}},"pro":{"hasOwnProperty":7}}}'));
  assert.deepEqual(limits, DEFAULT_AI_LIMITS);
  assert.equal(typeof ({} as { toString: unknown }).toString, "function");
  assert.equal(({} as { polluted?: unknown }).polluted, undefined);
});
