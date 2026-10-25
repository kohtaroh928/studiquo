-- Optional untrusted Docling provenance. Never used as account authorization.
-- Legacy rows remain readable without metadata; no existing content is rewritten.
ALTER TABLE rag_chunks ADD COLUMN metadata_json TEXT;
