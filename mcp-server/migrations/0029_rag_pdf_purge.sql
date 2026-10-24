-- Step5-B is disabled by default. 0014 remains immutable, including its zero flag.
ALTER TABLE rag_pdf_jobs ADD COLUMN writer_version TEXT NOT NULL DEFAULT 'legacy';
CREATE INDEX rag_pdf_jobs_purge_due ON rag_pdf_jobs(settled_at,job_id)
 WHERE state='settled' AND writer_version='floor-v2' AND created_at IS NOT NULL AND settled_at IS NOT NULL;
CREATE TABLE rag_pdf_purge_control (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 contract_version TEXT NOT NULL DEFAULT 'pre-adoption-v1',
 enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
 writer_fenced INTEGER NOT NULL DEFAULT 0 CHECK(writer_fenced IN (0,1)),
 last_clock_at INTEGER NOT NULL,
 requested_at INTEGER,
 cursor_at INTEGER NOT NULL DEFAULT 0 CHECK(cursor_at>=0),
 cursor_job TEXT NOT NULL DEFAULT '',
 next_cursor_at INTEGER NOT NULL DEFAULT 0 CHECK(next_cursor_at>=0),
 next_cursor_job TEXT NOT NULL DEFAULT '',
 candidate_count INTEGER NOT NULL DEFAULT 0 CHECK(candidate_count BETWEEN 0 AND 10),
 lease_id TEXT,
 lease_until INTEGER NOT NULL DEFAULT 0,
 CHECK((lease_id IS NULL AND lease_until=0) OR (lease_id IS NOT NULL AND lease_until>0))
);
INSERT INTO rag_pdf_purge_control(singleton,last_clock_at)
 VALUES(1,CAST(strftime('%s','now') AS INTEGER)*1000);
CREATE TRIGGER rag_pdf_purge_no_replace BEFORE INSERT ON rag_pdf_purge_control
 WHEN EXISTS(SELECT 1 FROM rag_pdf_purge_control WHERE singleton=1) BEGIN
 SELECT RAISE(ABORT,'pdf_purge_control_required');
END;
CREATE TRIGGER rag_pdf_purge_no_delete BEFORE DELETE ON rag_pdf_purge_control BEGIN
 SELECT RAISE(ABORT,'pdf_purge_control_required');
END;
CREATE TRIGGER rag_pdf_purge_monotonic BEFORE UPDATE ON rag_pdf_purge_control
 WHEN NEW.writer_fenced<OLD.writer_fenced OR NEW.last_clock_at<OLD.last_clock_at BEGIN
 SELECT RAISE(ABORT,'pdf_purge_rollback_forbidden');
END;
CREATE TRIGGER rag_pdf_jobs_writer_fence BEFORE INSERT ON rag_pdf_jobs
 WHEN NEW.writer_version!='floor-v2' AND EXISTS(
 SELECT 1 FROM rag_pdf_purge_control WHERE singleton=1 AND writer_fenced=1) BEGIN
 SELECT RAISE(ABORT,'pdf_job_writer_upgrade_required');
END;
-- An existing row must not be moved to a new accounting window/identity.
CREATE TRIGGER rag_pdf_jobs_identity_kept BEFORE UPDATE ON rag_pdf_jobs
 WHEN NEW.job_id!=OLD.job_id OR NEW.account_key!=OLD.account_key OR NEW.document_id!=OLD.document_id
 OR NEW.intake_id!=OLD.intake_id OR NEW.generation!=OLD.generation OR NEW.window_start!=OLD.window_start
 OR NEW.writer_version!=OLD.writer_version BEGIN
 SELECT RAISE(ABORT,'pdf_job_identity_immutable');
END;
-- All expiry predicates use the database clock. Missing intake is held, not
-- treated as proof of revocation. Future adoption must replace this contract.
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
  AND (r.state!='done' OR r.lease_id IS NOT NULL OR r.lease_until!=0));
-- A pass is a single D1 batch: acquire/revalidate, delete, release. Clock gaps
-- over a day need a separately reviewed re-anchor; no automatic blind reset.
CREATE TRIGGER rag_pdf_purge_pass_guard BEFORE UPDATE OF requested_at ON rag_pdf_purge_control BEGIN
 SELECT CASE WHEN NEW.enabled!=1 OR NEW.contract_version!='pre-adoption-v1' OR NEW.writer_fenced!=1
  OR NEW.requested_at IS NULL OR ABS(NEW.requested_at-CAST(strftime('%s','now') AS INTEGER)*1000)>5000
  OR NEW.last_clock_at!=CAST(strftime('%s','now') AS INTEGER)*1000
  OR NEW.last_clock_at<OLD.last_clock_at OR NEW.last_clock_at-OLD.last_clock_at>86400000
  OR NEW.lease_id IS NULL OR NEW.lease_until<=NEW.last_clock_at+1000 OR NEW.lease_until>NEW.requested_at+10000
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'rag_pdf_*')!=5
  OR EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE '%receipt%')
  THEN RAISE(ABORT,'pdf_purge_pass_not_authorized') END;
END;
CREATE TRIGGER rag_pdf_jobs_purge_guard BEFORE DELETE ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM rag_pdf_purge_control p JOIN rag_pdf_retention_control c USING(singleton)
  WHERE p.singleton=1 AND p.enabled=1 AND p.writer_fenced=1 AND p.contract_version='pre-adoption-v1'
   AND p.lease_id IS NOT NULL AND p.lease_until>CAST(strftime('%s','now') AS INTEGER)*1000+1000
   AND p.last_clock_at<=CAST(strftime('%s','now') AS INTEGER)*1000
   AND CAST(strftime('%s','now') AS INTEGER)*1000-p.last_clock_at<=10000
   AND c.policy_version='raw-pdf-retention-v1' AND c.physical_purge_enabled=0)
  OR (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'rag_pdf_*')!=5
  OR EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name LIKE '%receipt%')
  OR NOT EXISTS(SELECT 1 FROM rag_pdf_purge_eligible WHERE job_id=OLD.job_id)
  THEN RAISE(ABORT,'pdf_job_purge_not_authorized') END;
 UPDATE rag_pdf_retention_control SET min_admission_window=MAX(min_admission_window,OLD.window_start+86400000) WHERE singleton=1;
 DELETE FROM rag_pdf_job_recovery WHERE job_id=OLD.job_id AND state='done' AND lease_id IS NULL AND lease_until=0;
END;
