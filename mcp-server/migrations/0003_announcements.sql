-- Operator announcements (update notes, maintenance, important notices).
-- The language-independent facts live in `announcements`; every language's
-- title/body is one row in `announcement_translations`, so supporting a new
-- language never needs a schema change — just another row (and one entry in
-- SUPPORTED_LANGUAGES in src/announcements.js for the admin form).
--
-- All timestamps are epoch milliseconds, like the rest of ADMIN_DB.

CREATE TABLE announcements (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,                 -- update | maintenance | important | news
  status TEXT NOT NULL,               -- draft | published | archived
  link TEXT,                          -- optional https URL
  min_app_version TEXT,               -- inclusive; NULL = no lower bound
  max_app_version TEXT,               -- inclusive; NULL = no upper bound
  publish_at INTEGER,                 -- NULL while a draft
  expires_at INTEGER,                 -- NULL = never expires
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_announcements_status_publish ON announcements (status, publish_at);

CREATE TABLE announcement_translations (
  announcement_id TEXT NOT NULL REFERENCES announcements (id) ON DELETE CASCADE,
  lang TEXT NOT NULL,                 -- BCP 47 code: ja, en, zh-Hans, pt-BR, …
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (announcement_id, lang)
);
