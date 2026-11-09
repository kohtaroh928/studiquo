import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { DOCUMENT_ROOM_SCHEMA, purgeRoomData, removeAccountData, removeParticipantData } from "./document-room-store.ts";
import {
  CHUNK_CHARS, MAX_ASSET_CHARS, MAX_ROOM_ASSET_CHARS, MAX_SNAPSHOT_CHARS,
  ASSET_GRACE_MS, missingAssets, pruneAssets, readAsset, readSnapshot, writeAsset, writeSnapshot,
} from "./document-snapshot-store.ts";
import { partialSql, type Untyped } from "./test-env.ts";

function roomSql() {
  const db = new DatabaseSync(":memory:");
  db.exec(DOCUMENT_ROOM_SCHEMA);
  const sql = {
    exec(query: string, ...params: Untyped[]) {
      const statement = db.prepare(query);
      const returnsRows = /^\s*SELECT/i.test(query) || /RETURNING/i.test(query);
      const rows = returnsRows ? statement.all(...params) : (statement.run(...params), []);
      return { toArray: () => rows, one: () => rows[0] };
    },
  };
  return { db, sql: partialSql(sql) };
}
const count = (db: Untyped, table: string) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const hash = (c: string) => c.repeat(64);

test("a room with no snapshot reads as revision 0 with nothing in it", () => {
  const { sql } = roomSql();
  assert.deepEqual(readSnapshot(sql), { revision: 0, snapshot: null });
});

test("a write must be based on the current revision; a stale writer is refused and nothing changes", () => {
  const { sql } = roomSql();
  assert.deepEqual(writeSnapshot(sql, 0, "v1", "alice", 1), { ok: true, revision: 1 });
  assert.deepEqual(writeSnapshot(sql, 1, "v2", "bob", 2), { ok: true, revision: 2 });
  assert.deepEqual(writeSnapshot(sql, 1, "stale", "alice", 3), { ok: false, reason: "conflict", revision: 2 });
  assert.deepEqual(readSnapshot(sql), { revision: 2, snapshot: "v2" });
  // a writer ahead of the room is also refused (a restored or reset room)
  assert.equal(writeSnapshot(sql, 9, "x", "alice", 4).ok, false);
});

test("reading since the current revision says unchanged and sends no body", () => {
  const { sql } = roomSql();
  writeSnapshot(sql, 0, "v1", "alice", 1);
  assert.deepEqual(readSnapshot(sql, 1), { revision: 1, snapshot: null, unchanged: true });
  assert.equal(readSnapshot(sql, 0).snapshot, "v1");
});

test("a snapshot bigger than one chunk round-trips exactly, and shrinking leaves no old chunks", () => {
  const { db, sql } = roomSql();
  const big = "あ".repeat(CHUNK_CHARS * 2 + 17);
  assert.equal(writeSnapshot(sql, 0, big, "alice", 1).ok, true);
  assert.equal(readSnapshot(sql).snapshot, big);
  assert.equal(count(db, "snapshot_chunks"), 3);
  writeSnapshot(sql, 1, "small", "alice", 2);
  assert.equal(count(db, "snapshot_chunks"), 1);
  assert.equal(readSnapshot(sql).snapshot, "small");
  // an empty snapshot is still a snapshot
  writeSnapshot(sql, 2, "", "alice", 3);
  assert.deepEqual(readSnapshot(sql), { revision: 3, snapshot: "" });
});

test("a snapshot over the limit is refused without touching the stored one", () => {
  const { sql } = roomSql();
  writeSnapshot(sql, 0, "v1", "alice", 1);
  assert.deepEqual(writeSnapshot(sql, 1, "x".repeat(MAX_SNAPSHOT_CHARS + 1), "alice", 2), { ok: false, reason: "too_large", revision: 1 });
  assert.equal(readSnapshot(sql).snapshot, "v1");
});

test("assets are stored by hash, once; large ones are chunked; bad names and sizes are refused", () => {
  const { db, sql } = roomSql();
  const data = "A".repeat(CHUNK_CHARS + 5);
  assert.deepEqual(writeAsset(sql, hash("a"), data), { ok: true, stored: true });
  assert.deepEqual(writeAsset(sql, hash("a"), "other"), { ok: true, stored: false }, "an existing name is not overwritten");
  assert.equal(readAsset(sql, hash("a")), data);
  assert.equal(count(db, "asset_chunks"), 2);
  assert.equal(readAsset(sql, hash("b")), null);
  assert.equal(readAsset(sql, "not-a-hash"), null);
  assert.deepEqual(writeAsset(sql, "xyz", "d"), { ok: false, reason: "bad_hash" });
  assert.deepEqual(writeAsset(sql, hash("c"), "A".repeat(MAX_ASSET_CHARS + 1)), { ok: false, reason: "too_large" });
  assert.deepEqual(missingAssets(sql, [hash("a"), hash("b"), "nope", hash("b")]), [hash("b")]);
});

test("a room cannot hold more image data than the room limit", () => {
  const { sql } = roomSql();
  const piece = "A".repeat(MAX_ASSET_CHARS);
  const fits = Math.floor(MAX_ROOM_ASSET_CHARS / MAX_ASSET_CHARS);
  for (let i = 0; i < fits; i++) assert.equal(writeAsset(sql, String(i).padStart(2, "0").repeat(32), piece).ok, true);
  assert.deepEqual(writeAsset(sql, "ff".repeat(32), "A"), { ok: false, reason: "room_full" });
});

test("purging a room erases the snapshot and the images too", () => {
  const { db, sql } = roomSql();
  sql.exec("INSERT INTO participants (user_key, role) VALUES ('alice', 'owner')");
  writeSnapshot(sql, 0, "秘密の本文", "alice", 1);
  writeAsset(sql, hash("a"), "AAAA");
  purgeRoomData(sql);
  for (const table of ["snapshot_meta", "snapshot_chunks", "assets", "asset_chunks", "participants"]) assert.equal(count(db, table), 0, table);
});

test("removing a member keeps the document but unlinks them as its last author; the last member leaving erases it", () => {
  const { db, sql } = roomSql();
  sql.exec("INSERT INTO participants (user_key, role) VALUES ('alice', 'owner')");
  sql.exec("INSERT INTO participants (user_key, role) VALUES ('bob', 'editor')");
  writeSnapshot(sql, 0, "本文", "bob", 1);
  assert.equal(removeParticipantData(sql, "bob"), "removed");
  assert.equal(db.prepare("SELECT author_key FROM snapshot_meta").get().author_key, "");
  assert.equal(readSnapshot(sql).snapshot, "本文");
  assert.equal(removeParticipantData(sql, "alice"), "purged");
  assert.equal(count(db, "snapshot_chunks"), 0);
});

test("pruning drops images the snapshot no longer names, but not ones uploaded within the grace period", () => {
  const { db, sql } = roomSql();
  writeAsset(sql, hash("a"), "AAAA", 0);                 // old, unnamed -> dropped
  writeAsset(sql, hash("b"), "BBBB", 0);                 // old, named -> kept
  writeAsset(sql, hash("c"), "CCCC", ASSET_GRACE_MS);    // fresh, unnamed -> kept
  assert.equal(pruneAssets(sql, [hash("b")], ASSET_GRACE_MS + 1), 1);
  assert.equal(readAsset(sql, hash("a")), null);
  assert.equal(readAsset(sql, hash("b")), "BBBB");
  assert.equal(readAsset(sql, hash("c")), "CCCC");
  assert.equal(count(db, "asset_chunks"), 2);
  assert.equal(count(db, "asset_times"), 2);
  // an image from before upload times were recorded has no time: it is not protected
  db.prepare("DELETE FROM asset_times WHERE hash = ?").run(hash("c"));
  assert.equal(pruneAssets(sql, [hash("b")], ASSET_GRACE_MS + 2), 1);
  assert.equal(readAsset(sql, hash("c")), null);
});

test("account deletion of the owner erases the snapshot and every image, upload times included", () => {
  const { db, sql } = roomSql();
  sql.exec("INSERT INTO participants (user_key, role) VALUES ('alice', 'owner')");
  writeSnapshot(sql, 0, "本文", "alice", 1);
  writeAsset(sql, hash("a"), "AAAA");
  assert.equal(removeAccountData(sql, "alice"), "purged-owner");
  for (const table of ["snapshot_meta", "snapshot_chunks", "assets", "asset_chunks", "asset_times", "participants"]) assert.equal(count(db, table), 0, table);
});
