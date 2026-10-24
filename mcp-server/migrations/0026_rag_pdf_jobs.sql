-- Admission accounting only: no PDF, title, raw digest, token or parser output.
CREATE TABLE rag_pdf_jobs (
 job_id TEXT PRIMARY KEY,
 account_key TEXT NOT NULL,
 document_id TEXT NOT NULL,
 intake_id TEXT NOT NULL UNIQUE,
 generation INTEGER NOT NULL,
 consent_epoch INTEGER NOT NULL,
 raw_consent_epoch INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','receiving','dispatched','stop_requested','settled')),
 token_hash TEXT,
 ever_dispatched INTEGER NOT NULL DEFAULT 0 CHECK(ever_dispatched IN (0,1)),
 window_start INTEGER NOT NULL,
 reserved_units INTEGER NOT NULL CHECK(reserved_units>0),
 settled_units INTEGER,
 memory_weight INTEGER NOT NULL CHECK(memory_weight=67108864),
 policy_version TEXT NOT NULL,
 deadline INTEGER NOT NULL,
 CHECK((state='settled' AND settled_units IS NOT NULL AND settled_units BETWEEN 0 AND reserved_units)
   OR (state!='settled' AND settled_units IS NULL)),
 CHECK(ever_dispatched=0 OR token_hash IS NOT NULL)
);
CREATE INDEX rag_pdf_jobs_owner_window ON rag_pdf_jobs(account_key,window_start);
CREATE INDEX rag_pdf_jobs_window ON rag_pdf_jobs(window_start);
CREATE INDEX rag_pdf_jobs_state ON rag_pdf_jobs(state);
CREATE TRIGGER rag_pdf_jobs_intake_changed AFTER UPDATE ON rag_pdf_intakes
WHEN OLD.intake_id!=NEW.intake_id OR OLD.state!=NEW.state
 OR OLD.generation!=NEW.generation OR OLD.consent_epoch!=NEW.consent_epoch
 OR OLD.raw_consent_epoch!=NEW.raw_consent_epoch OR OLD.pdf_sha256 IS NOT NEW.pdf_sha256
 OR OLD.byte_length IS NOT NEW.byte_length OR OLD.expires_at!=NEW.expires_at BEGIN
 UPDATE rag_pdf_jobs SET state='stop_requested'
 WHERE intake_id=OLD.intake_id AND state!='settled';
END;
CREATE TRIGGER rag_pdf_jobs_intake_deleted AFTER DELETE ON rag_pdf_intakes BEGIN
 UPDATE rag_pdf_jobs SET state='stop_requested'
 WHERE intake_id=OLD.intake_id AND state!='settled';
END;
