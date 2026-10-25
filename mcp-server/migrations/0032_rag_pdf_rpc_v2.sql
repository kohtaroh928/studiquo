-- Additive dispatch contract. Existing jobs stay legacy; never backfill a digest.
-- The digest is PDF-linkable metadata, retained/purged with its accounting parent.
ALTER TABLE rag_pdf_jobs ADD COLUMN rpc_version INTEGER NOT NULL DEFAULT 1 CHECK(rpc_version IN (1,2));
ALTER TABLE rag_pdf_jobs ADD COLUMN rpc_pdf_sha256 TEXT;
ALTER TABLE rag_pdf_jobs ADD COLUMN rpc_not_after INTEGER;
CREATE TRIGGER rag_pdf_jobs_rpc_insert BEFORE INSERT ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN NEW.rpc_version!=1 OR NEW.rpc_pdf_sha256 IS NOT NULL OR NEW.rpc_not_after IS NOT NULL
 THEN RAISE(ABORT,'pdf_rpc_contract_invalid') END;
END;
CREATE TRIGGER rag_pdf_jobs_rpc_update BEFORE UPDATE ON rag_pdf_jobs BEGIN
 SELECT CASE WHEN NEW.deadline IS NOT OLD.deadline
 THEN RAISE(ABORT,'pdf_rpc_contract_immutable') END;
 SELECT CASE WHEN OLD.rpc_version=2 AND (NEW.rpc_version IS NOT OLD.rpc_version
  OR NEW.rpc_pdf_sha256 IS NOT OLD.rpc_pdf_sha256 OR NEW.rpc_not_after IS NOT OLD.rpc_not_after)
 THEN RAISE(ABORT,'pdf_rpc_contract_immutable') END;
 SELECT CASE WHEN NEW.rpc_version=1 AND (NEW.rpc_pdf_sha256 IS NOT NULL OR NEW.rpc_not_after IS NOT NULL)
 THEN RAISE(ABORT,'pdf_rpc_contract_invalid') END;
 SELECT CASE WHEN OLD.rpc_version=1 AND NEW.rpc_version=2 AND NOT (
  OLD.state='receiving' AND NEW.state='dispatched' AND OLD.ever_dispatched=0 AND NEW.ever_dispatched=1
  AND OLD.token_hash IS NOT NULL AND NEW.token_hash IS OLD.token_hash
  AND typeof(NEW.rpc_not_after)='integer' AND NEW.rpc_not_after=OLD.deadline
  AND NEW.rpc_not_after>0 AND NEW.rpc_not_after<=9007199254560991
  AND typeof(NEW.rpc_pdf_sha256)='text' AND length(NEW.rpc_pdf_sha256)=64
  AND NEW.rpc_pdf_sha256 NOT GLOB '*[^0-9a-f]*'
  AND EXISTS(SELECT 1 FROM rag_pdf_intakes i WHERE i.intake_id=OLD.intake_id
   AND i.account_key=OLD.account_key AND i.document_id=OLD.document_id AND i.generation=OLD.generation
   AND i.state='pending' AND i.pdf_sha256=NEW.rpc_pdf_sha256))
 THEN RAISE(ABORT,'pdf_rpc_contract_invalid') END;
END;
