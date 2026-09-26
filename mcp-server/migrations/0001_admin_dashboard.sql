-- Admin dashboard: RevenueCat's raw webhook events (append-only, the source
-- of truth for revenue history and monthly trend charts), each subscriber's
-- current status (a small table kept in sync with the log above so "how
-- many active subscribers right now" doesn't require rescanning the whole
-- log), and the not-yet-wired-up usage-event log (app-open pings) that DAU/
-- MAU and retention will read from once the app itself starts sending them.

CREATE TABLE revenuecat_events (
  event_id TEXT PRIMARY KEY,
  app_user_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  period_type TEXT,
  product_id TEXT,
  price_in_purchased_currency REAL,
  currency TEXT,
  environment TEXT NOT NULL,
  occurred_at INTEGER NOT NULL
);
CREATE INDEX idx_revenuecat_events_occurred_at ON revenuecat_events (occurred_at);
CREATE INDEX idx_revenuecat_events_app_user_id ON revenuecat_events (app_user_id, occurred_at);

CREATE TABLE subscribers (
  app_user_id TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  product_id TEXT,
  expires_at INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_subscribers_status ON subscribers (status);

CREATE TABLE usage_events (
  id TEXT PRIMARY KEY,
  user_key TEXT NOT NULL,
  occurred_at INTEGER NOT NULL
);
CREATE INDEX idx_usage_events_occurred_at ON usage_events (occurred_at);
CREATE INDEX idx_usage_events_user_key ON usage_events (user_key, occurred_at);

CREATE TABLE users_first_seen (
  user_key TEXT PRIMARY KEY,
  first_seen_at INTEGER NOT NULL
);
