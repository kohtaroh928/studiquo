-- Separate original-PDF consent. Keep tombstones; never store PDF bytes or titles.
CREATE TABLE rag_raw_pdf_consents (
 account_key TEXT PRIMARY KEY,
 epoch INTEGER NOT NULL CHECK(epoch BETWEEN 0 AND 9007199254740991),
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 rag_consent_epoch INTEGER,
 consent_version TEXT,
 CHECK((enabled=0 AND rag_consent_epoch IS NULL AND consent_version IS NULL)
    OR (enabled=1 AND rag_consent_epoch IS NOT NULL AND rag_consent_epoch>=0
        AND consent_version IS NOT NULL AND consent_version='raw-pdf-docling-v1'))
);

-- Old and new callers invalidate in the same transaction as the parent change.
-- Saturating epochs still disable consent; the JS grant path refuses exhaustion.
CREATE TRIGGER rag_raw_pdf_control_changed AFTER UPDATE OF epoch,enabled ON rag_controls
WHEN OLD.epoch != NEW.epoch OR OLD.enabled != NEW.enabled BEGIN
 UPDATE rag_raw_pdf_consents SET enabled=0,rag_consent_epoch=NULL,consent_version=NULL,
  epoch= CASE WHEN epoch<9007199254740991 THEN epoch+1 ELSE epoch END
 WHERE account_key=NEW.account_key;
END;
CREATE TRIGGER rag_raw_pdf_control_deleted AFTER DELETE ON rag_controls BEGIN
 UPDATE rag_raw_pdf_consents SET enabled=0,rag_consent_epoch=NULL,consent_version=NULL,
  epoch= CASE WHEN epoch<9007199254740991 THEN epoch+1 ELSE epoch END
 WHERE account_key=OLD.account_key;
END;
CREATE TRIGGER rag_raw_pdf_account_deleted AFTER UPDATE OF deleted ON rag_accounts
WHEN OLD.deleted=0 AND NEW.deleted!=0 BEGIN
 UPDATE rag_raw_pdf_consents SET enabled=0,rag_consent_epoch=NULL,consent_version=NULL,
  epoch= CASE WHEN epoch<9007199254740991 THEN epoch+1 ELSE epoch END
 WHERE account_key=NEW.account_key;
END;
