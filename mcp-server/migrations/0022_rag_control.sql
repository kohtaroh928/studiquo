-- Durable consent and document tombstones. Never remove controls when disabling RAG.
CREATE TABLE rag_controls (
 account_key TEXT PRIMARY KEY,
 epoch INTEGER NOT NULL CHECK(epoch >= 0),
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 operation_id TEXT NOT NULL
);
CREATE TABLE rag_documents (
 account_key TEXT NOT NULL,
 document_id TEXT NOT NULL,
 source_id TEXT,
 generation INTEGER NOT NULL CHECK(generation >= 0),
 consent_epoch INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('eligible','locked','excluded','trashed','deleted')),
 source_hash TEXT NOT NULL,
 title TEXT NOT NULL,
 folder_id TEXT,
 total_pages INTEGER NOT NULL,
 operation_id TEXT NOT NULL,
 request_id TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(account_key, document_id),
 UNIQUE(account_key, source_id)
);
CREATE TABLE rag_cleanup_jobs (
 account_key TEXT NOT NULL,
 source_id TEXT NOT NULL,
 last_attempt_at INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(account_key,source_id)
);
CREATE INDEX rag_documents_source ON rag_documents(account_key,source_id,state);

-- Compensation journal for writes finishing after a source lease expires.
CREATE TABLE rag_cleanup_vectors (
 account_key TEXT NOT NULL, source_id TEXT NOT NULL, chunk_id TEXT NOT NULL,
 writer_lease TEXT NOT NULL, settled INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(account_key,source_id,chunk_id)
);
