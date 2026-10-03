-- Admin dashboard inbox: what people report by hand ("問題を報告") and what
-- the app sends by itself (crashes, hangs, a few known non-fatal errors).
--
-- issue_reports used to live only in KV (90-day TTL, no way to list or mark
-- one handled). The screenshot stays in KV (it is large); everything the
-- dashboard filters, sorts and updates lives here.
CREATE TABLE issue_reports (
  id TEXT PRIMARY KEY,
  reporter_key TEXT NOT NULL,
  description TEXT NOT NULL,
  app_version TEXT NOT NULL DEFAULT '',
  os_version TEXT NOT NULL DEFAULT '',
  device_model TEXT NOT NULL DEFAULT '',
  language TEXT NOT NULL DEFAULT '',
  has_screenshot INTEGER NOT NULL DEFAULT 0,
  -- open | in_progress | resolved
  status TEXT NOT NULL DEFAULT 'open',
  admin_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_issue_reports_status_created ON issue_reports (status, created_at);

-- One row per distinct problem, not per occurrence: a bug that hits a
-- thousand people is one row with occurrences = N and N distinct users.
CREATE TABLE app_errors (
  fingerprint TEXT PRIMARY KEY,
  -- crash | hang | cpu | disk | error
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  occurrences INTEGER NOT NULL DEFAULT 0,
  last_app_version TEXT NOT NULL DEFAULT '',
  last_os_version TEXT NOT NULL DEFAULT '',
  last_device_model TEXT NOT NULL DEFAULT '',
  -- open | in_progress | resolved
  status TEXT NOT NULL DEFAULT 'open',
  admin_note TEXT NOT NULL DEFAULT '',
  -- The newest app version seen when this was marked resolved. Only an
  -- occurrence from a *newer* version reopens it: old builds still in the
  -- wild keep hitting a bug that is already fixed.
  resolved_after_version TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_app_errors_status_last_seen ON app_errors (status, last_seen_at);

-- Distinct accounts affected per problem. user_key uses the same
-- "usage-account:" hash as usage_events, so deleting an account removes it.
CREATE TABLE app_error_users (
  fingerprint TEXT NOT NULL,
  user_key TEXT NOT NULL,
  PRIMARY KEY (fingerprint, user_key)
);
CREATE INDEX idx_app_error_users_user_key ON app_error_users (user_key);
