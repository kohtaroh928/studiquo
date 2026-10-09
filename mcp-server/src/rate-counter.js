import { DurableObject } from "cloudflare:workers";
import { reserveAttempt, refundAttempt, trustPair, trustExpiryMs } from "./login-throttle.js";
import { touchSeenContext } from "./login-monitor.js";

// One instance per counted key (an AI usage bucket, a document-collab
// action, …) — see ai.js's withinQuota and document-collab.js's
// withinLimit, its only callers. A KV+TTL counter used to do this job, but
// every bump() cost a KV read and a KV write, and those count against the
// whole Cloudflare account's shared daily KV operation cap alongside every
// other KV use in this Worker — a busy day of ordinary AI/chat/document
// usage was enough to exhaust it and start failing unrelated features. A
// Durable Object's storage isn't subject to that cap at all, and unlike two
// independent KV get/put calls racing each other, one object handles its
// requests one at a time, so a bump can't be lost to a concurrent one
// reading the same stale count.
export class RateCounter extends DurableObject {
  /**
   * True and increments this counter if it's still under `limit` for the
   * current window; false, unchanged, once it isn't.
   *
   * `windowSeconds` is how long a window lasts before the count resets on
   * its own (60 for a per-minute rate limit, 86_400 for a per-day quota).
   * Unlike the old KV+TTL counters' clock-aligned buckets, the window here
   * starts from this key's first bump — still a soft cap rather than an
   * exact one, same as the KV version was, just without its burst-at-the
   * -boundary quirk.
   */
  async bump(limit, windowSeconds) {
    const now = Date.now();
    const stored = await this.ctx.storage.get("state");
    const state = stored && now < stored.windowEndsAt
      ? stored
      : { count: 0, windowEndsAt: now + windowSeconds * 1000 };
    if (state.count >= limit) return false;
    state.count += 1;
    await this.ctx.storage.put("state", state);
    // Lets this object's storage be reclaimed once its window is long
    // over, instead of one object per distinct key (every user × every
    // counted action) persisting forever.
    await this.ctx.storage.setAlarm(state.windowEndsAt + windowSeconds * 1000);
    return true;
  }

  // Failed-login backoff (login-throttle.js owns the policy and the state
  // transitions; this object serialises access to them, which is what makes
  // "check the wait, then count the attempt" one atomic step). A name is
  // used either for bump() or for these, never both, so they share the alarm.
  async loginReserve(policy, { enforce = true } = {}) {
    const now = Date.now();
    const result = reserveAttempt(await this.ctx.storage.get("login"), now, policy, { enforce });
    if (result.waitSeconds === 0) await this.saveLogin(result.state, now, policy);
    return { waitSeconds: result.waitSeconds, trusted: result.trusted };
  }

  async loginRefund(policy) {
    const stored = await this.ctx.storage.get("login");
    if (stored) await this.saveLogin(refundAttempt(stored, policy), Date.now(), policy);
  }

  async loginTrust() {
    const now = Date.now();
    const next = trustPair(await this.ctx.storage.get("login"), now);
    await this.ctx.storage.put("login", next);
    await this.ctx.storage.setAlarm(trustExpiryMs(next) + 3_600_000);
  }

  async saveLogin(state, now, policy) {
    await this.ctx.storage.put("login", state);
    // Outlives both the failure window and any trust, then reclaims storage.
    const until = Math.max(Math.max(state.blockedUntil ?? 0, now) + policy.windowSeconds * 1000, trustExpiryMs(state) + 3_600_000);
    await this.ctx.storage.setAlarm(until);
  }

  // Which country+network an account has signed in from (login-monitor.js).
  // Used under its own name, so it shares nothing with bump()/login state.
  async seenContext(key, { maxEntries, ttlSeconds }) {
    const now = Date.now();
    const result = touchSeenContext(await this.ctx.storage.get("seen"), key, now, maxEntries, ttlSeconds);
    await this.ctx.storage.put("seen", result.state);
    await this.ctx.storage.setAlarm(now + ttlSeconds * 1000);
    return { isNew: result.isNew, wasEmpty: result.wasEmpty };
  }

  // Per-account password generation (local-auth.js). Deliberately has no
  // alarm: forgetting the count would let a stale record's old generation
  // match again.
  async nextAccountGeneration() {
    const next = ((await this.ctx.storage.get("gen")) ?? 0) + 1;
    await this.ctx.storage.put("gen", next);
    // A password being set again (re-registration after a deletion) takes the
    // count back out of retirement: see retireAccountGeneration.
    await this.ctx.storage.deleteAlarm();
    return next;
  }

  // Account deletion. The count can't be dropped at once: a login already in
  // flight (or one that read a stale copy of the record) could still try to
  // write the deleted account back, and it is the moved-on count that makes
  // that refuse. Nothing but a counter is kept, and only for as long as KV can
  // serve a stale read (about a minute) plus a wide margin; then the alarm
  // clears it. Setting a password again before then cancels the alarm.
  async retireAccountGeneration(ttlSeconds) {
    const next = ((await this.ctx.storage.get("gen")) ?? 0) + 1;
    await this.ctx.storage.put("gen", next);
    await this.ctx.storage.setAlarm(Date.now() + ttlSeconds * 1000);
    return next;
  }

  // Account deletion, for every other per-account object (seen contexts,
  // failure counters, notice allowance, code-attempt counters): forget it all.
  async purgeAll() {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  // Writes `json` to `key` only if no password was set since `expectedGen`.
  // The check and the write are one step here, so a concurrent password set
  // can't slip in between them.
  // The KV write is outside this object's storage, so without the block a
  // nextAccountGeneration() (and the password write that follows it) could
  // run while this put is still in flight and then be overtaken by it.
  async upgradeAccountIfCurrent(key, json, expectedGen) {
    return this.ctx.blockConcurrencyWhile(async () => {
      if (((await this.ctx.storage.get("gen")) ?? 0) !== expectedGen) return false;
      await this.env.STUDIQUO_DATA.put(key, json);
      return true;
    });
  }

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}
