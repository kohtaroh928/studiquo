// Credential-stuffing defence for POST /api/auth/local/login. The per-IP
// Cloudflare limit alone doesn't hold once an attacker spreads attempts
// across a botnet or proxy pool, so failed logins are also counted under
// keys that don't depend on which IP asked:
//
//   - the account (email) — the same mailbox hit from anywhere
//   - IP + account        — one client hammering one mailbox
//   - ASN                 — one network/hosting provider working a list
//
// Each key escalates independently: a few free failures, then an
// exponentially growing wait, capped. A wait, not a lock — while it runs the
// password isn't even checked (so a lucky guess can't succeed), but it
// always expires on its own, so someone deliberately failing logins against
// a victim's address can make a *new* device or network wait up to
// `maxSeconds` per key (and keep doing so while they keep failing), but
// never locks anyone out, and never touches an IP the owner already uses. Counting happens whether or not the address has
// an account, so the 429 doesn't reveal which addresses are registered.
//
// Two further rules keep this from being turned against the real owner:
//   - An attempt is counted *before* its password is checked (and handed back
//     on success), in one atomic step with the wait check. Counting after
//     the check would let a burst of parallel requests all see "no wait" and
//     all get a password verified.
//   - An IP that has already signed in to this account successfully (within
//     the last 14 days) is "trusted" for it: the shared account and ASN waits
//     are not *enforced* against that pair, though its failures still count
//     toward them, and its own IP+account streak still escalates. A stranger hammering the
//     address can't therefore keep its owner waiting on their usual network.
import { sha256Hex } from "./auth.js";

export const THROTTLE_POLICIES = {
  // Shared carrier/NAT ASNs hold many honest users, so this key tolerates a
  // lot before it slows anyone and never waits long.
  asn: { freeFailures: 100, baseSeconds: 10, maxSeconds: 300, windowSeconds: 3_600 },
  account: { freeFailures: 10, baseSeconds: 30, maxSeconds: 900, windowSeconds: 3_600 },
  ipAccount: { freeFailures: 5, baseSeconds: 15, maxSeconds: 900, windowSeconds: 3_600 },
};

function streakAlive(state, now, policy) {
  return Boolean(state) && state.failures > 0 && now < state.lastFailureAt + policy.windowSeconds * 1000;
}

/**
 * Pure state transition: records one failure against `state` (or a fresh
 * state if it's missing or its window has lapsed since the last failure) and
 * works out the resulting wait. `now` is epoch milliseconds.
 */
export function recordFailure(state, now, policy) {
  const live = streakAlive(state, now, policy) ? state : { failures: 0 };
  const failures = live.failures + 1;
  const waitSeconds = waitFor(failures, policy);
  return {
    failures,
    lastFailureAt: now,
    blockedUntil: waitSeconds > 0 ? now + waitSeconds * 1000 : 0,
    trustedUntil: state?.trustedUntil ?? 0,
  };
}

const TRUST_SECONDS = 14 * 86_400;

function waitFor(failures, policy) {
  const over = failures - policy.freeFailures;
  return over <= 0 ? 0 : Math.min(policy.maxSeconds, policy.baseSeconds * 2 ** (over - 1));
}

/** Whole seconds left on `state`'s wait at `now`; 0 when not waiting. */
export function remainingSeconds(state, now) {
  if (!state || !state.blockedUntil || now >= state.blockedUntil) return 0;
  return Math.ceil((state.blockedUntil - now) / 1000);
}


/**
 * One atomic step for the Durable Object: if `state` is waiting, say so and
 * change nothing (a blocked try is not a failure); otherwise count this
 * attempt as a failure up front and let it proceed. `trusted` reports whether
 * this key's IP+account pair has signed in successfully before.
 */
export function reserveAttempt(state, now, policy, { enforce = true } = {}) {
  const trusted = Boolean(state) && now < (state.trustedUntil ?? 0);
  const current = streakAlive(state, now, policy) ? state : { ...(state ?? {}), failures: 0, blockedUntil: 0 };
  const waitSeconds = remainingSeconds(current, now);
  // `enforce: false` still counts the failure but never refuses (a trusted
  // pair against the shared account / ASN keys).
  if (enforce && waitSeconds > 0) return { state: current, waitSeconds, trusted };
  return { state: recordFailure(current, now, policy), waitSeconds: 0, trusted };
}

/** Takes back the failure reserveAttempt counted, once the password turned out correct. */
export function refundAttempt(state, policy) {
  if (!state || state.failures <= 0) return state;
  const failures = state.failures - 1;
  const waitSeconds = waitFor(failures, policy);
  return { ...state, failures, blockedUntil: waitSeconds > 0 ? state.lastFailureAt + waitSeconds * 1000 : 0 };
}

/** A correct password: forget the streak and remember this IP+account pair as known. */
export function trustPair(state, now) {
  return { failures: 0, lastFailureAt: now, blockedUntil: 0, trustedUntil: now + TRUST_SECONDS * 1000 };
}

export function trustExpiryMs(state) {
  return state?.trustedUntil ?? 0;
}

async function loginKeys(env, request, email) {
  const emailHash = await sha256Hex(email.trim().toLowerCase());
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const named = (policy, name) => ({ policy, stub: env.RATE_COUNTER.getByName(name) });
  const shared = [named(THROTTLE_POLICIES.account, `login-fail-account:${emailHash}`)];
  const asn = request.cf?.asn;
  if (asn !== undefined && asn !== null) shared.push(named(THROTTLE_POLICIES.asn, `login-fail-asn:${asn}`));
  return {
    pair: named(THROTTLE_POLICIES.ipAccount, `login-fail-ip-account:${await sha256Hex(`${ip}|${emailHash}`)}`),
    shared,
  };
}

/**
 * Call before checking the password. Counts this attempt as a failure up
 * front (atomically with the wait check, in each key's Durable Object), so
 * parallel requests can't all slip past a wait that hasn't been recorded
 * yet. Returns `{ waitSeconds }`; when it's > 0 the caller must refuse
 * without checking the password, and nothing is left counted. Otherwise
 * pass the result to finishLoginAttempt() with the outcome.
 */
export async function beginLoginAttempt(env, request, email) {
  const { pair, shared } = await loginKeys(env, request, email);
  const own = await pair.stub.loginReserve(pair.policy);
  if (own.waitSeconds > 0) return { waitSeconds: own.waitSeconds, pair, held: [] };
  // A known IP+account pair is never held up by the shared account / ASN
  // waits, but its failures still count toward them: otherwise a botnet that
  // had trusted many IPs (say with an old, leaked password) could guess a
  // changed one without ever moving the account's counter.
  if (own.trusted) {
    await Promise.all(shared.map(key => key.stub.loginReserve(key.policy, { enforce: false })));
    return { waitSeconds: 0, pair, held: shared };
  }

  const results = await Promise.all(shared.map(key => key.stub.loginReserve(key.policy)));
  const waitSeconds = Math.max(0, ...results.map(result => result.waitSeconds));
  // Keys that did count this attempt (their own wait was 0).
  const held = shared.filter((_, index) => results[index].waitSeconds === 0);
  if (waitSeconds > 0) {
    // Refused: hand back every failure just counted, including the pair's.
    await Promise.all([pair, ...held].map(key => key.stub.loginRefund(key.policy)));
    return { waitSeconds, pair, held: [] };
  }
  return { waitSeconds: 0, pair, held };
}

/** Call after the password check. Failures stay counted; a success hands the shared counters their failure back and trusts this IP+account pair. */
export async function finishLoginAttempt(attempt, succeeded) {
  if (!succeeded) return;
  await Promise.all([
    attempt.pair.stub.loginTrust(),
    ...attempt.held.map(key => key.stub.loginRefund(key.policy)),
  ]);
}
