import { DurableObject } from "cloudflare:workers";

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

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}
