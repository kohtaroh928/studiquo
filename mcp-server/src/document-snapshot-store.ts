// The "whole document" side of a shared document room: one snapshot of the
// document (an opaque string the app builds) with a revision number, plus the
// large binary parts (images) kept apart under their SHA-256. Kept free of the
// Durable Object runtime like document-room-store.ts, so it runs against a
// plain SQLite database in tests.
//
// Why chunks: a Durable Object SQLite value is limited to about 2 MB, a
// document is not. Everything is stored in pieces well under that.

export const SNAPSHOT_SCHEMA = `
  CREATE TABLE IF NOT EXISTS snapshot_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL,
    author_key TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    total_chars INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS snapshot_chunks (
    idx INTEGER PRIMARY KEY,
    data TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS assets (
    hash TEXT PRIMARY KEY,
    total_chars INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS asset_times (
    hash TEXT PRIMARY KEY,
    uploaded_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS asset_chunks (
    hash TEXT NOT NULL,
    idx INTEGER NOT NULL,
    data TEXT NOT NULL,
    PRIMARY KEY (hash, idx)
  );
`;

export const CHUNK_CHARS = 500_000;
/** The snapshot text (paragraph text, tables, comments, formatting), without images. */
export const MAX_SNAPSHOT_CHARS = 6_000_000;
/** One image as base64. */
export const MAX_ASSET_CHARS = 6_000_000;
/** All images of one room, as base64. */
export const MAX_ROOM_ASSET_CHARS = 60_000_000;
export const MAX_MISSING_QUERY = 200;
/** An image uploaded this recently is kept even if no snapshot names it yet (its writer is about to). */
export const ASSET_GRACE_MS = 10 * 60 * 1000;
export const HASH_PATTERN = /^[a-f0-9]{64}$/;

const chunks = (text: string) => {
  const out: string[] = [];
  for (let i = 0; i < text.length; i += CHUNK_CHARS) out.push(text.slice(i, i + CHUNK_CHARS));
  return out.length ? out : [""];
};

export function readSnapshot(sql: SqlStorage, sinceRevision = -1) {
  const meta = sql.exec<{ revision: number }>("SELECT revision FROM snapshot_meta WHERE id = 1").toArray()[0];
  if (!meta) return { revision: 0, snapshot: null as string | null };
  if (sinceRevision === meta.revision) return { revision: meta.revision, snapshot: null as string | null, unchanged: true };
  const rows = sql.exec<{ data: string }>("SELECT data FROM snapshot_chunks ORDER BY idx ASC").toArray();
  return { revision: meta.revision, snapshot: rows.map(row => row.data).join("") as string | null };
}

/**
 * Stores `text` as the next revision, but only on top of `baseRevision` (the
 * revision the writer last saw). A writer who is behind gets `ok: false` and the
 * current revision, and has to merge first. Revision 0 means "no snapshot yet".
 */
export function writeSnapshot(sql: SqlStorage, baseRevision: number, text: string, authorKey: string, now: number) {
  if (text.length > MAX_SNAPSHOT_CHARS) return { ok: false as const, reason: "too_large" as const, revision: currentRevision(sql) };
  const revision = currentRevision(sql);
  if (baseRevision !== revision) return { ok: false as const, reason: "conflict" as const, revision };
  sql.exec("DELETE FROM snapshot_chunks");
  chunks(text).forEach((piece, idx) => sql.exec("INSERT INTO snapshot_chunks (idx, data) VALUES (?, ?)", idx, piece));
  sql.exec(
    "INSERT OR REPLACE INTO snapshot_meta (id, revision, author_key, updated_at, total_chars) VALUES (1, ?, ?, ?, ?)",
    revision + 1, authorKey, now, text.length,
  );
  return { ok: true as const, revision: revision + 1 };
}

function currentRevision(sql: SqlStorage) {
  return sql.exec<{ revision: number }>("SELECT revision FROM snapshot_meta WHERE id = 1").toArray()[0]?.revision ?? 0;
}

export function missingAssets(sql: SqlStorage, hashes: string[]) {
  const valid = [...new Set(hashes.filter(hash => HASH_PATTERN.test(hash)))].slice(0, MAX_MISSING_QUERY);
  return valid.filter(hash => sql.exec("SELECT 1 AS present FROM assets WHERE hash = ?", hash).toArray().length === 0);
}

/** Stores an image (base64) under its hash. Already stored: nothing happens. */
export function writeAsset(sql: SqlStorage, hash: string, data: string, now = Date.now()) {
  if (!HASH_PATTERN.test(hash)) return { ok: false as const, reason: "bad_hash" as const };
  if (data.length > MAX_ASSET_CHARS) return { ok: false as const, reason: "too_large" as const };
  if (sql.exec("SELECT 1 AS present FROM assets WHERE hash = ?", hash).toArray().length > 0) return { ok: true as const, stored: false };
  const used = sql.exec<{ total: number | null }>("SELECT SUM(total_chars) AS total FROM assets").toArray()[0]?.total ?? 0;
  if (used + data.length > MAX_ROOM_ASSET_CHARS) return { ok: false as const, reason: "room_full" as const };
  chunks(data).forEach((piece, idx) => sql.exec("INSERT INTO asset_chunks (hash, idx, data) VALUES (?, ?, ?)", hash, idx, piece));
  sql.exec("INSERT INTO assets (hash, total_chars) VALUES (?, ?)", hash, data.length);
  sql.exec("INSERT OR REPLACE INTO asset_times (hash, uploaded_at) VALUES (?, ?)", hash, now);
  return { ok: true as const, stored: true };
}

export function readAsset(sql: SqlStorage, hash: string) {
  if (!HASH_PATTERN.test(hash)) return null;
  if (sql.exec("SELECT 1 AS present FROM assets WHERE hash = ?", hash).toArray().length === 0) return null;
  return sql.exec<{ data: string }>("SELECT data FROM asset_chunks WHERE hash = ? ORDER BY idx ASC", hash).toArray().map(row => row.data).join("");
}

/**
 * Drops images the document no longer uses, so removed pictures do not stay on the
 * server and fill the room. `keep` is what the writer says the new snapshot names;
 * an image uploaded within the grace period is kept (another writer may be about to
 * name it). Returns how many were dropped.
 */
export function pruneAssets(sql: SqlStorage, keep: string[], now = Date.now()) {
  const wanted = new Set(keep);
  const rows = sql.exec<{ hash: string; uploaded_at: number | null }>(
    "SELECT assets.hash AS hash, asset_times.uploaded_at AS uploaded_at FROM assets LEFT JOIN asset_times ON asset_times.hash = assets.hash",
  ).toArray();
  let dropped = 0;
  for (const row of rows) {
    if (wanted.has(row.hash)) continue;
    if (row.uploaded_at !== null && now - row.uploaded_at < ASSET_GRACE_MS) continue;
    sql.exec("DELETE FROM asset_chunks WHERE hash = ?", row.hash);
    sql.exec("DELETE FROM asset_times WHERE hash = ?", row.hash);
    sql.exec("DELETE FROM assets WHERE hash = ?", row.hash);
    dropped++;
  }
  return dropped;
}

/** Erases everything of the document's content kept here (account deletion, room purge). */
export function purgeSnapshotData(sql: SqlStorage) {
  sql.exec("DELETE FROM asset_chunks");
  sql.exec("DELETE FROM asset_times");
  sql.exec("DELETE FROM assets");
  sql.exec("DELETE FROM snapshot_chunks");
  sql.exec("DELETE FROM snapshot_meta");
}

/** A removed member no longer appears as the snapshot's last author. */
export function unlinkSnapshotAuthor(sql: SqlStorage, userKey: string) {
  sql.exec("UPDATE snapshot_meta SET author_key = '' WHERE author_key = ?", userKey);
}
