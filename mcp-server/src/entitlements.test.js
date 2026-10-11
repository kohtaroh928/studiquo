import assert from "node:assert/strict";
import test from "node:test";
import { getPlan, PRODUCT_PLAN_MAP } from "./entitlements.js";

// A hand-rolled stand-in for the ADMIN_DB D1 binding: real SQL text is
// ignored (admin.test.js already exercises the real schema against a real
// SQLite file for admin.js's own writes), and `subscribers` is just the
// rows `getPlan`'s single query would see for a given app_user_id. This
// also makes it easy to hand back more than one row for the same
// app_user_id — not something today's real schema (app_user_id is its
// primary key) can actually produce, but exactly the shape `getPlan` is
// written to tolerate; see its own doc comment.
function fakeAdminDB(subscribers) {
  return {
    ADMIN_DB: {
      prepare() {
        return {
          bind(appUserId) {
            return {
              async all() {
                return { results: subscribers.filter(row => row.app_user_id === appUserId) };
              },
            };
          },
        };
      },
    },
  };
}

const FAR_FUTURE = Date.now() + 365 * 24 * 60 * 60 * 1000;
const PAST = Date.now() - 60_000;

test("no subscriber record resolves to standard", async () => {
  const env = fakeAdminDB([]);
  assert.equal(await getPlan(env, "user-1"), "standard");
});

test("no sub at all (not signed in) resolves to standard without querying", async () => {
  const env = fakeAdminDB([]);
  assert.equal(await getPlan(env, null), "standard");
  assert.equal(await getPlan(env, ""), "standard");
});

test("an active plus subscriber resolves to plus", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.plus.monthly", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-1"), "plus");
});

test("an active pro subscriber (yearly) resolves to pro", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.pro.yearly", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-1"), "pro");
});

test("an expired record resolves to standard even though its product_id maps to pro", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "expired", product_id: "com.yabuko.studiquo.pro.monthly", expires_at: PAST },
  ]);
  assert.equal(await getPlan(env, "user-1"), "standard");
});

test("a status of 'active' whose expires_at has already passed resolves to standard", async () => {
  // Shouldn't happen in practice (the EXPIRATION webhook would have already
  // flipped status), but expires_at is still checked defensively.
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.plus.monthly", expires_at: PAST },
  ]);
  assert.equal(await getPlan(env, "user-1"), "standard");
});

test("a billing_issue subscriber is still entitled (RevenueCat's own grace period)", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "billing_issue", product_id: "com.yabuko.studiquo.plus.yearly", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-1"), "plus");
});

test("a null expires_at (no known end date) is treated as still active", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.pro.monthly", expires_at: null },
  ]);
  assert.equal(await getPlan(env, "user-1"), "pro");
});

test("an unrecognized product_id resolves to standard", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "some_other_app's_product", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-1"), "standard");
});

test("pro and plus both active at once resolves to pro, the more generous plan", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.plus.monthly", expires_at: FAR_FUTURE },
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.pro.monthly", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-1"), "pro");
});

test("one account's subscription never leaks into another's lookup", async () => {
  const env = fakeAdminDB([
    { app_user_id: "user-1", status: "active", product_id: "com.yabuko.studiquo.pro.monthly", expires_at: FAR_FUTURE },
  ]);
  assert.equal(await getPlan(env, "user-2"), "standard");
});

test("PRODUCT_PLAN_MAP maps every plus/pro product id to the right plan", () => {
  assert.equal(PRODUCT_PLAN_MAP["com.yabuko.studiquo.plus.monthly"], "plus");
  assert.equal(PRODUCT_PLAN_MAP["com.yabuko.studiquo.plus.yearly"], "plus");
  assert.equal(PRODUCT_PLAN_MAP["com.yabuko.studiquo.pro.monthly"], "pro");
  assert.equal(PRODUCT_PLAN_MAP["com.yabuko.studiquo.pro.yearly"], "pro");
});

// --- Paid Standard / paywall switch ---------------------------------------

// Like fakeAdminDB, but routes by SQL text so the legacy-account lookup can
// be answered separately from the subscribers lookup.
function fakePaywallDB({ subscribers = [], legacy = [], paywall = true } = {}) {
  return {
    ...(paywall ? { PAYWALL_ENABLED: "true" } : {}),
    ADMIN_DB: {
      prepare(sql) {
        return {
          bind(appUserId) {
            return {
              async all() {
                if (sql.includes("legacy_standard_accounts")) {
                  return { results: legacy.filter(id => id === appUserId).map(id => ({ app_user_id: id })) };
                }
                return { results: subscribers.filter(row => row.app_user_id === appUserId) };
              },
            };
          },
        };
      },
    },
  };
}

const STANDARD_YEARLY = "com.yabuko.studiquo.standard.yearly";

test("the standard yearly product maps to standard", () => {
  assert.equal(PRODUCT_PLAN_MAP[STANDARD_YEARLY], "standard");
});

test("paywall off: no subscription is still standard, whatever the legacy table holds", async () => {
  const env = fakePaywallDB({ paywall: false });
  assert.equal(await getPlan(env, "new-user"), "standard");
  assert.equal(await getPlan(env, null), "standard");
});

test("paywall on: no subscription and not legacy resolves to free", async () => {
  const env = fakePaywallDB();
  assert.equal(await getPlan(env, "new-user"), "free");
  assert.equal(await getPlan(env, null), "free");
});

test("paywall on: a legacy account without a subscription stays standard", async () => {
  const env = fakePaywallDB({ legacy: ["old-user"] });
  assert.equal(await getPlan(env, "old-user"), "standard");
  assert.equal(await getPlan(env, "new-user"), "free");
});

test("paywall on: an active standard subscriber (trial or paid) resolves to standard", async () => {
  const env = fakePaywallDB({
    subscribers: [{ app_user_id: "u", status: "active", product_id: STANDARD_YEARLY, expires_at: FAR_FUTURE }],
  });
  assert.equal(await getPlan(env, "u"), "standard");
});

test("paywall on: an expired standard subscriber who is not legacy falls to free", async () => {
  const env = fakePaywallDB({
    subscribers: [{ app_user_id: "u", status: "expired", product_id: STANDARD_YEARLY, expires_at: PAST }],
  });
  assert.equal(await getPlan(env, "u"), "free");
});

test("paywall on: plus outranks standard and a legacy grant never lowers a subscription", async () => {
  const env = fakePaywallDB({
    legacy: ["u"],
    subscribers: [{ app_user_id: "u", status: "active", product_id: "com.yabuko.studiquo.plus.yearly", expires_at: FAR_FUTURE }],
  });
  assert.equal(await getPlan(env, "u"), "plus");
});

test("a purchase under the pre-link identity still counts once the session is canonical", async () => {
  const env = fakePaywallDB({
    subscribers: [{ app_user_id: "apple-sub", status: "active", product_id: STANDARD_YEARLY, expires_at: FAR_FUTURE }],
  });
  assert.equal(await getPlan(env, ["google:canonical", "apple-sub"]), "standard");
  assert.equal(await getPlan(env, ["google:canonical", undefined]), "free");
});

test("a legacy grant under the pre-link identity still counts", async () => {
  const env = fakePaywallDB({ legacy: ["apple-sub"] });
  assert.equal(await getPlan(env, ["google:canonical", "apple-sub"]), "standard");
});
