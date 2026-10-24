-- Step6-B: add the evidence child to the reviewed pre-adoption purge contract.
-- Disable any previous opt-in. Preserve writer fence, admission floor and clocks.
ALTER TABLE rag_pdf_purge_control ADD COLUMN purging_job TEXT;
UPDATE rag_pdf_purge_control SET enabled=0,contract_version='pre-adoption-stop-v2',lease_id=NULL,lease_until=0;
DROP VIEW rag_pdf_purge_eligible;
DROP TRIGGER rag_pdf_purge_pass_guard;
DROP TRIGGER rag_pdf_jobs_purge_guard;


-- Rebuild only the minimal evidence table to add FK cascade; all rows and
-- immutable proofs are copied unchanged. No parent job/account data is removed.
DROP TRIGGER rag_pdf_evidence_claim_bind;
DROP TRIGGER rag_pdf_evidence_claimed;
DROP TRIGGER rag_pdf_evidence_no_replace;
DROP TRIGGER rag_pdf_evidence_monotonic;
DROP TRIGGER rag_pdf_evidence_no_delete;
DROP TRIGGER rag_pdf_evidence_execution_fenced;
DROP TRIGGER rag_pdf_evidence_settle_guard;
ALTER TABLE rag_pdf_execution_evidence RENAME TO rag_pdf_execution_evidence_previous;
CREATE TABLE rag_pdf_execution_evidence (
 job_id TEXT PRIMARY KEY REFERENCES rag_pdf_jobs(job_id) ON DELETE CASCADE,
 claim_hash TEXT NOT NULL CHECK(length(claim_hash)=64),
 protocol TEXT NOT NULL CHECK(protocol='stop-proof-v1'),
 local_stopped_at INTEGER CHECK(local_stopped_at IS NULL OR local_stopped_at BETWEEN 0 AND 9007199254740991),
 remote_stopped_at INTEGER CHECK(remote_stopped_at IS NULL OR remote_stopped_at BETWEEN 0 AND 9007199254740991),
 remote_kind TEXT CHECK(remote_kind IS NULL OR remote_kind IN ('cancel_confirmed','not_dispatched')),
 CHECK((remote_stopped_at IS NULL AND remote_kind IS NULL) OR (remote_stopped_at IS NOT NULL AND remote_kind IS NOT NULL))
);
INSERT INTO rag_pdf_execution_evidence SELECT * FROM rag_pdf_execution_evidence_previous;
DROP TABLE rag_pdf_execution_evidence_previous;
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

CREATE VIEW rag_pdf_purge_eligible AS SELECT j.job_id,j.settled_at FROM rag_pdf_jobs j
 WHERE j.state='settled' AND j.writer_version='floor-v2' AND j.created_at IS NOT NULL AND j.settled_at IS NOT NULL
 AND j.created_at<=j.settled_at AND j.settled_at<=CAST(strftime('%s','now') AS INTEGER)*1000-172800000
 AND j.window_start>=0 AND j.window_start%86400000=0
 AND j.window_start<(CAST(strftime('%s','now') AS INTEGER)/86400)*86400000
 AND EXISTS(SELECT 1 FROM rag_pdf_intakes i WHERE i.account_key=j.account_key AND i.document_id=j.document_id
  AND ((i.intake_id=j.intake_id AND i.generation=j.generation AND i.state='cancelled')
   OR (i.intake_id!=j.intake_id AND i.generation>j.generation)))
 AND NOT EXISTS(SELECT 1 FROM rag_documents d WHERE d.account_key=j.account_key AND d.document_id=j.document_id)
 AND NOT EXISTS(SELECT 1 FROM rag_pdf_job_recovery r WHERE r.job_id=j.job_id
  AND (r.state!='done' OR r.lease_id IS NOT NULL OR r.lease_until!=0))
 AND ((j.claim_protocol='legacy' AND NOT EXISTS(SELECT 1 FROM rag_pdf_execution_evidence e WHERE e.job_id=j.job_id))
  OR (j.claim_protocol='stop-proof-v1' AND EXISTS(SELECT 1 FROM rag_pdf_execution_evidence e WHERE e.job_id=j.job_id
   AND e.protocol=j.claim_protocol AND e.claim_hash=j.token_hash AND e.local_stopped_at IS NOT NULL
   AND e.remote_stopped_at IS NOT NULL AND e.local_stopped_at<=j.settled_at AND e.remote_stopped_at<=j.settled_at
   AND (e.remote_kind='cancel_confirmed' OR (e.remote_kind='not_dispatched' AND j.ever_dispatched=0)))));

CREATE TRIGGER rag_pdf_purge_pass_guard BEFORE UPDATE OF requested_at ON rag_pdf_purge_control BEGIN
 SELECT CASE WHEN NEW.purging_job IS NOT NULL OR NEW.enabled!=1 OR NEW.contract_version!='pre-adoption-stop-v2' OR NEW.writer_fenced!=1
  OR NEW.requested_at IS NULL OR ABS(NEW.requested_at-CAST(strftime('%s','now') AS INTEGER)*1000)>5000
  OR NEW.last_clock_at!=CAST(strftime('%s','now') AS INTEGER)*1000
  OR NEW.last_clock_at<OLD.last_clock_at OR NEW.last_clock_at-OLD.last_clock_at>86400000
  OR NEW.lease_id IS NULL OR NEW.lease_until<=NEW.last_clock_at+1000 OR NEW.lease_until>NEW.requested_at+10000
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'rag_pdf_*')!=6
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('rag_pdf_purge_context_guard','rag_pdf_purge_context_clear'))!=2
  OR NOT EXISTS(SELECT 1 FROM pragma_foreign_key_list('rag_pdf_execution_evidence') WHERE "table"='rag_pdf_jobs' AND "from"='job_id' AND "to"='job_id' AND on_delete='CASCADE')
  OR EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE '%receipt%')
  THEN RAISE(ABORT,'pdf_purge_pass_not_authorized') END;
END;
CREATE TRIGGER rag_pdf_jobs_purge_guard BEFORE DELETE ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM rag_pdf_purge_control p JOIN rag_pdf_retention_control c USING(singleton)
  WHERE p.singleton=1 AND p.purging_job IS NULL AND p.enabled=1 AND p.writer_fenced=1 AND p.contract_version='pre-adoption-stop-v2'
   AND p.lease_id IS NOT NULL AND p.lease_until>CAST(strftime('%s','now') AS INTEGER)*1000+1000
   AND p.last_clock_at<=CAST(strftime('%s','now') AS INTEGER)*1000
   AND CAST(strftime('%s','now') AS INTEGER)*1000-p.last_clock_at<=10000
   AND c.policy_version='raw-pdf-retention-v1' AND c.physical_purge_enabled=0)
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'rag_pdf_*')!=6
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('rag_pdf_purge_context_guard','rag_pdf_purge_context_clear'))!=2
  OR NOT EXISTS(SELECT 1 FROM pragma_foreign_key_list('rag_pdf_execution_evidence') WHERE "table"='rag_pdf_jobs' AND "from"='job_id' AND "to"='job_id' AND on_delete='CASCADE')
  OR EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE '%receipt%')
  OR NOT EXISTS(SELECT 1 FROM rag_pdf_purge_eligible WHERE job_id=OLD.job_id)
  THEN RAISE(ABORT,'pdf_job_purge_not_authorized') END;
 UPDATE rag_pdf_retention_control SET min_admission_window=MAX(min_admission_window,OLD.window_start+86400000) WHERE singleton=1;
 UPDATE rag_pdf_purge_control SET purging_job=OLD.job_id WHERE singleton=1;
 DELETE FROM rag_pdf_job_recovery WHERE job_id=OLD.job_id AND state='done' AND lease_id IS NULL AND lease_until=0;
END;
-- Cascading child deletion happens after the parent row is removed. Keep the
-- context until the parent AFTER trigger, so direct child deletion cannot mimic it.
CREATE TRIGGER rag_pdf_purge_context_clear AFTER DELETE ON rag_pdf_jobs BEGIN
 UPDATE rag_pdf_purge_control SET purging_job=NULL WHERE singleton=1;
END;

-- Context alone cannot authorize a child delete: the FK parent must already
-- be absent within its cascade. Manually setting context cannot fake this.
-- Child deletion, recovery deletion, context/floor update and parent deletion
-- all roll back together on any trigger failure.
CREATE TRIGGER rag_pdf_purge_context_guard BEFORE UPDATE OF purging_job ON rag_pdf_purge_control
 WHEN NEW.purging_job IS NOT NULL BEGIN
 SELECT CASE WHEN OLD.purging_job IS NOT NULL OR NEW.enabled!=1 OR NEW.contract_version!='pre-adoption-stop-v2'
  OR NEW.lease_id IS NULL OR NEW.lease_until<=CAST(strftime('%s','now') AS INTEGER)*1000+1000
  OR NOT EXISTS(SELECT 1 FROM rag_pdf_purge_eligible WHERE job_id=NEW.purging_job)
  THEN RAISE(ABORT,'pdf_purge_context_not_authorized') END;
END;
CREATE TRIGGER rag_pdf_evidence_no_delete BEFORE DELETE ON rag_pdf_execution_evidence BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM rag_pdf_purge_control p WHERE p.singleton=1
  AND p.purging_job=OLD.job_id AND p.enabled=1 AND p.writer_fenced=1 AND p.contract_version='pre-adoption-stop-v2'
  AND p.lease_id IS NOT NULL AND p.lease_until>CAST(strftime('%s','now') AS INTEGER)*1000+1000)
  OR EXISTS(SELECT 1 FROM rag_pdf_jobs WHERE job_id=OLD.job_id)
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'rag_pdf_*')!=6
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('rag_pdf_purge_context_guard','rag_pdf_purge_context_clear'))!=2
  OR NOT EXISTS(SELECT 1 FROM pragma_foreign_key_list('rag_pdf_execution_evidence') WHERE "table"='rag_pdf_jobs' AND "from"='job_id' AND "to"='job_id' AND on_delete='CASCADE')
  OR EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE '%receipt%')
  THEN RAISE(ABORT,'pdf_stop_evidence_retention_required') END;
END;
