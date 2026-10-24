-- Embedding v1: bge-m3 / 1024 dimensions / cosine. Apply before enabling RAG.
CREATE TABLE rag_accounts (account_key TEXT PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE rag_sources (
 account_key TEXT NOT NULL, source_id TEXT NOT NULL, title TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('pdf','notebook')), folder_id TEXT,
 source_hash TEXT NOT NULL, total_pages INTEGER NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
 deleted INTEGER NOT NULL DEFAULT 0, lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(account_key,source_id)
);
CREATE TABLE rag_chunks (
 chunk_id TEXT PRIMARY KEY, account_key TEXT NOT NULL, source_id TEXT NOT NULL,
 page_number INTEGER NOT NULL, ordinal INTEGER NOT NULL, page_hash TEXT NOT NULL,
 chunk_hash TEXT NOT NULL, text TEXT NOT NULL, search_text TEXT NOT NULL,
 ready INTEGER NOT NULL DEFAULT 0, vector_folder TEXT,
 FOREIGN KEY(account_key,source_id) REFERENCES rag_sources(account_key,source_id)
);
CREATE INDEX rag_chunks_scope ON rag_chunks(account_key,source_id,page_number,ready);
CREATE INDEX rag_sources_folder ON rag_sources(account_key,folder_id,deleted);
CREATE VIRTUAL TABLE rag_chunks_fts USING fts5(search_text, content='rag_chunks', content_rowid='rowid', tokenize='unicode61');
CREATE TRIGGER rag_chunks_ai AFTER INSERT ON rag_chunks BEGIN
 INSERT INTO rag_chunks_fts(rowid,search_text) VALUES(new.rowid,new.search_text);
END;
CREATE TRIGGER rag_chunks_ad AFTER DELETE ON rag_chunks BEGIN
 INSERT INTO rag_chunks_fts(rag_chunks_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
END;
CREATE TRIGGER rag_chunks_au AFTER UPDATE OF search_text ON rag_chunks BEGIN
 INSERT INTO rag_chunks_fts(rag_chunks_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
 INSERT INTO rag_chunks_fts(rowid,search_text) VALUES(new.rowid,new.search_text);
END;
CREATE TABLE rag_pages (
 account_key TEXT NOT NULL, source_id TEXT NOT NULL, page_number INTEGER NOT NULL,
 page_hash TEXT NOT NULL, source_hash TEXT NOT NULL,
 PRIMARY KEY(account_key,source_id,page_number)
);
