-- Step6-A: opt-in claim protocol, no retrofit of existing/legacy execution.
ALTER TABLE rag_pdf_jobs ADD COLUMN claim_protocol TEXT NOT NULL DEFAULT 'legacy'
 CHECK(claim_protocol IN ('legacy','stop-proof-v1'));
CREATE TABLE rag_pdf_execution_evidence (
 job_id TEXT PRIMARY KEY REFERENCES rag_pdf_jobs(job_id),
 claim_hash TEXT NOT NULL CHECK(length(claim_hash)=64),
 protocol TEXT NOT NULL CHECK(protocol='stop-proof-v1'),
 local_stopped_at INTEGER CHECK(local_stopped_at IS NULL OR local_stopped_at BETWEEN 0 AND 9007199254740991),
 remote_stopped_at INTEGER CHECK(remote_stopped_at IS NULL OR remote_stopped_at BETWEEN 0 AND 9007199254740991),
 remote_kind TEXT CHECK(remote_kind IS NULL OR remote_kind IN ('cancel_confirmed','not_dispatched')),
 CHECK((remote_stopped_at IS NULL AND remote_kind IS NULL) OR (remote_stopped_at IS NOT NULL AND remote_kind IS NOT NULL))
);
CREATE TRIGGER rag_pdf_evidence_claim_bind BEFORE UPDATE ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN (OLD.token_hash IS NOT NULL AND (NEW.token_hash IS NOT OLD.token_hash OR NEW.claim_protocol!=OLD.claim_protocol))
  OR (OLD.claim_protocol='legacy' AND NEW.claim_protocol='stop-proof-v1' AND (OLD.token_hash IS NOT NULL OR OLD.state!='reserved' OR NEW.state!='receiving'))
  THEN RAISE(ABORT,'pdf_stop_claim_immutable') END;
END;
CREATE TRIGGER rag_pdf_evidence_claimed AFTER UPDATE ON rag_pdf_jobs
 WHEN OLD.token_hash IS NULL AND NEW.token_hash IS NOT NULL AND NEW.claim_protocol='stop-proof-v1' BEGIN
 INSERT INTO rag_pdf_execution_evidence(job_id,claim_hash,protocol) VALUES(NEW.job_id,NEW.token_hash,'stop-proof-v1');
END;
CREATE TRIGGER rag_pdf_evidence_no_replace BEFORE INSERT ON rag_pdf_execution_evidence BEGIN
 SELECT CASE WHEN EXISTS(SELECT 1 FROM rag_pdf_execution_evidence WHERE job_id=NEW.job_id)
  OR NOT EXISTS(SELECT 1 FROM rag_pdf_jobs WHERE job_id=NEW.job_id AND token_hash=NEW.claim_hash
   AND claim_protocol=NEW.protocol AND state='receiving')
  THEN RAISE(ABORT,'pdf_stop_evidence_not_authorized') END;
END;
CREATE TRIGGER rag_pdf_evidence_monotonic BEFORE UPDATE ON rag_pdf_execution_evidence BEGIN
 SELECT CASE WHEN NEW.job_id!=OLD.job_id OR NEW.claim_hash!=OLD.claim_hash OR NEW.protocol!=OLD.protocol
  OR (OLD.local_stopped_at IS NOT NULL AND NEW.local_stopped_at IS NOT OLD.local_stopped_at)
  OR (OLD.remote_stopped_at IS NOT NULL AND (NEW.remote_stopped_at IS NOT OLD.remote_stopped_at OR NEW.remote_kind IS NOT OLD.remote_kind))
  OR NOT EXISTS(SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=NEW.job_id AND j.token_hash=NEW.claim_hash AND j.claim_protocol=NEW.protocol)
  OR (OLD.local_stopped_at IS NULL AND NEW.local_stopped_at IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=NEW.job_id AND j.state='stop_requested'))
  OR (NEW.remote_kind='not_dispatched' AND (NEW.local_stopped_at IS NULL OR NOT EXISTS(
   SELECT 1 FROM rag_pdf_jobs j WHERE j.job_id=NEW.job_id AND j.ever_dispatched=0 AND j.state IN ('stop_requested','settled'))))
  THEN RAISE(ABORT,'pdf_stop_evidence_not_authorized') END;
END;
CREATE TRIGGER rag_pdf_evidence_no_delete BEFORE DELETE ON rag_pdf_execution_evidence BEGIN
 SELECT RAISE(ABORT,'pdf_stop_evidence_retention_required');
END;
CREATE TRIGGER rag_pdf_evidence_execution_fenced BEFORE UPDATE ON rag_pdf_jobs
 WHEN NEW.claim_protocol='stop-proof-v1' AND EXISTS(SELECT 1 FROM rag_pdf_execution_evidence e
  WHERE e.job_id=OLD.job_id AND e.local_stopped_at IS NOT NULL)
  AND (NEW.state IN ('receiving','dispatched') OR NEW.ever_dispatched!=OLD.ever_dispatched) BEGIN
 SELECT RAISE(ABORT,'pdf_execution_already_stopped');
END;
CREATE TRIGGER rag_pdf_evidence_settle_guard BEFORE UPDATE OF state ON rag_pdf_jobs
 WHEN NEW.claim_protocol='stop-proof-v1' AND NEW.state='settled' AND OLD.state!='settled' BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM rag_pdf_execution_evidence e WHERE e.job_id=NEW.job_id
  AND e.claim_hash=NEW.token_hash AND e.protocol=NEW.claim_protocol AND e.local_stopped_at IS NOT NULL
  AND e.remote_stopped_at IS NOT NULL AND (e.remote_kind='cancel_confirmed' OR (e.remote_kind='not_dispatched' AND NEW.ever_dispatched=0)))
  THEN RAISE(ABORT,'pdf_stop_evidence_incomplete') END;
END;
-- The extra PDF table deliberately closes the 0015 pre-adoption purge gate.
-- Step6-B must add a reviewed atomic evidence/parent retention contract first.
