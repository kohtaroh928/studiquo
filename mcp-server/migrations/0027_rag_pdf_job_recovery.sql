-- Stop retry journal only. No PDF, owner, digest, or executor token.
CREATE TABLE rag_pdf_job_recovery (
 job_id TEXT PRIMARY KEY REFERENCES rag_pdf_jobs(job_id),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 next_attempt_at INTEGER NOT NULL DEFAULT 0,
 lease_id TEXT,
 lease_until INTEGER NOT NULL DEFAULT 0,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','remote_stopped','needs_attention','done')),
 outcome TEXT NOT NULL DEFAULT 'none' CHECK(outcome IN ('none','confirmed','failed','timeout','exhausted','settled')),
 remote_stopped_at INTEGER,
 CHECK((lease_id IS NULL AND lease_until=0) OR (lease_id IS NOT NULL AND lease_until>0))
);
CREATE INDEX rag_pdf_recovery_due ON rag_pdf_job_recovery(state,next_attempt_at,lease_until);
