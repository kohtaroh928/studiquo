// The arithmetic behind RateCounter.take/give (rate-counter.js), kept apart
// from the Durable Object so it can be tested without the Workers runtime.
//
// A counter's state is `{ count, windowEndsAt }`. A window starts at the first
// successful take and lasts `windowSeconds`; `windowEndsAt` doubles as the
// window's identity, so a refund can tell "the window I took from" apart from
// a newer one that began after it ended.

/** Takes `amount` if the window (new or current) has room; never creates state when it refuses. */
export function takeFrom(stored, now, limit, windowSeconds, amount) {
  const state = stored && now < stored.windowEndsAt
    ? { ...stored }
    : { count: 0, windowEndsAt: now + windowSeconds * 1000 };
  if (state.count + amount > limit) return { ok: false };
  state.count += amount;
  return { ok: true, state, windowEndsAt: state.windowEndsAt };
}

/**
 * Gives back `amount` taken from the window identified by `windowEndsAt`.
 * Returns the new state, or `null` when there is nothing to change: no state,
 * the window has already ended, or a different (newer) window is current.
 * The count never goes below zero.
 */
export function giveTo(stored, now, amount, windowEndsAt) {
  if (!stored || now >= stored.windowEndsAt || stored.windowEndsAt !== windowEndsAt) return null;
  return { ...stored, count: Math.max(0, stored.count - amount) };
}
