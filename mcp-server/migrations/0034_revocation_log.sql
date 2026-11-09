-- Append-only record of revocations (account deleted, sessions cut off, suspension,
-- connected apps removed), kept OUTSIDE the KV namespace so that a KV restore from an
-- old backup can have them re-applied (security/revocation-reapply, docs/BACKUP_AND_RECOVERY.md).
-- Holds hashes and kinds only: no e-mail, no name, no content.
CREATE TABLE revocation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('account-deleted','account-reregistered','session-cutoff','suspension-set','suspension-cleared','connections-revoked')),
  subject TEXT NOT NULL,              -- an identity hash, or the suspension KV key
  value TEXT NOT NULL DEFAULT ''      -- session-cutoff: the cut-off (ms); otherwise empty
);
CREATE INDEX idx_revocation_log_at ON revocation_log (at);
CREATE TRIGGER revocation_log_no_update BEFORE UPDATE ON revocation_log
BEGIN SELECT RAISE(ABORT, 'revocation_log is append-only'); END;
CREATE TRIGGER revocation_log_no_delete BEFORE DELETE ON revocation_log
BEGIN SELECT RAISE(ABORT, 'revocation_log is append-only'); END;
