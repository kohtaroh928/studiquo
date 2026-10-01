// Resolves a signed-in account's current subscription plan from the
// `subscribers` table in D1 (ADMIN_DB) that admin.js's RevenueCat webhook
// (`handleAdminWebhook`) keeps up to date — see
// migrations/0001_admin_dashboard.sql for that table's schema and admin.js's
// `upsertSubscriber`/`ACTIVATING_EVENT_TYPES` for how a row gets there.
// Nothing in this file talks to RevenueCat directly; it only reads what the
// webhook already wrote.
//
// Contract with the iOS app: RevenueCat's subscriber id (`app_user_id`) is
// only usable as the key into that table if the app calls
// `Purchases.shared.logIn(session.sub)` right after a real studiquo sign-in
// (see AuthenticationStore.swift). Without that call RevenueCat assigns its
// own anonymous id, `app_user_id` never matches `session.sub`, and
// `getPlan` silently returns "standard" forever even for a paying
// subscriber.
//
// PRODUCT_PLAN_MAP is kept in sync by hand with `SubscriptionProductID` in
// studiquo/Services/SubscriptionStore.swift — the two files are two
// independent listings of the same App Store product ids, not one shared
// source. Whoever adds a product in one place must add it in the other, or
// a real purchase grants nothing on the server.
export const PRODUCT_PLAN_MAP = {
  "com.yabuko.studiquo.plus.monthly": "plus",
  "com.yabuko.studiquo.plus.yearly": "plus",
  "com.yabuko.studiquo.pro.monthly": "pro",
  "com.yabuko.studiquo.pro.yearly": "pro",
};

// Higher-ranked plans win when more than one applies at once (see below).
const PLAN_RANK = { standard: 0, plus: 1, pro: 2 };

// RevenueCat's CANCELLATION doesn't deactivate a subscriber by itself — see
// admin.js's ACTIVATING_EVENT_TYPES comment: access lasts until the
// EXPIRATION event fires at the end of the current period, and only then
// does `status` here become "expired". "billing_issue" (a failed renewal
// charge) is still entitled during RevenueCat's own grace period, same as
// an outright "active" subscriber — only EXPIRATION/REFUND ever move a row
// out of this set (admin.js's DEACTIVATING_EVENT_TYPES).
const ACTIVE_STATUSES = new Set(["active", "billing_issue"]);

function planFromRow(row) {
  if (!row) return "standard";
  if (!ACTIVE_STATUSES.has(row.status)) return "standard";
  // expires_at is null for a subscriber whose event never carried
  // expiration_at_ms (admin.js falls back to `null` there); null means
  // "not known to have an end date", not "expired".
  if (typeof row.expires_at === "number" && row.expires_at > 0 && row.expires_at <= Date.now()) {
    return "standard";
  }
  return PRODUCT_PLAN_MAP[row.product_id] ?? "standard";
}

/**
 * Returns "standard" | "plus" | "pro" for `sub` (studiquo's session.sub,
 * which must equal RevenueCat's app_user_id — see this file's header).
 * Falls back to "standard" when there's no subscriber record, the record
 * is expired/not currently entitled, or its product_id isn't one this
 * server recognizes.
 *
 * Queries every row for `sub` rather than assuming at most one: today's
 * `subscribers` schema keys on `app_user_id` alone, so in practice there is
 * never more than one row per account, but a user who somehow holds two
 * valid entitlements at once (e.g. a mistaken double purchase, or a future
 * schema that tracks one row per product) must resolve to the single most
 * generous plan — pro over plus — rather than whichever happened to be
 * written last.
 */
export async function getPlan(env, sub) {
  if (!sub) return "standard";
  const { results } = await env.ADMIN_DB.prepare(
    `SELECT status, product_id, expires_at FROM subscribers WHERE app_user_id = ?`
  ).bind(sub).all();
  const plans = (results ?? []).map(planFromRow);
  return plans.reduce((best, plan) => (PLAN_RANK[plan] > PLAN_RANK[best] ? plan : best), "standard");
}
