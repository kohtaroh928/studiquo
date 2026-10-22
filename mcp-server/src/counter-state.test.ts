import assert from "node:assert/strict";
import test from "node:test";
import { takeFrom, giveTo } from "./counter-state.ts";
import type { Untyped } from "./test-env.ts";

const T0 = 1_000_000;

/** `takeFrom` for a take the test expects to succeed: narrows the result so `.state` and `.windowEndsAt` are typed. */
function takeOk(...args: Parameters<typeof takeFrom>) {
  const result = takeFrom(...args);
  assert.ok(result.ok);
  return result as Extract<typeof result, { ok: true }>;
}

test("the first take starts a window that ends windowSeconds later", () => {
  const result = takeFrom(undefined, T0, 10, 60, 3);
  assert.deepEqual(result, { ok: true, state: { count: 3, windowEndsAt: T0 + 60_000 }, windowEndsAt: T0 + 60_000 });
});

test("takes add up inside a window and are refused at the limit, leaving the state alone", () => {
  let state = takeOk(undefined, T0, 10, 60, 6).state;
  state = takeOk(state, T0 + 1000, 10, 60, 4).state;
  assert.equal(state.count, 10);
  assert.deepEqual(takeFrom(state, T0 + 2000, 10, 60, 1), { ok: false });
});

test("an amount larger than the limit never creates a window", () => {
  assert.deepEqual(takeFrom(undefined, T0, 10, 60, 11), { ok: false });
  assert.deepEqual(takeFrom({ count: 5, windowEndsAt: T0 - 1 }, T0, 10, 60, 11), { ok: false });
});

test("a take after the window ended starts a fresh one", () => {
  const result = takeFrom({ count: 10, windowEndsAt: T0 }, T0, 10, 60, 2);
  assert.equal(result.ok, true);
  assert.equal(result.state.count, 2);
  assert.equal(result.windowEndsAt, T0 + 60_000);
});

test("give returns credits to the same window", () => {
  const taken = takeOk(undefined, T0, 10, 60, 6);
  const next = giveTo(taken.state, T0 + 1000, 6, taken.windowEndsAt);
  assert.equal(next!.count, 0);
});

test("give never takes the count below zero", () => {
  const taken = takeOk(undefined, T0, 10, 60, 2);
  assert.equal(giveTo(taken.state, T0 + 1, 50, taken.windowEndsAt)!.count, 0);
});

test("give does nothing once its window ended, or when a newer window is current", () => {
  const first = takeOk(undefined, T0, 10, 60, 6);
  assert.equal(giveTo(first.state, first.windowEndsAt, 6, first.windowEndsAt), null, "window over");
  // A new window began after the first one ended; the old refund must not touch it.
  const second = takeOk(first.state, first.windowEndsAt + 1, 10, 60, 3);
  assert.equal(second.state.count, 3);
  assert.equal(giveTo(second.state, first.windowEndsAt + 2, 6, first.windowEndsAt), null);
});

test("give with no state does nothing", () => {
  assert.equal(giveTo(undefined, T0, 1, T0 + 1), null);
});
