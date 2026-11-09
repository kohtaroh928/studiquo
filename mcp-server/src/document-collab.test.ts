import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import worker from "./app.ts";
import { DOCUMENT_ROOM_SCHEMA } from "./document-room-store.ts";
import { missingAssets, pruneAssets, readAsset, readSnapshot, writeAsset, writeSnapshot } from "./document-snapshot-store.ts";
import { sha256Hex } from "./auth.ts";
import { partialCtx, partialEnv, partialSql, type LooseEnv, type Untyped } from "./test-env.ts";

// Stands in for the real DocumentRoom Durable Object (document-room.ts): one
// shared participants/blocks/changes record per room id, persisting across
// separate getByName(id) calls the way a real Durable Object instance would.
function snapshotSql(state: Untyped) {
  if (!state.sql) {
    const db = new DatabaseSync(":memory:");
    db.exec(DOCUMENT_ROOM_SCHEMA);
    state.sql = partialSql({
      exec(query: string, ...params: Untyped[]) {
        const statement = db.prepare(query);
        const rows = /^\s*SELECT/i.test(query) ? statement.all(...params) : (statement.run(...params), []);
        return { toArray: () => rows, one: () => rows[0] };
      },
    });
  }
  return state.sql;
}

function fakeDocumentRoomBinding() {
  const rooms = new Map();
  function room(id: string) {
    if (!rooms.has(id)) rooms.set(id, { participants: new Map(), blocks: new Map(), changes: [], nextChangeID: 1 });
    return rooms.get(id);
  }
  function requireParticipant(state: { participants: { get: (arg0: any) => any; }; }, userKey: string) {
    const role = state.participants.get(userKey);
    if (!role) throw new Error("Forbidden");
    return role;
  }
  function requireReviewer(state: { participants: { get: (arg0: any) => any; }; }, userKey: string) {
    const role = requireParticipant(state, userKey);
    if (role !== "owner" && role !== "reviewer") throw new Error("Forbidden");
  }
  return {
    getByName(id: string) {
      const state = room(id);
      return {
        async initialize(ownerKey: string, blocks: unknown) {
          if (state.participants.size > 0) return { status: "already_initialized" };
          state.participants.set(ownerKey, "owner");
          for (const block of (Array.isArray(blocks) ? blocks : []).slice(0, 2000)) {
            state.blocks.set(Number(block.order) || 0, {
              order: Number(block.order) || 0,
              kind: String(block.kind ?? "paragraph"),
              text: String(block.text ?? ""),
              listKind: block.listKind ?? null,
              listLevel: Number(block.listLevel) || 0,
              paragraphStyle: block.paragraphStyle ?? null,
            });
          }
          return { status: "initialized" };
        },
        async invite(ownerKey: string, userKey: string, role: string) {
          const ownerRole = requireParticipant(state, ownerKey);
          if (ownerRole !== "owner") throw new Error("Forbidden");
          if (role !== "editor" && role !== "reviewer") throw new Error("InvalidRole");
          if (userKey === ownerKey) throw new Error("InvalidRole");
          state.participants.set(userKey, role);
          return { status: "invited" };
        },
        async roleOf(userKey: string) {
          return state.participants.get(userKey) ?? null;
        },
        async removeAccount(userKey: string) {
          state.participants.delete(userKey);
          return "removed";
        },
        // Mirrors document-room.ts's removeMember / leave.
        async removeMember(ownerKey: string, userKey: string) {
          if (requireParticipant(state, ownerKey) !== "owner") throw new Error("Forbidden");
          if (userKey === ownerKey) throw new Error("OwnerCannotLeave");
          if (!state.participants.has(userKey)) return { status: "not_found" };
          state.participants.delete(userKey);
          state.changes = state.changes.filter((change: Untyped) => !(change.authorKey === userKey && change.status !== "accepted"));
          return { status: "removed" };
        },
        async leave(userKey: string) {
          if (requireParticipant(state, userKey) === "owner") throw new Error("OwnerCannotLeave");
          state.participants.delete(userKey);
          state.changes = state.changes.filter((change: Untyped) => !(change.authorKey === userKey && change.status !== "accepted"));
          return { status: "left" };
        },
        async listParticipants(userKey: string) {
          requireParticipant(state, userKey);
          return Array.from(state.participants, ([key, role]) => ({ userKey: key, role }));
        },
        async getState(userKey: string) {
          requireParticipant(state, userKey);
          return {
            blocks: Array.from(state.blocks.values()).sort((a, b) => (a as { order: number }).order - (b as { order: number }).order),
            pendingChanges: state.changes.filter((change: Untyped) => change.status === "pending"),
          };
        },
        async proposeChange(userKey: string, blockOrder: string, previousText: string, newText: string) {
          const role = requireParticipant(state, userKey);
          if (role !== "owner" && role !== "editor") throw new Error("Forbidden");
          const change = {
            id: state.nextChangeID++,
            authorKey: userKey,
            blockOrder,
            previousText,
            newText,
            status: "pending",
            createdAt: Date.now(),
          };
          state.changes.push(change);
          return { id: change.id, status: "pending" };
        },
        // The snapshot methods run the real storage code (document-snapshot-store.ts)
        // on an in-memory SQLite; only the role checks repeat document-room.ts.
        async getSnapshot(userKey: string, sinceRevision: number) {
          requireParticipant(state, userKey);
          return readSnapshot(snapshotSql(state), sinceRevision);
        },
        async putSnapshot(userKey: string, baseRevision: number, text: string, assetHashes?: string[]) {
          const role = requireParticipant(state, userKey);
          if (role !== "owner" && role !== "editor") throw new Error("Forbidden");
          if (readSnapshot(snapshotSql(state), -1).revision === 0 && role !== "owner") return { ok: false, reason: "not_ready", revision: 0 };
          const result = writeSnapshot(snapshotSql(state), baseRevision, text, userKey, Date.now());
          if (result.ok && Array.isArray(assetHashes)) pruneAssets(snapshotSql(state), assetHashes);
          return result;
        },
        async missingAssets(userKey: string, hashes: string[]) {
          requireParticipant(state, userKey);
          return { missing: missingAssets(snapshotSql(state), hashes) };
        },
        async putAsset(userKey: string, hash: string, data: string) {
          const role = requireParticipant(state, userKey);
          if (role !== "owner" && role !== "editor") throw new Error("Forbidden");
          return writeAsset(snapshotSql(state), hash, data);
        },
        async getAsset(userKey: string, hash: string) {
          requireParticipant(state, userKey);
          const data = readAsset(snapshotSql(state), hash);
          return data === null ? { found: false } : { found: true, data };
        },
        async reviewChange(userKey: string, changeID: string, decision: string) {
          requireReviewer(state, userKey);
          if (decision !== "accept" && decision !== "reject") throw new Error("InvalidDecision");
          const change = state.changes.find((item: Untyped) => item.id === changeID);
          if (!change) return { status: "not_found" };
          if (change.status !== "pending") return { status: change.status };
          if (decision === "accept") {
            const block = state.blocks.get(change.blockOrder);
            if (block) block.text = change.newText;
          }
          change.status = decision === "accept" ? "accepted" : "rejected";
          return { status: change.status };
        },
      };
    },
  };
}

// Stands in for the real RateCounter Durable Object (rate-counter.ts): a
// plain in-memory count per name, ignoring windowSeconds entirely since no
// test here spans a real window boundary.
function fakeRateCounterBinding() {
  const counts = new Map();
  return {
    getByName(name: string) {
      return {
        async bump(limit: number) {
          const used = (counts.get(name) ?? 0) + 1;
          if (used > limit) return false;
          counts.set(name, used);
          return true;
        },
      };
    },
  };
}

function environment() {
  const values = new Map();
  const studiquoData = {
    async get(key: string, type: string) {
      await new Promise(resolve => setImmediate(resolve));
      let value = values.get(key) ?? null;
      // These tests aren't exercising session-authenticity enforcement
      // itself — treat any well-formed bearer token as if it came from a
      // real sign-in, mirroring chat.test.js's own environment() helper.
      if (value === null && key.startsWith("session:")) {
        value = JSON.stringify({ sub: "test", issuedAt: Math.floor(Date.now() / 1000) });
      }
      return type === "json" && value ? JSON.parse(value) : value;
    },
    async put(key: string, value: string) { values.set(key, value); },
    async delete(key: string) { values.delete(key); },
    async list({ prefix }: { prefix?: unknown }) {
      return { keys: [...values.keys()].filter(name => name.startsWith(prefix)).map(name => ({ name })), list_complete: true };
    },
  };
  return partialEnv({
    STUDIQUO_DATA: studiquoData,
    DOCUMENT_ROOM: fakeDocumentRoomBinding(),
    RATE_COUNTER: fakeRateCounterBinding(),
    CHAT_ROOM: fakeChatRoomBinding(),
  });
}

// Stands in for ChatRoom's blockStatus (chat-room.ts): nothing is blocked
// unless a test lists the room id.
function fakeChatRoomBinding(blockedRooms = new Set()) {
  return {
    getByName(id: unknown) {
      return { async blockStatus() { return { blockedByMe: blockedRooms.has(id), blockedByOther: false }; } };
    },
  };
}

const noopCtx = partialCtx({ waitUntil() {} });

function freshToken(suffix: string) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;
}

function request(path: string, { method = "GET", token, body }: { method?: string; token?: string; body?: unknown } = {}) {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  return new Request(`https://example.test${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

const ROOM_ID = "a".repeat(64);

function initRoom(env: LooseEnv, token: string, blocks: { order: number; kind: string; text: string; }[]) {
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/init`, { method: "POST", token, body: { blocks } }),
    env,
    noopCtx
  );
}

let nextTestCode = 1;

// Seeds the same chat:user:/chat:code: KV records chat.ts's registerUser()
// would create for a real account, so invite() below can resolve a friend
// code to a userKey exactly the way the live handler does. Returns the
// minted code.
async function registerFriend(env: LooseEnv, token: string, name: string, { befriendedBy }: { befriendedBy?: string } = {}) {
  const userKey = await sha256Hex(token);
  const code = `TESTCODE${String(nextTestCode++).padStart(4, "0")}`;
  await env.STUDIQUO_DATA.put(`chat:user:${userKey}`, JSON.stringify({ key: userKey, name, code, friends: [] }));
  await env.STUDIQUO_DATA.put(`chat:code:${code}`, userKey);
  if (befriendedBy) await befriend(env, befriendedBy, { code, name, roomID: `room-${code}` });
  return code;
}

// Adds `friend` to the friends list of the account that owns `token`, creating
// that account's record first if it has none.
async function befriend(env: LooseEnv, token: string, friend: { code: string; name: any; roomID: string; }) {
  const userKey = await sha256Hex(token);
  const existing = await env.STUDIQUO_DATA.get(`chat:user:${userKey}`, "json")
    ?? { key: userKey, name: "owner", code: `OWNER${userKey.slice(0, 6).toUpperCase()}`, friends: [] };
  existing.friends = [...(existing.friends ?? []), friend];
  await env.STUDIQUO_DATA.put(`chat:user:${userKey}`, JSON.stringify(existing));
}

// `inviteeToken` is the token belonging to the person being invited — the
// route resolves their friend code to a userKey server-side (the same way
// chat.ts resolves one when adding a friend), so this registers them first.
async function sendInvite(env: LooseEnv, ownerToken: string, inviteeToken: string, role: string, { name = "友人" }: { name?: string } = {}) {
  const code = await registerFriend(env, inviteeToken, name, { befriendedBy: ownerToken });
  // Friendship is mutual: the invitee has the owner in their own list too,
  // sharing the direct room's id (which is what a block is looked up by).
  const ownerRecord = await env.STUDIQUO_DATA.get(`chat:user:${await sha256Hex(ownerToken)}`, "json");
  await befriend(env, inviteeToken, { code: ownerRecord.code, name: "owner", roomID: `room-${code}` });
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: ownerToken, body: { code, role } }),
    env,
    noopCtx
  );
}

// An invitation only seats the person once they accept it. Most tests are about
// what a participant can do, so this sends the invitation and has the invitee
// accept it; the response is the invitation's, as before.
async function invite(env: LooseEnv, ownerToken: string, inviteeToken: string, role: string, options?: { name?: string; } | undefined) {
  const response = await sendInvite(env, ownerToken, inviteeToken, role, options);
  if (response.status === 200) {
    const accepted = await worker.fetch(
      request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: inviteeToken, body: {} }),
      env, noopCtx
    );
    assert.equal(accepted.status, 200, "the invitee can accept");
  }
  return response;
}

function getState(env: LooseEnv, token: string) {
  return worker.fetch(request(`/api/document/rooms/${ROOM_ID}/state`, { token }), env, noopCtx);
}

function propose(env: LooseEnv, token: string, blockOrder: number, previousText: string, newText: string) {
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/propose`, { method: "POST", token, body: { blockOrder, previousText, newText } }),
    env,
    noopCtx
  );
}

function review(env: LooseEnv, token: string, changeID: number, decision: string) {
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/changes/${changeID}/review`, { method: "POST", token, body: { decision } }),
    env,
    noopCtx
  );
}

test("owner initializes a room with a block snapshot", async () => {
  const env = environment();
  const owner = freshToken("1");
  const response = await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "はじめに" }]);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "initialized" });
});

test("re-initializing an already-initialized room is a no-op", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "one" }]);
  const response = await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "two" }]);
  assert.deepEqual(await response.json(), { status: "already_initialized" });
  const state = await (await getState(env, owner)).json();
  assert.equal(state.blocks[0].text, "one");
});

test("owner invites an editor and a reviewer, who can then read state", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "はじめに" }]);

  assert.equal((await invite(env, owner, editor, "editor")).status, 200);
  assert.equal((await invite(env, owner, reviewer, "reviewer")).status, 200);

  const state = await getState(env, editor);
  assert.equal(state.status, 200);
  const body = await state.json();
  assert.equal(body.blocks.length, 1);
  assert.equal(body.blocks[0].text, "はじめに");
});

test("a non-owner cannot invite", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  const outsider = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor");

  const response = await invite(env, editor, outsider, "editor");
  assert.equal(response.status, 403);
});

test("inviting with an invalid role is rejected", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await invite(env, owner, freshToken("2"), "owner");
  assert.equal(response.status, 400);
});

test("someone never invited cannot read room state", async () => {
  const env = environment();
  const owner = freshToken("1");
  const stranger = freshToken("9");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await getState(env, stranger);
  assert.equal(response.status, 403);
});

test("editor proposes a change, reviewer accepts it, and the block text updates", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "はじめに" }]);
  await invite(env, owner, editor, "editor");
  await invite(env, owner, reviewer, "reviewer");

  const proposeResponse = await propose(env, editor, 0, "はじめに", "はじめに(改訂)");
  assert.equal(proposeResponse.status, 200);
  const { id: changeID } = await proposeResponse.json();

  const pending = await (await getState(env, reviewer)).json();
  assert.equal(pending.pendingChanges.length, 1);
  assert.equal(pending.pendingChanges[0].newText, "はじめに(改訂)");

  const reviewResponse = await review(env, reviewer, changeID, "accept");
  assert.equal(reviewResponse.status, 200);
  assert.deepEqual(await reviewResponse.json(), { status: "accepted" });

  const state = await (await getState(env, owner)).json();
  assert.equal(state.blocks[0].text, "はじめに(改訂)");
  assert.equal(state.pendingChanges.length, 0);
});

test("rejecting a proposed change leaves the block text untouched", async () => {
  const env = environment();
  const owner = freshToken("1");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "はじめに" }]);
  await invite(env, owner, reviewer, "reviewer");

  const { id: changeID } = await (await propose(env, owner, 0, "はじめに", "変更案")).json();
  const reviewResponse = await review(env, reviewer, changeID, "reject");
  assert.deepEqual(await reviewResponse.json(), { status: "rejected" });

  const state = await (await getState(env, owner)).json();
  assert.equal(state.blocks[0].text, "はじめに");
});

test("an editor-only participant (not owner or reviewer) cannot review a change", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor");

  const { id: changeID } = await (await propose(env, editor, 0, "x", "y")).json();
  const response = await review(env, editor, changeID, "accept");
  assert.equal(response.status, 403);
});

test("a reviewer-only participant (not owner or editor) cannot propose a change", async () => {
  const env = environment();
  const owner = freshToken("1");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, reviewer, "reviewer");

  const response = await propose(env, reviewer, 0, "x", "y");
  assert.equal(response.status, 403);
});

test("reviewing an already-resolved change returns its existing status instead of erroring", async () => {
  const env = environment();
  const owner = freshToken("1");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, reviewer, "reviewer");
  const { id: changeID } = await (await propose(env, owner, 0, "x", "y")).json();

  await review(env, reviewer, changeID, "accept");
  const second = await review(env, reviewer, changeID, "accept");
  assert.deepEqual(await second.json(), { status: "accepted" });
});

test("reviewing a nonexistent change returns 404", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await review(env, owner, 999, "accept");
  assert.equal(response.status, 404);
});

test("an invalid decision is rejected", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const { id: changeID } = await (await propose(env, owner, 0, "x", "y")).json();
  const response = await review(env, owner, changeID, "maybe");
  assert.equal(response.status, 400);
});

test("proposing with a non-integer blockOrder is rejected", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/propose`, {
      method: "POST",
      token: owner,
      body: { blockOrder: "not-a-number", previousText: "x", newText: "y" },
    }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("proposing more than the per-minute limit is rate limited", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);

  let lastStatus = 200;
  for (let i = 0; i < 31; i += 1) {
    const response = await propose(env, owner, 0, "x", `y${i}`);
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

test("inviting more than the per-minute limit is rate limited", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);

  let lastStatus = 200;
  for (let i = 0; i < 6; i += 1) {
    const response = await invite(env, owner, freshToken("abcdef"[i]), "editor");
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

test("owner can list participants with their roles and display names", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor", { name: "田中" });

  const response = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/participants`, { token: owner }), env, noopCtx);
  assert.equal(response.status, 200);
  const participants = await response.json();
  assert.equal(participants.length, 2);
  assert.ok(participants.some((entry: Untyped) => entry.userKey && entry.role === "owner"));
  assert.ok(participants.some((entry: Untyped) => entry.role === "editor" && entry.name === "田中"));
});

test("inviting with a code no one is registered under is refused like any non-friend", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code: "NOSUCHCODE1", role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("a friend whose account has gone is a 404", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await befriend(env, owner, { code: "GONEFRIEND", name: "消えた人", roomID: "room-gone" });
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code: "GONEFRIEND", role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
});

test("someone who is not a friend cannot be invited, even with a valid code", async () => {
  const env = environment();
  const owner = freshToken("1");
  const stranger = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, stranger, "他人");
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(stranger)), null);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-room:${await sha256Hex(stranger)}:${ROOM_ID}`), null);
});

test("a friend the owner has blocked cannot be invited", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, friend, "友人", { befriendedBy: owner });
  env.CHAT_ROOM = fakeChatRoomBinding(new Set([`room-${code}`]));
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 403);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
});

test("creating more rooms than the hourly limit is rate limited", async () => {
  const env = environment();
  const owner = freshToken("1");
  let lastStatus = 200;
  for (let i = 0; i < 21; i += 1) {
    const response = await worker.fetch(
      request(`/api/document/rooms/${String(i).padStart(64, "0")}/init`, { method: "POST", token: owner, body: { blocks: [] } }),
      env,
      noopCtx
    );
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

test("inviting with a malformed code is rejected", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code: "!!!", role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 400);
});

test("a request outside /api/document/ is not handled by this router", async () => {
  const env = environment();
  const response = await worker.fetch(request("/health"), env, noopCtx);
  assert.equal(response.status, 200);
});

test("an invitee whose account is deleted while the invite is being made is left with no invitation", async () => {
  const env = environment();
  const owner = freshToken("1");
  const invitee = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, invitee, "友人", { befriendedBy: owner });
  const inviteeKey = await sha256Hex(invitee);
  // The deletion lands after the code was resolved and the invitation was written.
  const put = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (name: string, value: string, options: string) => {
    const result = await put.call(env.STUDIQUO_DATA, name, value, options);
    if (name.startsWith("doc-invite:")) await env.STUDIQUO_DATA.delete(`chat:user:${inviteeKey}`);
    return result;
  };
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-invite:${inviteeKey}:${ROOM_ID}`), null);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(inviteeKey), null);
});

test("an invitation does not seat anyone until it is accepted", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const sent = await sendInvite(env, owner, friend, "editor");
  assert.equal(sent.status, 200);
  assert.equal((await sent.json()).status, "pending");
  assert.equal((await getState(env, friend)).status, 403, "not a participant yet");
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-room:${await sha256Hex(friend)}:${ROOM_ID}`), null);

  const waiting = await (await worker.fetch(request("/api/document/invites", { token: friend }), env, noopCtx)).json();
  assert.deepEqual(waiting.map((item: Untyped) => [item.roomID, item.role]), [[ROOM_ID, "editor"]]);

  const accepted = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal((await accepted.json()).status, "joined");
  assert.equal((await getState(env, friend)).status, 200);
  assert.deepEqual(await (await worker.fetch(request("/api/document/invites", { token: friend }), env, noopCtx)).json(), []);
  assert.notEqual(await env.STUDIQUO_DATA.get(`doc-room:${await sha256Hex(friend)}:${ROOM_ID}`), null);
});

test("declining an invitation removes it and seats no one", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await sendInvite(env, owner, friend, "reviewer");
  const declined = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/decline`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal((await declined.json()).status, "declined");
  assert.equal((await getState(env, friend)).status, 403);
  const again = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(again.status, 404, "nothing left to accept");
});

test("nobody can accept an invitation that was not made for them", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  const stranger = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await sendInvite(env, owner, friend, "editor");
  const response = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: stranger, body: {} }), env, noopCtx);
  assert.equal(response.status, 404);
  assert.equal((await getState(env, stranger)).status, 403);
});

test("an invitation from someone who is no longer the room's owner is void", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await sendInvite(env, owner, friend, "editor");
  await env.DOCUMENT_ROOM.getByName(ROOM_ID).removeAccount(await sha256Hex(owner));
  const response = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(response.status, 410);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-invite:${await sha256Hex(friend)}:${ROOM_ID}`), null, "and it is cleared");
});

test("one person can hold only so many invitations at once", async () => {
  const env = environment();
  const friend = freshToken("2");
  const friendKey = await sha256Hex(friend);
  for (let i = 0; i < 20; i++) await env.STUDIQUO_DATA.put(`doc-invite:${friendKey}:${String(i).padStart(64, "0")}`, JSON.stringify({ inviterKey: "x", role: "editor", createdAt: i }));
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await sendInvite(env, owner, friend, "editor");
  assert.equal(response.status, 429);
});

test("an invitation lapses after two weeks", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const ttls: unknown[] = [];
  const put = env.STUDIQUO_DATA.put;
  env.STUDIQUO_DATA.put = async (name: string, value: string, options: { expirationTtl: any; }) => { if (name.startsWith("doc-invite:")) ttls.push(options?.expirationTtl); return put.call(env.STUDIQUO_DATA, name, value, options); };
  await sendInvite(env, owner, friend, "editor");
  assert.deepEqual(ttls, [14 * 24 * 3600]);
});

// MARK: Removing members and leaving

function removeMember(env: LooseEnv, token: string, memberKey: string) {
  return worker.fetch(request(`/api/document/rooms/${ROOM_ID}/participants/${memberKey}`, { method: "DELETE", token }), env, noopCtx);
}

function leaveRoom(env: LooseEnv, token: string) {
  return worker.fetch(request(`/api/document/rooms/${ROOM_ID}/leave`, { method: "POST", token, body: {} }), env, noopCtx);
}

test("the owner can remove an editor, who then loses every access and their pending proposals", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor");
  assert.equal((await propose(env, editor, 0, "x", "y")).status, 200);
  const editorKey = await sha256Hex(editor);

  const removed = await removeMember(env, owner, editorKey);
  assert.equal(removed.status, 200);
  assert.equal((await getState(env, editor)).status, 403, "a removed member can no longer read the document");
  assert.equal((await propose(env, editor, 0, "x", "z")).status, 403, "or propose changes");
  const state = await (await getState(env, owner)).json();
  assert.equal(state.pendingChanges.length, 0, "their undecided proposals went with them");
  assert.equal(await env.STUDIQUO_DATA.get(`doc-room:${editorKey}:${ROOM_ID}`), null, "and the account index entry");
});

test("removing a member also withdraws an invitation they had not answered", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  const friendKey = await sha256Hex(friend);
  assert.ok(await env.STUDIQUO_DATA.get(`doc-invite:${friendKey}:${ROOM_ID}`));

  // Not seated yet: the owner withdrawing the offer is what "removing" them means.
  assert.equal((await removeMember(env, owner, friendKey)).status, 200);
  const accept = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(accept.status, 404);
});

test("only the owner can remove a member; an editor cannot remove the owner or others", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  const reviewer = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor");
  await invite(env, owner, reviewer, "reviewer");

  assert.equal((await removeMember(env, editor, await sha256Hex(reviewer))).status, 403);
  assert.equal((await removeMember(env, editor, await sha256Hex(owner))).status, 403);
  assert.equal((await removeMember(env, freshToken("9"), await sha256Hex(editor))).status, 403, "a stranger cannot either");
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(reviewer)), "reviewer");
});

test("the owner cannot remove themselves or leave, and cannot remove someone who is not in the room", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await removeMember(env, owner, await sha256Hex(owner))).status, 400);
  assert.equal((await leaveRoom(env, owner)).status, 400);
  assert.equal((await removeMember(env, owner, "b".repeat(64))).status, 404);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(owner)), "owner");
});

test("a member can leave on their own and then loses access", async () => {
  const env = environment();
  const owner = freshToken("1");
  const editor = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await invite(env, owner, editor, "editor");

  assert.equal((await leaveRoom(env, editor)).status, 200);
  assert.equal((await getState(env, editor)).status, 403);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-room:${await sha256Hex(editor)}:${ROOM_ID}`), null);
  assert.equal((await leaveRoom(env, editor)).status, 403, "leaving twice is refused, not silently accepted");
});

// MARK: Accepting an invitation re-checks the relationship

test("an invitation cannot be accepted after the owner has blocked the invitee", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  const friendRecord = await env.STUDIQUO_DATA.get(`chat:user:${await sha256Hex(friend)}`, "json");
  const code = friendRecord.code;
  env.CHAT_ROOM = fakeChatRoomBinding(new Set([`room-${code}`]));

  const accept = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(accept.status, 403);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
});

test("an invitation cannot be accepted once the owner is no longer the invitee's friend, and is kept in case that was a stale read", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  const friendKey = await sha256Hex(friend);
  const record = await env.STUDIQUO_DATA.get(`chat:user:${friendKey}`, "json");
  record.friends = [];
  await env.STUDIQUO_DATA.put(`chat:user:${friendKey}`, JSON.stringify(record));

  const accept = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(accept.status, 403);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(friendKey), null);
  assert.ok(await env.STUDIQUO_DATA.get(`doc-invite:${friendKey}:${ROOM_ID}`), "the offer stays; it expires on its own");
});

test("an invitation whose inviter's account is gone is cleared", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  await env.STUDIQUO_DATA.delete(`chat:user:${await sha256Hex(owner)}`);
  const friendKey = await sha256Hex(friend);

  const accept = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(accept.status, 410);
  assert.equal(await env.STUDIQUO_DATA.get(`doc-invite:${friendKey}:${ROOM_ID}`), null);
});


// ---- Gaps: blocks from the other side, self-invites, re-invites, answering edge cases ----

const membershipKey = async (token: string) => `doc-room:${await sha256Hex(token)}:${ROOM_ID}`;
const inviteKeyFor = async (token: string) => `doc-invite:${await sha256Hex(token)}:${ROOM_ID}`;
const answerInvite = (env: LooseEnv, token: string, answer: "accept" | "decline") =>
  worker.fetch(request(`/api/document/rooms/${ROOM_ID}/invite/${answer}`, { method: "POST", token, body: {} }), env, noopCtx);

test("a friend who has blocked the owner cannot be invited either", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, friend, "友人", { befriendedBy: owner });
  env.CHAT_ROOM = { getByName: () => ({ async blockStatus() { return { blockedByMe: false, blockedByOther: true }; } }) };
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "editor" } }),
    env, noopCtx
  );
  assert.equal(response.status, 403);
  assert.equal(await env.STUDIQUO_DATA.get(await inviteKeyFor(friend)), null, "no offer is left behind");
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
});

test("an owner cannot invite themselves, even through a friend entry that carries their own code", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, owner, "自分", { befriendedBy: owner });
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "editor" } }),
    env, noopCtx
  );
  assert.equal(response.status, 400);
  assert.equal(await env.STUDIQUO_DATA.get(await inviteKeyFor(owner)), null);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(owner)), "owner");
});

test("a friend code is accepted in lower case and with surrounding spaces", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, friend, "友人", { befriendedBy: owner });
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code: ` ${code.toLowerCase()} `, role: "reviewer" } }),
    env, noopCtx
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "pending");
});

test("inviting someone who already took part changes their role at once, without a new offer", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const code = await registerFriend(env, friend, "友人", { befriendedBy: owner });
  // Accepting re-checks the friendship from the invitee's side, so it must be mutual.
  const ownerRecord = await env.STUDIQUO_DATA.get(`chat:user:${await sha256Hex(owner)}`, "json");
  await befriend(env, friend, { code: ownerRecord.code, name: "owner", roomID: `room-${code}` });
  const send = (role: string) => worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role } }), env, noopCtx);
  assert.equal((await send("editor")).status, 200);
  assert.equal((await answerInvite(env, friend, "accept")).status, 200);

  const changed = await send("reviewer");
  assert.equal(changed.status, 200);
  assert.deepEqual(await changed.json(), { status: "invited" });
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), "reviewer");
  assert.equal(await env.STUDIQUO_DATA.get(await membershipKey(friend)), "reviewer");
  assert.equal(await env.STUDIQUO_DATA.get(await inviteKeyFor(friend)), null, "nothing is waiting for an answer");
});

test("inviting again while an offer is waiting replaces it, even when the friend is already at the limit", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  const friendKey = await sha256Hex(friend);
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  for (let i = 0; i < 19; i++) {
    await env.STUDIQUO_DATA.put(`doc-invite:${friendKey}:${String(i + 1).padStart(64, "0")}`, JSON.stringify({ inviterKey: "x", role: "editor", createdAt: i }));
  }
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  // Now 20 are waiting. A second offer for the same room is a change, not a 21st.
  const code = (await env.STUDIQUO_DATA.get(`chat:user:${friendKey}`, "json")).code;
  const again = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code, role: "reviewer" } }), env, noopCtx);
  assert.equal(again.status, 200);
  const stored = await env.STUDIQUO_DATA.get(await inviteKeyFor(friend), "json");
  assert.equal(stored.role, "reviewer");
});

test("the waiting invitations are listed newest first, only for the person they were made to", async () => {
  const env = environment();
  const friend = freshToken("2");
  const other = freshToken("3");
  const friendKey = await sha256Hex(friend);
  const otherKey = await sha256Hex(other);
  const rooms = ["1", "2", "3"].map(digit => digit.repeat(64));
  await env.STUDIQUO_DATA.put(`doc-invite:${friendKey}:${rooms[0]}`, JSON.stringify({ inviterKey: "o", inviterName: "古い", role: "editor", createdAt: 100 }));
  await env.STUDIQUO_DATA.put(`doc-invite:${friendKey}:${rooms[1]}`, JSON.stringify({ inviterKey: "o", role: "reviewer", createdAt: 300 }));
  await env.STUDIQUO_DATA.put(`doc-invite:${otherKey}:${rooms[2]}`, JSON.stringify({ inviterKey: "o", role: "editor", createdAt: 200 }));

  const listed = await (await worker.fetch(request("/api/document/invites", { token: friend }), env, noopCtx)).json();
  assert.deepEqual(listed.map((item: Untyped) => item.roomID), [rooms[1], rooms[0]]);
  assert.equal(listed[0].inviterName, null, "a missing name is null, not undefined");
  assert.equal(listed[1].inviterName, "古い");
  assert.deepEqual(await (await worker.fetch(request("/api/document/invites", { token: other }), env, noopCtx)).json().then((items: Untyped[]) => items.map(item => item.roomID)), [rooms[2]]);
});

test("an offer whose role is no longer valid is void when answered, and is cleared", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  await env.STUDIQUO_DATA.put(await inviteKeyFor(friend), JSON.stringify({ inviterKey: await sha256Hex(owner), role: "owner", createdAt: Date.now() }));
  const response = await answerInvite(env, friend, "accept");
  assert.equal(response.status, 410);
  assert.equal(await env.STUDIQUO_DATA.get(await inviteKeyFor(friend)), null);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
});

test("accepting after the account was deleted leaves no seat and no membership record, and keeps the offer to expire", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  await env.STUDIQUO_DATA.delete(`chat:user:${await sha256Hex(friend)}`);
  const response = await answerInvite(env, friend, "accept");
  // Accepting re-confirms the friendship, which a deleted account can no longer show.
  assert.equal(response.status, 403);
  assert.equal(await env.DOCUMENT_ROOM.getByName(ROOM_ID).roleOf(await sha256Hex(friend)), null);
  assert.equal(await env.STUDIQUO_DATA.get(await membershipKey(friend)), null);
  // A missing friendship is refused but the offer is kept (KV reads lag); it expires by itself.
  assert.notEqual(await env.STUDIQUO_DATA.get(await inviteKeyFor(friend)), null);
});

test("accepting or declining is rate limited", async () => {
  const env = environment();
  const friend = freshToken("2");
  let last = 0;
  for (let i = 0; i < 21; i++) last = (await answerInvite(env, friend, "decline")).status;
  assert.equal(last, 429);
});

test("an offer made for one room can't be used to enter another", async () => {
  const env = environment();
  const owner = freshToken("1");
  const friend = freshToken("2");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await sendInvite(env, owner, friend, "editor")).status, 200);
  const otherRoom = "b".repeat(64);
  const response = await worker.fetch(request(`/api/document/rooms/${otherRoom}/invite/accept`, { method: "POST", token: friend, body: {} }), env, noopCtx);
  assert.equal(response.status, 404);
  assert.equal(await env.DOCUMENT_ROOM.getByName(otherRoom).roleOf(await sha256Hex(friend)), null);
  assert.notEqual(await env.STUDIQUO_DATA.get(await inviteKeyFor(friend)), null, "the real offer is untouched");
});

test("someone outside the room can read neither its participants nor its state, and an uncreated room is closed too", async () => {
  const env = environment();
  const owner = freshToken("1");
  const stranger = freshToken("3");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const participants = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/participants`, { token: stranger }), env, noopCtx);
  assert.equal(participants.status, 403);
  assert.equal((await getState(env, stranger)).status, 403);
  const never = "c".repeat(64);
  const missing = await worker.fetch(request(`/api/document/rooms/${never}/state`, { token: owner }), env, noopCtx);
  assert.equal(missing.status, 403);
});

test("an owner's retried init restores the membership record; someone else's init of that room records nothing", async () => {
  const env = environment();
  const owner = freshToken("1");
  const intruder = freshToken("4");
  assert.equal((await (await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }])).json()).status, "initialized");
  assert.equal(await env.STUDIQUO_DATA.get(await membershipKey(owner)), "owner");

  // The first attempt created the room but failed before the record was written.
  await env.STUDIQUO_DATA.delete(await membershipKey(owner));
  const retry = await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  assert.equal((await retry.json()).status, "already_initialized");
  assert.equal(await env.STUDIQUO_DATA.get(await membershipKey(owner)), "owner");

  const taken = await initRoom(env, intruder, [{ order: 0, kind: "paragraph", text: "mine" }]);
  assert.equal((await taken.json()).status, "already_initialized");
  assert.equal(await env.STUDIQUO_DATA.get(await membershipKey(intruder)), null);
  assert.equal((await getState(env, intruder)).status, 403);
  assert.equal((await (await getState(env, owner)).json()).blocks[0].text, "x", "the room's text is unchanged");
});

test("an unknown path under /api/document/ is a 404, and a known path with the wrong method is too", async () => {
  const env = environment();
  const owner = freshToken("1");
  assert.equal((await worker.fetch(request("/api/document/nope", { token: owner }), env, noopCtx)).status, 404);
  assert.equal((await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/state`, { method: "POST", token: owner, body: {} }), env, noopCtx)).status, 404);
  assert.equal((await worker.fetch(request("/api/document/invites", { method: "POST", token: owner, body: {} }), env, noopCtx)).status, 404);
});

// ---------- whole-document sync (snapshot and images) ----------

const snapshotPath = `/api/document/rooms/${ROOM_ID}/snapshot`;
const putSnapshot = (env: LooseEnv, token: string, baseRevision: number, snapshot: string) =>
  worker.fetch(request(snapshotPath, { method: "PUT", token, body: { baseRevision, snapshot } }), env, noopCtx);
const getSnapshot = (env: LooseEnv, token: string, since = -1) =>
  worker.fetch(request(`${snapshotPath}?since=${since}`, { token }), env, noopCtx);

async function roomWith(roles: string[]) {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "はじめに" }]);
  const tokens: Record<string, string> = { owner };
  for (const [index, role] of roles.entries()) {
    tokens[role] = freshToken(String(index + 2));
    assert.equal((await invite(env, owner, tokens[role], role)).status, 200);
  }
  return { env, tokens };
}

test("an editor and the owner save snapshots on top of each other; a stale save gets 409 with the current revision", async () => {
  const { env, tokens } = await roomWith(["editor"]);
  const first = await putSnapshot(env, tokens.owner, 0, "v1");
  assert.deepEqual(await first.json(), { revision: 1 });
  const second = await putSnapshot(env, tokens.editor, 1, "v2");
  assert.deepEqual(await second.json(), { revision: 2 });
  const stale = await putSnapshot(env, tokens.owner, 1, "stale");
  assert.equal(stale.status, 409);
  assert.deepEqual(await stale.json(), { error: "conflict", revision: 2 });
  assert.deepEqual(await (await getSnapshot(env, tokens.owner)).json(), { revision: 2, snapshot: "v2" });
  assert.deepEqual(await (await getSnapshot(env, tokens.owner, 2)).json(), { revision: 2, snapshot: null, unchanged: true });
});

test("a reviewer can read the snapshot but not write it; a stranger can do neither", async () => {
  const { env, tokens } = await roomWith(["reviewer"]);
  await putSnapshot(env, tokens.owner, 0, "v1");
  assert.equal((await getSnapshot(env, tokens.reviewer)).status, 200);
  assert.equal((await putSnapshot(env, tokens.reviewer, 1, "x")).status, 403);
  const stranger = freshToken("9");
  assert.equal((await getSnapshot(env, stranger)).status, 403);
  assert.equal((await putSnapshot(env, stranger, 1, "x")).status, 403);
});

test("a malformed snapshot write is a 400, an oversized one a 413", async () => {
  const { env, tokens } = await roomWith([]);
  const bad = (body: unknown) => worker.fetch(request(snapshotPath, { method: "PUT", token: tokens.owner, body }), env, noopCtx);
  assert.equal((await bad({ baseRevision: "x", snapshot: "s" })).status, 400);
  assert.equal((await bad({ baseRevision: -1, snapshot: "s" })).status, 400);
  assert.equal((await bad({ baseRevision: 0, snapshot: 5 })).status, 400);
  assert.equal((await putSnapshot(env, tokens.owner, 0, "x".repeat(6_000_001))).status, 413);
});

test("an image is stored under the SHA-256 of its bytes: a wrong name is refused, a right one is stored once and read back", async () => {
  const { env, tokens } = await roomWith(["editor", "reviewer"]);
  const bytes = new Uint8Array([1, 2, 3, 250, 251]);
  const data = btoa(String.fromCharCode(...bytes));
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(b => b.toString(16).padStart(2, "0")).join("");
  const assetPath = (name: string) => `/api/document/rooms/${ROOM_ID}/assets/${name}`;
  const put = (token: string, name: string, body: unknown) => worker.fetch(request(assetPath(name), { method: "PUT", token, body }), env, noopCtx);

  assert.equal((await put(tokens.editor, "b".repeat(64), { data })).status, 400, "the name must be the hash of the bytes");
  assert.equal((await put(tokens.editor, hash, { data: "not base64!" })).status, 400);
  assert.deepEqual(await (await put(tokens.editor, hash, { data })).json(), { status: "stored" });
  assert.deepEqual(await (await put(tokens.owner, hash, { data })).json(), { status: "exists" });
  assert.equal((await put(tokens.reviewer, hash, { data })).status, 403, "a reviewer cannot upload");

  const missing = await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/assets/missing`, { method: "POST", token: tokens.reviewer, body: { hashes: [hash, "c".repeat(64)] } }), env, noopCtx);
  assert.deepEqual(await missing.json(), { missing: ["c".repeat(64)] });
  const got = await worker.fetch(request(assetPath(hash), { token: tokens.reviewer }), env, noopCtx);
  assert.deepEqual(await got.json(), { data });
  assert.equal((await worker.fetch(request(assetPath("d".repeat(64)), { token: tokens.owner }), env, noopCtx)).status, 404);
  assert.equal((await worker.fetch(request(assetPath(hash), { token: freshToken("9") }), env, noopCtx)).status, 403);
});

// Regression: the app once sent "…/snapshot%3Fsince=0" (the "?" percent-encoded into the
// path), which matches no route and answered 404 on every poll, so nothing was ever synced.
test("the snapshot route takes its query as a query; an encoded question mark in the path is a 404", async () => {
  const { env, tokens } = await roomWith([]);
  await putSnapshot(env, tokens.owner, 0, "v1");
  const ok = await worker.fetch(request(`${snapshotPath}?since=0`, { token: tokens.owner }), env, noopCtx);
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { revision: 1, snapshot: "v1" });
  const encoded = await worker.fetch(request(`${snapshotPath}%3Fsince=0`, { token: tokens.owner }), env, noopCtx);
  assert.equal(encoded.status, 404);
  // Without a query the full snapshot comes back; a junk query is ignored rather than failing.
  assert.equal((await worker.fetch(request(`${snapshotPath}?since=abc`, { token: tokens.owner }), env, noopCtx)).status, 200);
});

// Regression: a first sync of a room with no snapshot, then a second device reading it, must hand
// back exactly what was stored (no loss through the revision rule).
test("what the first writer stores is exactly what a later reader gets, and writes can only build on the current revision", async () => {
  const { env, tokens } = await roomWith(["editor"]);
  const text = JSON.stringify({ blocks: ["あ".repeat(10), "い"] });
  assert.deepEqual(await (await putSnapshot(env, tokens.owner, 0, text)).json(), { revision: 1 });
  assert.deepEqual(await (await getSnapshot(env, tokens.editor, 0)).json(), { revision: 1, snapshot: text });
  assert.equal((await putSnapshot(env, tokens.editor, 0, "late")).status, 409);
});

// Review finding: an editor who writes before the owner has ever synced would make a thinner copy
// the room's first truth (and the owner's richer document would then be overwritten by it).
test("the first snapshot of a room can only come from its owner; an editor is told the room is not ready", async () => {
  const { env, tokens } = await roomWith(["editor"]);
  const early = await putSnapshot(env, tokens.editor, 0, "thin copy");
  assert.equal(early.status, 412);
  assert.deepEqual(await (await getSnapshot(env, tokens.owner)).json(), { revision: 0, snapshot: null }, "nothing was stored");
  assert.deepEqual(await (await putSnapshot(env, tokens.owner, 0, "owner version")).json(), { revision: 1 });
  assert.deepEqual(await (await putSnapshot(env, tokens.editor, 1, "editor edit")).json(), { revision: 2 });
});

// Review finding: authorization came after reading and hashing a body of several MB.
test("a stranger or reviewer is refused before any body is read, and a malformed base64 image is a 400, not a 500", async () => {
  const { env, tokens } = await roomWith(["reviewer"]);
  const stranger = freshToken("9");
  const assetPath = `/api/document/rooms/${ROOM_ID}/assets/${"e".repeat(64)}`;
  for (const token of [stranger, tokens.reviewer]) {
    assert.equal((await worker.fetch(request(assetPath, { method: "PUT", token, body: { data: "AAAA" } }), env, noopCtx)).status, 403);
    assert.equal((await putSnapshot(env, token, 0, "x")).status, 403);
  }
  const owner = tokens.owner;
  for (const data of ["A", "AAA", "A===", "====", "AAAA=A"]) {
    const response = await worker.fetch(request(assetPath, { method: "PUT", token: owner, body: { data } }), env, noopCtx);
    assert.equal(response.status, 400, data);
  }
});

test("images the new snapshot no longer names are dropped; a just-uploaded one is kept for a while", async () => {
  const { env, tokens } = await roomWith(["editor"]);
  const bytes = (n: number) => new Uint8Array([n, n + 1, n + 2]);
  const sha = async (b: Uint8Array) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map(x => x.toString(16).padStart(2, "0")).join("");
  const put = async (b: Uint8Array) => {
    const hash = await sha(b);
    await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/assets/${hash}`, { method: "PUT", token: tokens.owner, body: { data: btoa(String.fromCharCode(...b)) } }), env, noopCtx);
    return hash;
  };
  const keep = await put(bytes(1));
  const dropped = await put(bytes(10));
  const write = (base: number, assets: string[]) => worker.fetch(request(snapshotPath, { method: "PUT", token: tokens.owner, body: { baseRevision: base, snapshot: "s", assets } }), env, noopCtx);
  assert.equal((await write(0, [keep])).status, 200);
  const has = async (hash: string) => (await worker.fetch(request(`/api/document/rooms/${ROOM_ID}/assets/${hash}`, { token: tokens.owner }), env, noopCtx)).status;
  assert.equal(await has(dropped), 200, "uploaded a moment ago: kept during the grace period");
  assert.equal(await has(keep), 200);
});

test("missingAssets deduplicates, drops non-hex hashes, caps at 200, and rejects non-string elements", async () => {
  const { env, tokens } = await roomWith(["editor"]);
  const valid200 = Array.from({ length: 200 }, (_, i) => i.toString(16).padStart(64, "0"));
  const tooMany205 = [...valid200, valid200[0], "not-a-hash", "UPPER".padStart(64, "0"), "f".repeat(64)];

  const cappedMissing = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/assets/missing`, { method: "POST", token: tokens.editor, body: { hashes: tooMany205 } }),
    env, noopCtx
  );
  assert.equal(cappedMissing.status, 200);
  const body = await cappedMissing.json();
  assert.equal(body.missing.length, 200);
  assert.deepEqual(body.missing, valid200);

  const nonStringMissing = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/assets/missing`, { method: "POST", token: tokens.editor, body: { hashes: [123] } }),
    env, noopCtx
  );
  assert.equal(nonStringMissing.status, 400);
});
