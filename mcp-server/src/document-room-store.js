// The SQL side of DocumentRoom, kept free of the Durable Object runtime so it
// can be exercised against a plain SQLite database. `sql` is a Durable Object
// SqlStorage: `exec(query, ...bindings)` returning a cursor with `toArray()`.

export const DOCUMENT_ROOM_SCHEMA = `
  CREATE TABLE IF NOT EXISTS participants (
    user_key TEXT PRIMARY KEY,
    role TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS blocks (
    block_order INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    text TEXT NOT NULL DEFAULT '',
    list_kind TEXT,
    list_level INTEGER NOT NULL DEFAULT 0,
    paragraph_style TEXT
  );
  CREATE TABLE IF NOT EXISTS changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    author_key TEXT NOT NULL,
    block_order INTEGER NOT NULL,
    previous_text TEXT NOT NULL,
    new_text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at INTEGER NOT NULL
  );
`;

// Erases the whole room (the document text, every proposal, and the member
// list) and returns the members it had, so the caller can drop their entries
// in the per-account room index. Safe to run again on an emptied room.
export function purgeRoomData(sql) {
  const members = sql.exec("SELECT user_key FROM participants").toArray().map(row => row.user_key);
  sql.exec("DELETE FROM changes");
  sql.exec("DELETE FROM blocks");
  sql.exec("DELETE FROM participants");
  return members;
}

// Takes one member out of the room. Whatever they proposed and nobody has
// decided yet goes with them; text they proposed that was accepted is already
// part of the owner's document and stays. A room left with nobody in it is
// erased. Returns "removed", "purged" (they were the last one), or "absent".
export function removeParticipantData(sql, userKey) {
  const present = sql.exec("SELECT 1 AS present FROM participants WHERE user_key = ?", userKey).toArray().length > 0;
  sql.exec("DELETE FROM changes WHERE author_key = ? AND status = 'pending'", userKey);
  sql.exec("DELETE FROM participants WHERE user_key = ?", userKey);
  const remaining = sql.exec("SELECT COUNT(*) AS count FROM participants").toArray()[0].count;
  if (remaining === 0) {
    purgeRoomData(sql);
    return present ? "purged" : "absent";
  }
  return present ? "removed" : "absent";
}

// `doc-room:<member key>:<room id>` -> the member's role. Lists the rooms an
// account is in, so deleting the account can find them: a room is reachable
// only by its id, and knows its members only by opaque keys.
export function roomMembershipKey(userKey, roomID) {
  return `doc-room:${userKey}:${roomID}`;
}
