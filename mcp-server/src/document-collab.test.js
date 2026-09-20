import assert from "node:assert/strict";
import test from "node:test";
import worker from "./app.js";
import { sha256Hex } from "./auth.js";

// Stands in for the real DocumentRoom Durable Object (document-room.js): one
// shared participants/blocks/changes record per room id, persisting across
// separate getByName(id) calls the way a real Durable Object instance would.
function fakeDocumentRoomBinding() {
  const rooms = new Map();
  function room(id) {
    if (!rooms.has(id)) rooms.set(id, { participants: new Map(), blocks: new Map(), changes: [], nextChangeID: 1 });
    return rooms.get(id);
  }
  function requireParticipant(state, userKey) {
    const role = state.participants.get(userKey);
    if (!role) throw new Error("Forbidden");
    return role;
  }
  function requireReviewer(state, userKey) {
    const role = requireParticipant(state, userKey);
    if (role !== "owner" && role !== "reviewer") throw new Error("Forbidden");
  }
  return {
    getByName(id) {
      const state = room(id);
      return {
        async initialize(ownerKey, blocks) {
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
        async invite(ownerKey, userKey, role) {
          const ownerRole = requireParticipant(state, ownerKey);
          if (ownerRole !== "owner") throw new Error("Forbidden");
          if (role !== "editor" && role !== "reviewer") throw new Error("InvalidRole");
          if (userKey === ownerKey) throw new Error("InvalidRole");
          state.participants.set(userKey, role);
          return { status: "invited" };
        },
        async listParticipants(userKey) {
          requireParticipant(state, userKey);
          return Array.from(state.participants, ([key, role]) => ({ userKey: key, role }));
        },
        async getState(userKey) {
          requireParticipant(state, userKey);
          return {
            blocks: Array.from(state.blocks.values()).sort((a, b) => a.order - b.order),
            pendingChanges: state.changes.filter(change => change.status === "pending"),
          };
        },
        async proposeChange(userKey, blockOrder, previousText, newText) {
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
        async reviewChange(userKey, changeID, decision) {
          requireReviewer(state, userKey);
          if (decision !== "accept" && decision !== "reject") throw new Error("InvalidDecision");
          const change = state.changes.find(item => item.id === changeID);
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

function environment() {
  const values = new Map();
  const studiquoData = {
    async get(key, type) {
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
    async put(key, value) { values.set(key, value); },
    async delete(key) { values.delete(key); },
  };
  return {
    STUDIQUO_DATA: studiquoData,
    DOCUMENT_ROOM: fakeDocumentRoomBinding(),
  };
}

const noopCtx = { waitUntil() {} };

function freshToken(suffix) {
  return `${Math.floor(Date.now() / 1000)}.${suffix.repeat(40)}`;
}

function request(path, { method = "GET", token, body } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  return new Request(`https://example.test${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

const ROOM_ID = "a".repeat(64);

function initRoom(env, token, blocks) {
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/init`, { method: "POST", token, body: { blocks } }),
    env,
    noopCtx
  );
}

let nextTestCode = 1;

// Seeds the same chat:user:/chat:code: KV records chat.js's registerUser()
// would create for a real account, so invite() below can resolve a friend
// code to a userKey exactly the way the live handler does. Returns the
// minted code.
async function registerFriend(env, token, name) {
  const userKey = await sha256Hex(token);
  const code = `TESTCODE${String(nextTestCode++).padStart(4, "0")}`;
  await env.STUDIQUO_DATA.put(`chat:user:${userKey}`, JSON.stringify({ key: userKey, name, code, friends: [] }));
  await env.STUDIQUO_DATA.put(`chat:code:${code}`, userKey);
  return code;
}

// `inviteeToken` is the token belonging to the person being invited — the
// route resolves their friend code to a userKey server-side (the same way
// chat.js resolves one when adding a friend), so this registers them first.
async function invite(env, ownerToken, inviteeToken, role, { name = "友人" } = {}) {
  const code = await registerFriend(env, inviteeToken, name);
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: ownerToken, body: { code, role } }),
    env,
    noopCtx
  );
}

function getState(env, token) {
  return worker.fetch(request(`/api/document/rooms/${ROOM_ID}/state`, { token }), env, noopCtx);
}

function propose(env, token, blockOrder, previousText, newText) {
  return worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/propose`, { method: "POST", token, body: { blockOrder, previousText, newText } }),
    env,
    noopCtx
  );
}

function review(env, token, changeID, decision) {
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
    const response = await invite(env, owner, freshToken(`invitee${i}`), "editor");
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
  assert.ok(participants.some(entry => entry.userKey && entry.role === "owner"));
  assert.ok(participants.some(entry => entry.role === "editor" && entry.name === "田中"));
});

test("inviting with a code no one is registered under returns 404", async () => {
  const env = environment();
  const owner = freshToken("1");
  await initRoom(env, owner, [{ order: 0, kind: "paragraph", text: "x" }]);
  const response = await worker.fetch(
    request(`/api/document/rooms/${ROOM_ID}/invite`, { method: "POST", token: owner, body: { code: "NOSUCHCODE1", role: "editor" } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 404);
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
