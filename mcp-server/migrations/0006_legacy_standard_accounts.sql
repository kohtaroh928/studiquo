-- Accounts that existed before Standard became a paid plan and were moved to
-- Standard (see entitlements.js's header). Read only while PAYWALL_ENABLED is
-- "true". Filled once, by hand, just before the paywall is switched on —
-- docs/releases has the procedure. Additive: nothing else reads or writes it.
CREATE TABLE legacy_standard_accounts (
  app_user_id TEXT PRIMARY KEY,
  granted_at INTEGER NOT NULL
);
