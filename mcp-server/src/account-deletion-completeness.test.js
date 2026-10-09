import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.js";
import { sha256Hex } from "./auth.js";
import { deleteAccount } from "./account-deletion.js";
import { DOCUMENT_ROOM_SCHEMA, membersIfOwner, purgeRoomData, removeAccountData, removeParticipantData, roomMembershipKey } from "./document-room-store.js";
import { VALIDITY_SECONDS, remainingValiditySeconds } from "./token.js";

// What account deletion must leave nothing of: the synced snapshot kept under a
// session's token, and collaborative document rooms. The room tests run the
// real SQL of the room (document-room-store.js) on an in-memory SQLite; the
// Durable Object wrapper around it is the only part replaced.

// ---------------------------------------------------------------------------
// The room's SQL, on a real database
// ---------------------------------------------------------------------------

function roomSql() {
  const db = new DatabaseSync(":memory:");
  db.exec(DOCUMENT_ROOM_SCHEMA);
  const sql = {
    exec(query, ...params) {
      const statement = db.prepare(query);
      const returnsRows = /^\s*SELECT/i.test(query) || /RETURNING/i.test(query);
      const rows = returnsRows ? statement.all(...params) : (statement.run(...params), []);
      return { toArray: () => rows, one: () => rows[0] };
    },
  };
  return { db, sql };
}

function seedRoom(sql, members, { changes = [] } = {}) {
  for (const [key, role] of members) sql.exec("INSERT INTO participants (user_key, role) VALUES (?, ?)", key, role);
  sql.exec("INSERT INTO blocks (block_order, kind, text) VALUES (0, 'paragraph', '本文')");
  for (const [author, status] of changes) {
    sql.exec(
      "INSERT INTO changes (author_key, block_order, previous_text, new_text, status, created_at) VALUES (?, 0, 'a', 'b', ?, 1)",
      author, status,
    );
  }
}

const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;

test("purging a room erases its text, proposals and members, and reports who was in it", () => {
  const { db, sql } = roomSql();
  seedRoom(sql, [["alice", "owner"], ["bob", "editor"]], { changes: [["bob", "pending"], ["alice", "accepted"]] });

  assert.deepEqual(purgeRoomData(sql).sort(), ["alice", "bob"]);
  for (const table of ["participants", "blocks", "changes"]) assert.equal(count(db, table), 0, `${table} is empty`);
  assert.deepEqual(purgeRoomData(sql), [], "purging an erased room is a no-op");
});

test("removing a member takes what they proposed and did not get accepted, and unlinks what was", () => {
  const { db, sql } = roomSql();
  seedRoom(sql, [["alice", "owner"], ["bob", "editor"]], {
    changes: [["bob", "pending"], ["bob", "rejected"], ["bob", "accepted"], ["alice", "pending"]],
  });

  assert.equal(removeParticipantData(sql, "bob"), "removed");
  assert.deepEqual(db.prepare("SELECT user_key FROM participants").all().map(row => row.user_key), ["alice"]);
  const remaining = db.prepare("SELECT author_key, status, previous_text, new_text FROM changes ORDER BY id").all();
  assert.deepEqual(remaining.map(row => `${row.author_key || "(nobody)"}:${row.status}`), ["(nobody):accepted", "alice:pending"],
    "his open and rejected proposals are gone; the accepted one stays, no longer his");
  assert.equal(remaining[0].previous_text, "", "the text it replaced is not kept");
  assert.equal(remaining[0].new_text, "b", "the accepted text is part of the document");
  assert.equal(count(db, "blocks"), 1, "the document itself stays");
});

test("a room is only erased for its owner, whatever an index says", () => {
  const { db, sql } = roomSql();
  seedRoom(sql, [["alice", "owner"], ["bob", "editor"]], { changes: [["bob", "pending"]] });

  assert.equal(membersIfOwner(sql, "bob"), null, "an editor is not the owner");
  assert.equal(membersIfOwner(sql, "stranger"), null);
  assert.deepEqual(membersIfOwner(sql, "alice").sort(), ["alice", "bob"]);

  // "bob" asking to be removed as if he owned it only removes him.
  assert.equal(removeAccountData(sql, "bob"), "removed");
  assert.equal(count(db, "blocks"), 1, "the owner's document is untouched");
  assert.deepEqual(db.prepare("SELECT user_key FROM participants").all().map(row => row.user_key), ["alice"]);

  assert.equal(removeAccountData(sql, "alice"), "purged-owner");
  for (const table of ["participants", "blocks", "changes"]) assert.equal(count(db, table), 0);
  assert.equal(removeAccountData(sql, "alice"), "absent", "running it again is harmless");
});

test("a room left with nobody in it is erased", () => {
  const { db, sql } = roomSql();
  seedRoom(sql, [["bob", "editor"]], { changes: [["bob", "accepted"]] });

  assert.equal(removeParticipantData(sql, "bob"), "purged");
  for (const table of ["participants", "blocks", "changes"]) assert.equal(count(db, table), 0);
});

test("removing someone who is not in the room changes nothing", () => {
  const { db, sql } = roomSql();
  seedRoom(sql, [["alice", "owner"]], { changes: [["alice", "pending"]] });

  assert.equal(removeParticipantData(sql, "stranger"), "absent");
  assert.equal(count(db, "participants"), 1);
  assert.equal(count(db, "changes"), 1);
  assert.equal(count(db, "blocks"), 1);
});

// ---------------------------------------------------------------------------
// Whole flow: sign-in, share a document, delete an account
// ---------------------------------------------------------------------------

// The bits of DocumentRoom the routes use, over the same SQL the real room runs.
function sqlBackedRooms() {
  const rooms = new Map();
  function room(id) {
    if (!rooms.has(id)) rooms.set(id, roomSql());
    return rooms.get(id);
  }
  return {
    _rooms: rooms,
    getByName(id) {
      const { db, sql } = room(id);
      const requireParticipant = userKey => {
        const rows = sql.exec("SELECT role FROM participants WHERE user_key = ?", userKey).toArray();
        if (rows.length !== 1) throw new Error("Forbidden");
        return rows[0].role;
      };
      return {
        async initialize(ownerKey) {
          if (count(db, "participants") > 0) return { status: "already_initialized" };
          sql.exec("INSERT OR IGNORE INTO participants (user_key, role) VALUES (?, 'owner')", ownerKey);
          sql.exec("INSERT INTO blocks (block_order, kind, text) VALUES (0, 'paragraph', '本文')");
          return { status: "initialized" };
        },
        async invite(ownerKey, userKey, role) {
          if (requireParticipant(ownerKey) !== "owner") throw new Error("Forbidden");
          sql.exec("INSERT OR REPLACE INTO participants (user_key, role) VALUES (?, ?)", userKey, role);
          return { status: "invited" };
        },
        async getState(userKey) {
          requireParticipant(userKey);
          return { blocks: sql.exec("SELECT * FROM blocks").toArray(), pendingChanges: [] };
        },
        async roleOf(userKey) { return sql.exec("SELECT role FROM participants WHERE user_key = ?", userKey).toArray()[0]?.role ?? null; },
        async ownerMembers(userKey) { return membersIfOwner(sql, userKey); },
        async removeAccount(userKey) { return removeAccountData(sql, userKey); },
        // Test helper standing in for the propose route.
        _propose(userKey, text) {
          sql.exec(
            "INSERT INTO changes (author_key, block_order, previous_text, new_text, status, created_at) VALUES (?, 0, '', ?, 'pending', 1)",
            userKey, text,
          );
        },
        _changes() { return db.prepare("SELECT author_key, new_text FROM changes ORDER BY id").all(); },
        _participants() { return db.prepare("SELECT user_key FROM participants").all().map(row => row.user_key).sort(); },
      };
    },
  };
}

// Chat gives each account a key that does not change between sign-ins. Like the
// real registry: settled on first use, and equal to the token-derived key only
// when a chat user already exists under it, otherwise derived from the account.
function fakeRegistry(values) {
  const keys = new Map();
  return {
    getByName(identityHash) {
      return {
        async resolveChatKey(hash, legacyTokenHash) {
          if (!keys.has(hash)) keys.set(hash, values.has(`chat:user:${legacyTokenHash}`) ? legacyTokenHash : hash);
          return keys.get(hash);
        },
      };
    },
  };
}

function environment() {
  const values = new Map();
  const puts = [];
  return {
    STUDIQUO_DATA: {
      async get(key, type) {
        const value = values.get(key) ?? null;
        return type === "json" && value ? JSON.parse(value) : value;
      },
      async put(key, value, options) { puts.push({ key, options }); values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix }) {
        return { keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })), list_complete: true };
      },
    },
    DOCUMENT_ROOM: sqlBackedRooms(),
    USER_REGISTRY: fakeRegistry(values),
    RATE_COUNTER: { getByName() { return { async bump() { return true; } }; } },
    MCP_INBOX: { getByName() { return { async purge() {} }; } },
    _values: values,
    _puts: puts,
  };
}

const noopCtx = { waitUntil() {} };
let nextToken = 1;

// A signed-in session for `sub`: the token the app would hold, and the server
// side session row that makes it real.
async function signIn(env, sub, { ageSeconds = 0 } = {}) {
  const issuedAt = Math.floor(Date.now() / 1000) - ageSeconds;
  const token = `${issuedAt}.${String(nextToken++).padStart(4, "0").repeat(10)}`;
  const tokenHash = await sha256Hex(token);
  env._values.set(`session:${tokenHash}`, JSON.stringify({ sub, issuedAt, issuedAtMs: issuedAt * 1000 }));
  return { token, tokenHash };
}

function call(env, path, { method = "GET", token, body } = {}) {
  const headers = { authorization: `Bearer ${token}` };
  if (body !== undefined) headers["content-type"] = "application/json";
  return worker.fetch(
    new Request(`https://example.test${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }),
    env, noopCtx,
  );
}

const ROOM = "b".repeat(64);
const initRoom = (env, token) => call(env, `/api/document/rooms/${ROOM}/init`, { method: "POST", token, body: { blocks: [] } });
const roomState = (env, token) => call(env, `/api/document/rooms/${ROOM}/state`, { token });

// Gives `sub` a friend code the way chat registration does, under the account's
// stable chat key.
async function registerFriend(env, session, sub, code) {
  const identityHash = await sha256Hex(`chat-account:${sub}`);
  const key = await env.USER_REGISTRY.getByName(identityHash).resolveChatKey(identityHash, session.tokenHash);
  env._values.set(`chat:code:${code}`, key);
  env._values.set(`chat:user:${key}`, JSON.stringify({ key, name: sub, code, friends: [] }));
  return key;
}

async function shareWithBob(env) {
  const alice = await signIn(env, "apple:alice");
  const bob = await signIn(env, "apple:bob");
  assert.equal((await initRoom(env, alice.token)).status, 200);
  const bobKey = await registerFriend(env, bob, "apple:bob", "BOBCODE01");
  const invited = await call(env, `/api/document/rooms/${ROOM}/invite`, { method: "POST", token: alice.token, body: { code: "BOBCODE01", role: "editor" } });
  assert.equal(invited.status, 200);
  return { alice, bob, bobKey };
}

test("the owner can still open their document after signing in again", async () => {
  const env = environment();
  const first = await signIn(env, "apple:alice");
  assert.equal((await initRoom(env, first.token)).status, 200);

  const second = await signIn(env, "apple:alice");
  assert.notEqual(second.token, first.token);
  assert.equal((await roomState(env, second.token)).status, 200, "a new session is the same person");
});

test("an invited friend opens the document with their own session", async () => {
  const env = environment();
  const { bob } = await shareWithBob(env);
  assert.equal((await roomState(env, bob.token)).status, 200);
  const later = await signIn(env, "apple:bob");
  assert.equal((await roomState(env, later.token)).status, 200, "and still after signing in again");
  const stranger = await signIn(env, "apple:carol");
  assert.equal((await roomState(env, stranger.token)).status, 403);
});

test("deleting the owner erases the document and every member's entry for it", async () => {
  const env = environment();
  const { alice, bob, bobKey } = await shareWithBob(env);
  const aliceKey = await registerFriend(env, alice, "apple:alice", "ALICECODE1");
  env.DOCUMENT_ROOM.getByName(ROOM)._propose(bobKey, "bob's idea");
  assert.ok(env._values.has(roomMembershipKey(aliceKey, ROOM)));
  assert.ok(env._values.has(roomMembershipKey(bobKey, ROOM)));

  await deleteAccount(env, "apple:alice");

  const room = env.DOCUMENT_ROOM.getByName(ROOM);
  assert.deepEqual(room._participants(), [], "nobody is left in the room");
  assert.deepEqual(room._changes(), [], "no proposals are left");
  assert.equal((await roomState(env, bob.token)).status, 403, "the friend no longer sees it");
  assert.equal(env._values.has(roomMembershipKey(aliceKey, ROOM)), false);
  assert.equal(env._values.has(roomMembershipKey(bobKey, ROOM)), false, "the friend's index entry goes with the room");
});

test("deleting an invited friend removes them and their open proposals, not the owner's document", async () => {
  const env = environment();
  const { alice, bob, bobKey } = await shareWithBob(env);
  const aliceKey = await registerFriend(env, alice, "apple:alice", "ALICECODE1");
  const room = env.DOCUMENT_ROOM.getByName(ROOM);
  room._propose(bobKey, "bob's idea");
  room._propose(aliceKey, "alice's idea");

  await deleteAccount(env, "apple:bob");

  assert.deepEqual(room._participants(), [aliceKey]);
  assert.deepEqual(room._changes().map(row => row.new_text), ["alice's idea"]);
  assert.equal((await roomState(env, alice.token)).status, 200, "the owner still has the document");
  assert.equal((await roomState(env, bob.token)).status, 401, "the deleted account's own session is gone");
  assert.equal(env._values.has(roomMembershipKey(bobKey, ROOM)), false);
  assert.ok(env._values.has(roomMembershipKey(aliceKey, ROOM)), "the owner's entry stays");
});

test("deletion that failed part-way finishes when it is run again", async () => {
  const env = environment();
  const { alice, bob, bobKey } = await shareWithBob(env);
  const aliceKey = await registerFriend(env, alice, "apple:alice", "ALICECODE1");

  const rooms = env.DOCUMENT_ROOM;
  let fail = true;
  env.DOCUMENT_ROOM = {
    getByName(id) {
      const room = rooms.getByName(id);
      return { ...room, async removeAccount(userKey) { if (fail) throw new Error("storage hiccup"); return room.removeAccount(userKey); } };
    },
  };
  await assert.rejects(() => deleteAccount(env, "apple:alice"), /storage hiccup/);
  assert.ok(env._values.has(roomMembershipKey(aliceKey, ROOM)), "the entry that points at the unfinished room is kept");

  fail = false;
  await deleteAccount(env, "apple:alice");
  assert.deepEqual(rooms.getByName(ROOM)._participants(), []);
  assert.equal(env._values.has(roomMembershipKey(aliceKey, ROOM)), false);
  assert.equal(env._values.has(roomMembershipKey(bobKey, ROOM)), false);
  assert.equal((await roomState(env, bob.token)).status, 403);
});

test("deleting an account that is in no room touches no room", async () => {
  const env = environment();
  const { alice } = await shareWithBob(env);
  await signIn(env, "apple:dave");
  await deleteAccount(env, "apple:dave");
  assert.equal((await roomState(env, alice.token)).status, 200);
});

const initRoomById = (env, token, roomID) =>
  call(env, `/api/document/rooms/${roomID}/init`, { method: "POST", token, body: { blocks: [] } });
const roomIdNumber = n => n.toString(16).padStart(64, "0");

async function stableKey(env, sub, tokenHash) {
  const identityHash = await sha256Hex(`chat-account:${sub}`);
  return env.USER_REGISTRY.getByName(identityHash).resolveChatKey(identityHash, tokenHash);
}

test("an index entry that is out of date never costs another person their document", async () => {
  const env = environment();
  const carol = await signIn(env, "apple:carol");
  assert.equal((await initRoom(env, carol.token)).status, 200);
  const alice = await signIn(env, "apple:alice");
  const aliceKey = await stableKey(env, "apple:alice", alice.tokenHash);

  // Alice's index says she owns the room, but the room is Carol's (for instance
  // the room was erased and the same id was created again by someone else).
  env._values.set(roomMembershipKey(aliceKey, ROOM), "owner");

  await deleteAccount(env, "apple:alice");

  assert.equal((await roomState(env, carol.token)).status, 200, "Carol's document is untouched");
  assert.equal(env._values.has(roomMembershipKey(aliceKey, ROOM)), false, "the stale entry is cleaned up");
});

test("a room whose index write failed at creation is still found when the client retries", async () => {
  const env = environment();
  const alice = await signIn(env, "apple:alice");
  const aliceKey = await stableKey(env, "apple:alice", alice.tokenHash);

  const put = env.STUDIQUO_DATA.put;
  let failOnce = true;
  env.STUDIQUO_DATA.put = async (key, value, options) => {
    if (failOnce && key.startsWith("doc-room:")) { failOnce = false; throw new Error("kv unavailable"); }
    return put(key, value, options);
  };

  assert.notEqual((await initRoom(env, alice.token)).status, 200, "the first attempt fails after the room exists");
  assert.equal(env._values.has(roomMembershipKey(aliceKey, ROOM)), false);

  const retry = await initRoom(env, alice.token);
  assert.equal(retry.status, 200);
  assert.deepEqual(await retry.json(), { status: "already_initialized" });
  assert.equal(env._values.get(roomMembershipKey(aliceKey, ROOM)), "owner", "recorded now, because the room says she owns it");

  await deleteAccount(env, "apple:alice");
  assert.deepEqual(env.DOCUMENT_ROOM.getByName(ROOM)._participants(), [], "so deleting her account erases the room");
});

test("someone who is not the owner cannot get an index entry by retrying init", async () => {
  const env = environment();
  const alice = await signIn(env, "apple:alice");
  await initRoom(env, alice.token);
  const mallory = await signIn(env, "apple:mallory");
  const malloryKey = await stableKey(env, "apple:mallory", mallory.tokenHash);

  const response = await initRoom(env, mallory.token);
  assert.deepEqual(await response.json(), { status: "already_initialized" });
  assert.equal(env._values.has(roomMembershipKey(malloryKey, ROOM)), false);
});

test("the other members' entries are dropped before the room is erased, so no repeat can lose them", async () => {
  const env = environment();
  const { alice, bobKey } = await shareWithBob(env);
  const aliceKey = await stableKey(env, "apple:alice", alice.tokenHash);

  const rooms = env.DOCUMENT_ROOM;
  let fail = true;
  env.DOCUMENT_ROOM = {
    getByName(id) {
      const room = rooms.getByName(id);
      return { ...room, async removeAccount(userKey) { if (fail) throw new Error("cut short"); return room.removeAccount(userKey); } };
    },
  };
  await assert.rejects(() => deleteAccount(env, "apple:alice"), /cut short/);
  assert.equal(env._values.has(roomMembershipKey(bobKey, ROOM)), false, "already dropped, while the room could still be asked");
  assert.ok(env._values.has(roomMembershipKey(aliceKey, ROOM)), "the owner's own entry is what a repeat starts from");

  fail = false;
  await deleteAccount(env, "apple:alice");
  assert.deepEqual(rooms.getByName(ROOM)._participants(), []);
  assert.equal(env._values.has(roomMembershipKey(aliceKey, ROOM)), false);
});

test("one room that cannot be removed does not stop the others", async () => {
  const env = environment();
  const alice = await signIn(env, "apple:alice");
  const aliceKey = await stableKey(env, "apple:alice", alice.tokenHash);
  for (const n of [1, 2, 3]) assert.equal((await initRoomById(env, alice.token, roomIdNumber(n))).status, 200);

  const rooms = env.DOCUMENT_ROOM;
  let broken = true;
  env.DOCUMENT_ROOM = {
    getByName(id) {
      const room = rooms.getByName(id);
      if (id !== roomIdNumber(2)) return room;
      return { ...room, async removeAccount(userKey) { if (broken) throw new Error("this room is stuck"); return room.removeAccount(userKey); } };
    },
  };
  await assert.rejects(() => deleteAccount(env, "apple:alice"), /this room is stuck/);
  assert.deepEqual(rooms.getByName(roomIdNumber(1))._participants(), [], "room 1 is gone");
  assert.deepEqual(rooms.getByName(roomIdNumber(3))._participants(), [], "room 3 is gone");
  assert.deepEqual(rooms.getByName(roomIdNumber(2))._participants(), [aliceKey], "room 2 is left for the retry");

  broken = false;
  await deleteAccount(env, "apple:alice");
  assert.deepEqual(rooms.getByName(roomIdNumber(2))._participants(), []);
  assert.deepEqual([...env._values.keys()].filter(key => key.startsWith("doc-room:")), []);
});

test("an account in very many rooms is finished by repeating, and the rest of the data goes first", async () => {
  const env = environment();
  const alice = await signIn(env, "apple:alice");
  const aliceKey = await stableKey(env, "apple:alice", alice.tokenHash);
  env._values.set(`chat:user:${aliceKey}`, JSON.stringify({ key: aliceKey, name: "alice", code: "A", friends: [] }));
  const total = 45;
  for (let n = 1; n <= total; n++) assert.equal((await initRoomById(env, alice.token, roomIdNumber(n))).status, 200);

  await assert.rejects(() => deleteAccount(env, "apple:alice"), /More document rooms remain/);
  assert.equal(env._values.has(`chat:user:${aliceKey}`), false, "everything but the rooms is already deleted");
  const left = [...env._values.keys()].filter(key => key.startsWith("doc-room:")).length;
  assert.equal(left, total - 40, "one run removes at most 40 rooms");

  await deleteAccount(env, "apple:alice");
  assert.deepEqual([...env._values.keys()].filter(key => key.startsWith("doc-room:")), []);
  for (let n = 1; n <= total; n++) assert.deepEqual(env.DOCUMENT_ROOM.getByName(roomIdNumber(n))._participants(), []);
});

// ---------------------------------------------------------------------------
// The synced snapshot expires with its session
// ---------------------------------------------------------------------------

const DAY = 86_400;
const snapshotBody = { version: 1, exportedAt: "2026-10-09T00:00:00Z", notebooks: [] };

test("a token's remaining validity is what is left of its 90 days, never less than a minute", () => {
  const now = 1_800_000_000_000;
  const mint = secondsAgo => `${Math.floor(now / 1000) - secondsAgo}.secret`;
  assert.equal(remainingValiditySeconds(mint(0), now), VALIDITY_SECONDS);
  assert.equal(remainingValiditySeconds(mint(89 * DAY), now), DAY);
  assert.equal(remainingValiditySeconds(mint(VALIDITY_SECONDS + 5 * DAY), now), 60, "expired: the smallest expiry KV accepts");
  assert.equal(remainingValiditySeconds("no-dot", now), 60);
  assert.equal(remainingValiditySeconds("abc.secret", now), 60);
  assert.equal(remainingValiditySeconds(`${Math.floor(now / 1000) + 30 * DAY}.secret`, now), VALIDITY_SECONDS, "a clock running ahead cannot extend it");
});

test("the snapshot kept under a session expires with that session; the account copy does not", async () => {
  const env = environment();
  const session = await signIn(env, "apple:alice", { ageSeconds: 80 * DAY });

  const response = await call(env, "/api/snapshot", { method: "PUT", token: session.token, body: snapshotBody });
  assert.equal(response.status, 200);

  const tokenCopy = env._puts.find(put => put.key === `snapshot:${session.tokenHash}`);
  assert.ok(tokenCopy.options?.expirationTtl, "an expiry is set");
  assert.ok(Math.abs(tokenCopy.options.expirationTtl - 10 * DAY) < 120, `about 10 days left, got ${tokenCopy.options.expirationTtl}`);

  const accountKey = await sha256Hex("mcp-account:apple:alice");
  const accountCopy = env._puts.find(put => put.key === `snapshot:${accountKey}`);
  assert.ok(accountCopy, "the account-level copy is written");
  assert.equal(accountCopy.options, undefined, "and lives until the account is deleted");
});
