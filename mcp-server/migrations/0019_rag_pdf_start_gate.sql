-- One-shot start permission, not evidence of actual VM start or stop.
-- Existing rows stay unknown/legacy. Never infer that NULL means not executed.
ALTER TABLE rag_pdf_jobs ADD COLUMN start_protocol TEXT NOT NULL DEFAULT 'legacy' CHECK(start_protocol IN ('legacy','one-shot-v1'));
ALTER TABLE rag_pdf_jobs ADD COLUMN start_claim_id TEXT;
ALTER TABLE rag_pdf_jobs ADD COLUMN start_claimed_at INTEGER;
CREATE TRIGGER rag_pdf_start_insert BEFORE INSERT ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN EXISTS(SELECT 1 FROM rag_pdf_jobs WHERE job_id=NEW.job_id)
 THEN RAISE(ABORT,'pdf_start_immutable') END;
 SELECT CASE WHEN NEW.start_protocol!='legacy' OR NEW.start_claim_id IS NOT NULL OR NEW.start_claimed_at IS NOT NULL
 THEN RAISE(ABORT,'pdf_start_invalid') END;
END;
CREATE TRIGGER rag_pdf_start_update BEFORE UPDATE ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN OLD.start_protocol='one-shot-v1' AND NEW.start_protocol IS NOT OLD.start_protocol
 THEN RAISE(ABORT,'pdf_start_immutable') END;
 SELECT CASE WHEN OLD.start_protocol='legacy' AND NEW.start_protocol='one-shot-v1' AND NOT (
  OLD.state='receiving' AND NEW.state='dispatched' AND OLD.ever_dispatched=0 AND NEW.ever_dispatched=1
  AND OLD.rpc_version=1 AND NEW.rpc_version=2 AND NEW.rpc_not_after=OLD.deadline
  AND OLD.token_hash IS NOT NULL AND NEW.token_hash IS OLD.token_hash
  AND NEW.claim_protocol='stop-proof-v1' AND NEW.start_claim_id IS NULL AND NEW.start_claimed_at IS NULL)
 THEN RAISE(ABORT,'pdf_start_invalid') END;
 SELECT CASE WHEN NEW.start_protocol='legacy' AND (NEW.start_claim_id IS NOT NULL OR NEW.start_claimed_at IS NOT NULL)
 THEN RAISE(ABORT,'pdf_start_invalid') END;
 SELECT CASE WHEN OLD.start_claim_id IS NOT NULL AND (NEW.start_claim_id IS NOT OLD.start_claim_id OR NEW.start_claimed_at IS NOT OLD.start_claimed_at)
 THEN RAISE(ABORT,'pdf_start_immutable') END;
 SELECT CASE WHEN (NEW.start_claim_id IS NULL)!=(NEW.start_claimed_at IS NULL)
 THEN RAISE(ABORT,'pdf_start_invalid') END;
 SELECT CASE WHEN OLD.start_claim_id IS NULL AND NEW.start_claim_id IS NOT NULL AND NOT (
  OLD.start_protocol='one-shot-v1' AND NEW.start_protocol=OLD.start_protocol
  AND OLD.state='dispatched' AND NEW.state=OLD.state AND OLD.ever_dispatched=1
  AND NEW.rpc_version=2 AND NEW.rpc_not_after=NEW.deadline
  AND NEW.token_hash IS OLD.token_hash AND NEW.claim_protocol='stop-proof-v1'
  AND typeof(NEW.start_claim_id)='text' AND length(NEW.start_claim_id)=36
  AND length(replace(NEW.start_claim_id,'-',''))=32 AND replace(NEW.start_claim_id,'-','') NOT GLOB '*[^0-9a-f]*'
  AND NEW.start_claim_id=lower(NEW.start_claim_id) AND NEW.start_claim_id NOT GLOB '*[^0-9a-f-]*'
  AND substr(NEW.start_claim_id,9,1)='-' AND substr(NEW.start_claim_id,14,1)='-'
  AND substr(NEW.start_claim_id,19,1)='-' AND substr(NEW.start_claim_id,24,1)='-'
  AND substr(NEW.start_claim_id,15,1)='4' AND substr(NEW.start_claim_id,20,1) IN ('8','9','a','b')
  AND typeof(NEW.start_claimed_at)='integer' AND NEW.start_claimed_at>=0
  AND NEW.start_claimed_at<NEW.deadline AND NEW.start_claimed_at<=9007199254740991)
 THEN RAISE(ABORT,'pdf_start_invalid') END;
END;
-- C1 cannot purge a new-protocol parent. Narrow eligibility so mixed coarse
-- batches still advance past retained rows instead of aborting every pass.
CREATE TRIGGER rag_pdf_start_parent_kept BEFORE DELETE ON rag_pdf_jobs
 WHEN OLD.start_protocol!='legacy' BEGIN
 SELECT RAISE(ABORT,'pdf_start_retention_required');
END;
DROP VIEW rag_pdf_purge_eligible;
CREATE VIEW rag_pdf_purge_eligible AS SELECT j.job_id,j.settled_at FROM rag_pdf_jobs j
 WHERE j.start_protocol='legacy' AND j.state='settled' AND j.writer_version='floor-v2' AND j.created_at IS NOT NULL AND j.settled_at IS NOT NULL
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
