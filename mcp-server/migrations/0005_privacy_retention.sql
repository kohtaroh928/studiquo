-- Apply before deploying the privacy retention Worker. Epoch milliseconds.
ALTER TABLE issue_reports ADD COLUMN account_key TEXT;
CREATE INDEX idx_issue_reports_account ON issue_reports (account_key);
CREATE INDEX idx_issue_reports_created ON issue_reports (created_at);
ALTER TABLE app_error_users ADD COLUMN last_seen_at INTEGER NOT NULL DEFAULT 0;
-- Existing links have no trustworthy timestamp; remove them at first sweep.
CREATE INDEX idx_app_error_users_last_seen ON app_error_users (last_seen_at);
CREATE TABLE privacy_deleted_customers (
  customer_hash TEXT PRIMARY KEY,
  deleted_at INTEGER NOT NULL
);
