-- Push fan-out state for an announcement. A push is sent in small batches
-- (one admin-page request each) so a single Worker invocation never has to
-- call APNs for every device; these columns remember where the walk over the
-- device registry is and what has happened so far.
--   push_state:   NULL (never sent) | 'sending' | 'sent'
--   push_cursor:  KV list cursor of the next batch ('' = start)
--   push_batches: bumped by every claimed batch; the compare-and-set on it
--                 is what stops two overlapping requests from sending the
--                 same batch twice.
ALTER TABLE announcements ADD COLUMN push_state TEXT;
ALTER TABLE announcements ADD COLUMN push_cursor TEXT NOT NULL DEFAULT '';
ALTER TABLE announcements ADD COLUMN push_batches INTEGER NOT NULL DEFAULT 0;
ALTER TABLE announcements ADD COLUMN push_users INTEGER NOT NULL DEFAULT 0;
ALTER TABLE announcements ADD COLUMN push_delivered INTEGER NOT NULL DEFAULT 0;
ALTER TABLE announcements ADD COLUMN push_failed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE announcements ADD COLUMN push_started_at INTEGER;
ALTER TABLE announcements ADD COLUMN push_sent_at INTEGER;
