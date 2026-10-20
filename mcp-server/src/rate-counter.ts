import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import { takeFrom, giveTo, type CounterState } from "./counter-state.ts";
import { reserveAttempt, refundAttempt, trustPair, trustExpiryMs } from "./login-throttle.ts";
import { touchSeenContext } from "./login-monitor.ts";

// One instance per counted key (an AI usage bucket, a document-collab
// action, …) — see ai.ts's withinQuota and document-collab.ts's
// withinLimit, its only callers. A KV+TTL counter used to do this job, but
// every bump() cost a KV read and a KV write, and those count against the
// whole Cloudflare account's shared daily KV operation cap alongside every
// other KV use in this Worker — a busy day of ordinary AI/chat/document
// usage was enough to exhaust it and start failing unrelated features. A
// Durable Object's storage isn't subject to that cap at all, and unlike two
// independent KV get/put calls racing each other, one object handles its
// requests one at a time, so a bump can't be lost to a concurrent one
// reading the same stale count.
/** The App Attest key registered under an `attest-key:` name: its public key and the last assertion counter seen. */
export interface AttestRecord {
  /** The key as base64url text (bytesToBase64Url in app-attest.ts). */
  publicKey: string;
  counter: number;
  createdAt?: number;
  lastSeenAt?: number;
}

export class RateCounter extends DurableObject<Env> {
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
  async bump(limit: number, windowSeconds: number, amount = 1) {
    return (await this.take(limit, windowSeconds, amount)).ok;
  }

  /**
   * `bump`, but also says which window the amount was taken from, so a later
   * `give` can return it to that window and no other. `amount` lets one call
   * cost more than one unit (AI credits, ai-credits.ts).
   */
  async take(limit: number, windowSeconds: number, amount = 1) {
    const result = takeFrom(await this.ctx.storage.get<CounterState>("state"), Date.now(), limit, windowSeconds, amount);
    if (!result.ok) return { ok: false };
    await this.ctx.storage.put("state", result.state);
    // Lets this object's storage be reclaimed once its window is long
    // over, instead of one object per distinct key (every user × every
    // counted action) persisting forever.
    await this.ctx.storage.setAlarm(result.windowEndsAt + windowSeconds * 1000);
    return { ok: true, windowEndsAt: result.windowEndsAt };
  }

  /**
   * Gives back what an earlier `take` took, for when a later check in the same
   * request refused it. Only touches the window it was taken from (see
   * counter-state.ts).
   */
  async give(amount: any, windowEndsAt: any) {
    const next = giveTo(await this.ctx.storage.get<CounterState>("state"), Date.now(), amount, windowEndsAt);
    if (next) await this.ctx.storage.put("state", next);
  }

  // Reads a quota without incrementing it. The AI header uses the exact same
  // per-device counter enforced by bump(), rather than a client-side estimate.
  async usage(limit: number, windowSeconds: number) {
    const now = Date.now();
    const stored = await this.ctx.storage.get<CounterState>("state");
    const state = stored && now < stored.windowEndsAt ? stored : null;
    const used = state?.count ?? 0;
    return { limit, remaining: Math.max(0, limit - used), resetsAt: state?.windowEndsAt ?? null };
  }

  // Failed-login backoff (login-throttle.ts owns the policy and the state
  // transitions; this object serialises access to them, which is what makes
  // "check the wait, then count the attempt" one atomic step). A name is
  // used either for bump() or for these, never both, so they share the alarm.
  async loginReserve(policy: any, { enforce = true } = {}) {
    const now = Date.now();
    const result = reserveAttempt(await this.ctx.storage.get("login"), now, policy, { enforce });
    if (result.waitSeconds === 0) await this.saveLogin(result.state, now, policy);
    return { waitSeconds: result.waitSeconds, trusted: result.trusted };
  }

  async loginRefund(policy: any) {
    const stored = await this.ctx.storage.get("login");
    if (stored) await this.saveLogin(refundAttempt(stored, policy), Date.now(), policy);
  }

  async loginTrust() {
    const now = Date.now();
    const next = trustPair(await this.ctx.storage.get("login"), now);
    await this.ctx.storage.put("login", next);
    await this.ctx.storage.setAlarm(trustExpiryMs(next) + 3_600_000);
  }

  async saveLogin(state: any, now: number, policy: any) {
    await this.ctx.storage.put("login", state);
    // Outlives both the failure window and any trust, then reclaims storage.
    const until = Math.max(Math.max(state.blockedUntil ?? 0, now) + policy.windowSeconds * 1000, trustExpiryMs(state) + 3_600_000);
    await this.ctx.storage.setAlarm(until);
  }

  // Which country+network an account has signed in from (login-monitor.ts).
  // Used under its own name, so it shares nothing with bump()/login state.
  async seenContext(key: string, { maxEntries, ttlSeconds }: any) {
    const now = Date.now();
    const result = touchSeenContext(await this.ctx.storage.get("seen"), key, now, maxEntries, ttlSeconds);
    await this.ctx.storage.put("seen", result.state);
    await this.ctx.storage.setAlarm(now + ttlSeconds * 1000);
    return { isNew: result.isNew, wasEmpty: result.wasEmpty };
  }

  // Per-account password generation (local-auth.ts). Deliberately has no
  // alarm: forgetting the count would let a stale record's old generation
  // match again.
  async nextAccountGeneration() {
    const next = ((await this.ctx.storage.get<number>("gen")) ?? 0) + 1;
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
  async retireAccountGeneration(ttlSeconds: number) {
    const next = ((await this.ctx.storage.get<number>("gen")) ?? 0) + 1;
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
  async upgradeAccountIfCurrent(key: string, json: any, expectedGen: any) {
    return this.ctx.blockConcurrencyWhile(async () => {
      if (((await this.ctx.storage.get<number>("gen")) ?? 0) !== expectedGen) return false;
      await this.env.STUDIQUO_DATA.put(key, json);
      return true;
    });
  }

  // App Attest (app-attest.ts): one object per registered app key, holding its
  // public key and the last assertion counter. Deliberately has no alarm: a key
  // stays valid for as long as the app install does, and forgetting the counter
  // would let an old assertion be sent again.
  async attestRegister(record: AttestRecord) {
    if (await this.ctx.storage.get("attest")) return false;
    await this.ctx.storage.put("attest", record);
    return true;
  }

  async attestKey(): Promise<AttestRecord | null> {
    return (await this.ctx.storage.get<AttestRecord>("attest")) ?? null;
  }

  // Moves the counter forward only if `counter` is higher than what is stored,
  // as one step, so two requests with the same counter cannot both pass.
  async attestAdvance(counter: any) {
    const record = await this.ctx.storage.get<AttestRecord>("attest");
    if (!record || counter <= record.counter) return false;
    await this.ctx.storage.put("attest", { ...record, counter, lastSeenAt: Date.now() });
    return true;
  }

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}
