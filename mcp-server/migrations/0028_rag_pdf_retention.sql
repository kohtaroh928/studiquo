-- Additive only. NULL means unknown; never infer settlement time from deadline.
ALTER TABLE rag_pdf_jobs ADD COLUMN created_at INTEGER CHECK(created_at IS NULL OR created_at BETWEEN 0 AND 9007199254740991);
ALTER TABLE rag_pdf_jobs ADD COLUMN settled_at INTEGER CHECK(settled_at IS NULL OR settled_at BETWEEN 0 AND 9007199254740991);
CREATE INDEX rag_pdf_jobs_settled_at ON rag_pdf_jobs(state,settled_at);
CREATE INDEX rag_pdf_intakes_retention_due ON rag_pdf_intakes(expires_at)
 WHERE state='pending' OR (state='cancelled' AND request_id!='');

-- Step5-A cannot enable physical purge. No public setter or scheduler yet.
CREATE TABLE rag_pdf_retention_control (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 policy_version TEXT NOT NULL CHECK(policy_version='raw-pdf-retention-v1'),
 min_admission_window INTEGER NOT NULL DEFAULT 0
  CHECK(min_admission_window BETWEEN 0 AND 9007199254740991 AND min_admission_window%86400000=0),
 physical_purge_enabled INTEGER NOT NULL DEFAULT 0 CHECK(physical_purge_enabled=0)
);
INSERT INTO rag_pdf_retention_control(singleton,policy_version) VALUES(1,'raw-pdf-retention-v1');
CREATE TRIGGER rag_pdf_retention_control_no_replace BEFORE INSERT ON rag_pdf_retention_control
 WHEN EXISTS(SELECT 1 FROM rag_pdf_retention_control WHERE singleton=1) BEGIN
 SELECT RAISE(ABORT,'pdf_retention_control_required');
END;
CREATE TRIGGER rag_pdf_retention_floor_monotonic BEFORE UPDATE ON rag_pdf_retention_control
 WHEN NEW.min_admission_window<OLD.min_admission_window BEGIN
 SELECT RAISE(ABORT,'pdf_retention_floor_rollback');
END;
CREATE TRIGGER rag_pdf_retention_control_kept BEFORE DELETE ON rag_pdf_retention_control BEGIN
 SELECT RAISE(ABORT,'pdf_retention_control_required');
END;
-- Defense for old reserve writers too. Step5-A never advances this floor.
CREATE TRIGGER rag_pdf_jobs_retention_floor BEFORE INSERT ON rag_pdf_jobs
 WHEN NOT EXISTS(SELECT 1 FROM rag_pdf_retention_control WHERE singleton=1
  AND policy_version='raw-pdf-retention-v1' AND NEW.window_start>=min_admission_window) BEGIN
 SELECT RAISE(ABORT,'pdf_job_admission_window_closed');
END;
