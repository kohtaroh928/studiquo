-- Chat reports a person filed from the app, kept where an operator can read
-- them (they used to be write-only KV entries nothing ever read), and an
-- append-only log of what the operator did in the admin API.
-- Apply before deploying the Worker that uses them. Epoch milliseconds.

CREATE TABLE chat_reports (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  message_id INTEGER NOT NULL,
  reporter_key TEXT NOT NULL,          -- '' once the reporter's account is deleted
  reported_key TEXT NOT NULL,          -- the message's sender
  reason TEXT NOT NULL,
  snapshot TEXT NOT NULL,              -- JSON: the message and its neighbours AS THEY WERE when reported
  status TEXT NOT NULL DEFAULT 'open', -- open | in_progress | resolved | dismissed
  admin_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
-- One report per person per message; filing again is a no-op.
CREATE UNIQUE INDEX idx_chat_reports_once ON chat_reports (reporter_key, room_id, message_id);
CREATE INDEX idx_chat_reports_status ON chat_reports (status, created_at);
CREATE INDEX idx_chat_reports_reported ON chat_reports (reported_key);

CREATE TABLE admin_audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL,                 -- Cloudflare Access identity (email, else subject)
  action TEXT NOT NULL,                -- e.g. announcement.delete, chat_report.view
  target TEXT NOT NULL DEFAULT '',     -- the id acted on
  detail TEXT NOT NULL DEFAULT ''      -- short, never message or report text
);
CREATE INDEX idx_admin_audit_at ON admin_audit_log (at);

-- Append-only: rows can never be edited, and only rows older than a year can
-- be removed (the retention period).
CREATE TRIGGER admin_audit_log_no_update BEFORE UPDATE ON admin_audit_log
BEGIN SELECT RAISE(ABORT, 'admin_audit_log is append-only'); END;
CREATE TRIGGER admin_audit_log_keep_a_year BEFORE DELETE ON admin_audit_log
WHEN OLD.at > (CAST(strftime('%s','now') AS INTEGER) * 1000 - 31536000000)
BEGIN SELECT RAISE(ABORT, 'admin_audit_log rows are kept for a year'); END;

-- Announcements are no longer erased: deleting one hides it.
ALTER TABLE announcements ADD COLUMN deleted_at INTEGER;
