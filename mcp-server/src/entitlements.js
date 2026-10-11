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
  "com.yabuko.studiquo.standard.yearly": "standard",
  "com.yabuko.studiquo.plus.monthly": "plus",
  "com.yabuko.studiquo.plus.yearly": "plus",
  "com.yabuko.studiquo.pro.monthly": "pro",
  "com.yabuko.studiquo.pro.yearly": "pro",
};

// Higher-ranked plans win when more than one applies at once (see below).
const PLAN_RANK = { free: 0, standard: 1, plus: 2, pro: 3 };

// Paid Standard (annual, 980 JPY) is behind this switch while the app is
// unreleased: with `PAYWALL_ENABLED` unset, an account with no subscription
// resolves to "standard" exactly as it did when Standard was free, so nothing
// changes for anyone. Once it is "true", an account with no active
// subscription resolves to "free" (no AI credits; the app shows its
// paywall) unless it is listed in `legacy_standard_accounts` — the accounts
// that already existed at launch and were moved to Standard. Remove the
// switch (and the "standard"-by-default branch) after launch.
export function paywallEnabled(env) {
  return env.PAYWALL_ENABLED === "true";
}

// RevenueCat's CANCELLATION doesn't deactivate a subscriber by itself — see
// admin.js's ACTIVATING_EVENT_TYPES comment: access lasts until the
// EXPIRATION event fires at the end of the current period, and only then
// does `status` here become "expired". "billing_issue" (a failed renewal
// charge) is still entitled during RevenueCat's own grace period, same as
// an outright "active" subscriber — only EXPIRATION/REFUND ever move a row
// out of this set (admin.js's DEACTIVATING_EVENT_TYPES).
const ACTIVE_STATUSES = new Set(["active", "billing_issue"]);

// `null` means "this row grants no plan"; the caller decides what that
// falls back to (see `getPlan`).
function planFromRow(row) {
  if (!row) return null;
  if (!ACTIVE_STATUSES.has(row.status)) return null;
  // expires_at is null for a subscriber whose event never carried
  // expiration_at_ms (admin.js falls back to `null` there); null means
  // "not known to have an end date", not "expired".
  if (typeof row.expires_at === "number" && row.expires_at > 0 && row.expires_at <= Date.now()) {
    return null;
  }
  return PRODUCT_PLAN_MAP[row.product_id] ?? null;
}

/**
 * Returns "free" | "standard" | "plus" | "pro" for `sub` (studiquo's
 * session.sub, which must equal RevenueCat's app_user_id — see this file's
 * header).
 *
 * With the paywall off (the default), an account with no usable
 * subscription is "standard". With it on, that account is "standard" only if
 * it is a legacy account, and "free" otherwise. A signed-out caller (no
 * `sub`) is never granted more than the no-subscription fallback.
 *
 * Queries every subscriber row for `sub` rather than assuming at most one:
 * today's `subscribers` schema keys on `app_user_id` alone, so in practice
 * there is never more than one row per account, but a user who somehow holds
 * two valid entitlements at once must resolve to the single most generous
 * plan — pro over plus — rather than whichever happened to be written last.
 */
export async function getPlan(env, sub) {
  if (!paywallEnabled(env)) {
    if (!sub) return "standard";
    return (await subscribedPlan(env, sub)) ?? "standard";
  }
  if (!sub) return "free";
  const subscribed = await subscribedPlan(env, sub);
  if (subscribed) return subscribed;
  return (await isLegacyAccount(env, sub)) ? "standard" : "free";
}

async function subscribedPlan(env, sub) {
  const { results } = await env.ADMIN_DB.prepare(
    `SELECT status, product_id, expires_at FROM subscribers WHERE app_user_id = ?`
  ).bind(sub).all();
  const plans = (results ?? []).map(planFromRow).filter(Boolean);
  if (plans.length === 0) return null;
  return plans.reduce((best, plan) => (PLAN_RANK[plan] > PLAN_RANK[best] ? plan : best));
}

async function isLegacyAccount(env, sub) {
  const { results } = await env.ADMIN_DB.prepare(
    `SELECT app_user_id FROM legacy_standard_accounts WHERE app_user_id = ?`
  ).bind(sub).all();
  return (results ?? []).length > 0;
}
