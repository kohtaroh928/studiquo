import assert from "node:assert/strict";
import test from "node:test";
import { THROTTLE_POLICIES, recordFailure, refundAttempt, remainingSeconds, reserveAttempt, trustPair } from "./login-throttle.js";

const policy = { freeFailures: 3, baseSeconds: 10, maxSeconds: 60, windowSeconds: 600 };
const T0 = 1_000_000;

function failTimes(count, start = T0, step = 1_000) {
  let state;
  for (let i = 0; i < count; i++) state = recordFailure(state, start + i * step, policy);
  return state;
}

test("failures within the free allowance never wait", () => {
  const state = failTimes(3);
  assert.equal(state.failures, 3);
  assert.equal(remainingSeconds(state, T0 + 2_000), 0);
});

test("the wait starts after the free failures and doubles each time", () => {
  const waits = [4, 5, 6, 7].map(count => {
    const state = failTimes(count);
    return remainingSeconds(state, state.lastFailureAt);
  });
  assert.deepEqual(waits, [10, 20, 40, 60]);
});

test("the wait is capped at maxSeconds", () => {
  const state = failTimes(30);
  assert.equal(remainingSeconds(state, state.lastFailureAt), 60);
});

test("a wait ends on its own, never a permanent lock", () => {
  const state = failTimes(10);
  assert.equal(remainingSeconds(state, state.blockedUntil), 0);
  assert.equal(remainingSeconds(state, state.blockedUntil + 1), 0);
});

test("remainingSeconds rounds up and treats a missing state as no wait", () => {
  assert.equal(remainingSeconds(undefined, T0), 0);
  assert.equal(remainingSeconds({ failures: 4, lastFailureAt: T0, blockedUntil: T0 + 1_500 }, T0), 2);
});

test("a failure after the window has lapsed starts a fresh streak", () => {
  const state = failTimes(6);
  const later = recordFailure(state, state.lastFailureAt + policy.windowSeconds * 1000 + 1, policy);
  assert.equal(later.failures, 1);
  assert.equal(later.blockedUntil, 0);
});

test("production policies tolerate a typo streak before slowing anyone", () => {
  assert.ok(THROTTLE_POLICIES.ipAccount.freeFailures >= 3);
  assert.ok(THROTTLE_POLICIES.account.freeFailures > THROTTLE_POLICIES.ipAccount.freeFailures);
  assert.ok(THROTTLE_POLICIES.asn.freeFailures > THROTTLE_POLICIES.account.freeFailures);
  for (const p of Object.values(THROTTLE_POLICIES)) assert.ok(p.maxSeconds <= 900);
});

function reserveTimes(count, start = T0, step = 1_000) {
  let state;
  const results = [];
  for (let i = 0; i < count; i++) {
    const result = reserveAttempt(state, start + i * step, policy);
    results.push(result.waitSeconds);
    state = result.state;
  }
  return { state, results };
}

test("reserveAttempt counts each attempt up front and refuses once the wait starts", () => {
  const { results } = reserveTimes(6);
  // 3 free; the 4th attempt is let through but starts a wait the 5th meets.
  assert.deepEqual(results.map(wait => wait > 0), [false, false, false, false, true, true]);
});

test("a refused attempt changes nothing, so hammering can't extend the wait", () => {
  const { state } = reserveTimes(4);
  const blocked = reserveAttempt(state, T0 + 5_000, policy);
  assert.ok(blocked.waitSeconds > 0);
  assert.equal(blocked.state.failures, state.failures);
  assert.equal(blocked.state.blockedUntil, state.blockedUntil);
});

test("refundAttempt takes back one failure and recomputes the wait", () => {
  const { state } = reserveTimes(4);
  assert.ok(remainingSeconds(state, state.lastFailureAt) > 0);
  const refunded = refundAttempt(state, policy);
  assert.equal(refunded.failures, 3);
  assert.equal(remainingSeconds(refunded, refunded.lastFailureAt), 0);
  assert.equal(refundAttempt(undefined, policy), undefined);
  assert.equal(refundAttempt({ failures: 0 }, policy).failures, 0);
});

test("trustPair clears the streak and marks the pair trusted until it lapses", () => {
  const { state } = reserveTimes(6);
  const trusted = trustPair(state, T0 + 10_000);
  assert.equal(trusted.failures, 0);
  assert.equal(remainingSeconds(trusted, T0 + 10_000), 0);
  assert.equal(reserveAttempt(trusted, T0 + 11_000, policy).trusted, true);
  assert.equal(reserveAttempt(trusted, trusted.trustedUntil + 1, policy).trusted, false);
});

test("trust survives the failure window lapsing", () => {
  const trusted = trustPair(undefined, T0);
  const failed = reserveAttempt(trusted, T0 + 1_000, policy).state;
  const later = reserveAttempt(failed, T0 + 1_000 + policy.windowSeconds * 1000 + 1, policy);
  assert.equal(later.trusted, true);
  assert.equal(later.state.failures, 1);
});

test("reserveAttempt with enforce:false counts a failure even while a wait is running, and never refuses", () => {
  const { state } = reserveTimes(6);
  assert.ok(remainingSeconds(state, T0 + 6_000) > 0);
  const result = reserveAttempt(state, T0 + 6_000, policy, { enforce: false });
  assert.equal(result.waitSeconds, 0);
  assert.equal(result.state.failures, state.failures + 1);
});
