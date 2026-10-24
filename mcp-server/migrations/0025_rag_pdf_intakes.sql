-- Pre-parse identity only: text sourceHash does not exist yet. No PDF/title/body.
CREATE TABLE rag_pdf_intakes (
 account_key TEXT NOT NULL,
 document_id TEXT NOT NULL,
 intake_id TEXT NOT NULL UNIQUE,
 request_id TEXT NOT NULL,
 generation INTEGER NOT NULL CHECK(generation BETWEEN 1 AND 9007199254740991),
 consent_epoch INTEGER NOT NULL,
 raw_consent_epoch INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','cancelled')),
 pdf_sha256 TEXT,
 byte_length INTEGER,
 expires_at INTEGER NOT NULL,
 PRIMARY KEY(account_key,document_id),
 CHECK((state='cancelled' AND pdf_sha256 IS NULL AND byte_length IS NULL)
    OR (state='pending' AND pdf_sha256 IS NOT NULL AND length(pdf_sha256)=64
        AND byte_length IS NOT NULL AND byte_length BETWEEN 5 AND 10485760))
);
CREATE TRIGGER rag_pdf_intakes_raw_changed AFTER UPDATE OF epoch,enabled,rag_consent_epoch,consent_version ON rag_raw_pdf_consents
WHEN OLD.epoch!=NEW.epoch OR OLD.enabled!=NEW.enabled
 OR OLD.rag_consent_epoch IS NOT NEW.rag_consent_epoch OR OLD.consent_version IS NOT NEW.consent_version BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=NEW.account_key AND state='pending';
END;
CREATE TRIGGER rag_pdf_intakes_raw_deleted AFTER DELETE ON rag_raw_pdf_consents BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=OLD.account_key AND state='pending';
END;

-- New-intake path must never bypass an existing document's lock/deletion state.
CREATE TRIGGER rag_pdf_intakes_document_inserted AFTER INSERT ON rag_documents BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=NEW.account_key AND document_id=NEW.document_id AND state='pending';
END;
CREATE TRIGGER rag_pdf_intakes_document_changed AFTER UPDATE ON rag_documents BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=OLD.account_key AND document_id=OLD.document_id AND state='pending';
END;
CREATE TRIGGER rag_pdf_intakes_document_deleted AFTER DELETE ON rag_documents BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=OLD.account_key AND document_id=OLD.document_id AND state='pending';
END;
CREATE TRIGGER rag_pdf_intakes_account_removed AFTER DELETE ON rag_accounts BEGIN
 UPDATE rag_pdf_intakes SET state='cancelled',pdf_sha256=NULL,byte_length=NULL
 WHERE account_key=OLD.account_key AND state='pending';
END;
