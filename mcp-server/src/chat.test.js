import assert from "node:assert/strict";
import test from "node:test";
import worker from "./app.js";

// Regression coverage for "friend requests are approved, not instant": adding
// a friend by code must create a one-directional pending request instead of
// an immediate mutual friendship, so a stranger who only knows your code
// can't start messaging you without your consent.

// Stands in for the real ChatRoom Durable Object (chat-room.js): one shared
// participants/messages record per room name, persisting across separate
// getByName(name) calls the way a real Durable Object instance would.
const ATTACHMENT_CONTENT_TYPE_PATTERN = /^[a-zA-Z0-9!#$&\-^_.+]+\/[a-zA-Z0-9!#$&\-^_.+]+$/;
const FAKE_MAX_ATTACHMENT_BYTES = 3 * 1024 * 1024;
const FAKE_ATTACHMENT_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

function fakeChatRoomBinding() {
  const rooms = new Map();
  const initializeCalls = { count: 0 };
  let nextAttachmentId = 1;
  function room(name) {
    if (!rooms.has(name)) rooms.set(name, { participants: new Set(), messages: [], attachments: new Map() });
    return rooms.get(name);
  }
  return {
    initializeCalls,
    getByName(name) {
      const state = room(name);
      return {
        async initialize(_roomID, participants) {
          initializeCalls.count += 1;
          if (state.participants.size > 0) return;
          for (const key of participants.slice(0, 2)) state.participants.add(key);
        },
        async sendMessage(userKey, text, clientMessageID = null) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const message = { id: state.messages.length + 1, text, sentAt: Date.now(), isMine: true, clientMessageID, isCanceled: false };
          state.messages.push({ ...message, senderKey: userKey });
          return message;
        },
        async listMessages(userKey, after = 0) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          return state.messages
            .filter(item => item.id > after)
            .map(({ senderKey, ...rest }) => ({ ...rest, isMine: senderKey === userKey }));
        },
        // Mirrors chat-room.js's real cancelMessage: only the original
        // sender may retract it, and the stored text is actually cleared
        // (not just hidden), so every future read of this room sees it gone.
        async cancelMessage(userKey, messageID) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const message = state.messages.find(item => item.id === messageID);
          if (!message) return { status: "not_found" };
          if (message.senderKey !== userKey) throw new Error("Forbidden");
          message.text = "";
          message.isCanceled = true;
          return { status: "canceled" };
        },
        // Mirrors chat-room.js's real storeAttachment/getAttachment: same
        // validation, same Forbidden gate, same in-room storage — so the
        // fake actually exercises the same access-control path.
        // Mirrors chat-room.js's opportunistic cleanup too: every new
        // upload purges attachments past the retention window first, since
        // there's no cron/alarm to do it on a schedule.
        async storeAttachment(userKey, contentType, base64Data) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const type = String(contentType ?? "").slice(0, 100);
          if (!ATTACHMENT_CONTENT_TYPE_PATTERN.test(type)) throw new Error("InvalidContentType");
          const data = String(base64Data ?? "");
          const approxBytes = Math.floor((data.length * 3) / 4);
          if (!data || approxBytes > FAKE_MAX_ATTACHMENT_BYTES) throw new Error("AttachmentTooLarge");
          for (const [existingId, existing] of state.attachments) {
            if (Date.now() - existing.createdAt >= FAKE_ATTACHMENT_RETENTION_MS) state.attachments.delete(existingId);
          }
          const id = `00000000-0000-4000-8000-${String(nextAttachmentId++).padStart(12, "0")}`;
          state.attachments.set(id, { contentType: type, data, createdAt: Date.now() });
          return { id };
        },
        async getAttachment(userKey, id) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          return state.attachments.get(id) ?? null;
        },
        // Test-only hook: backdates an attachment's stored timestamp to
        // simulate one uploaded long ago, without needing to actually wait
        // out the retention window.
        async _setAttachmentCreatedAtForTesting(id, createdAt) {
          const entry = state.attachments.get(id);
          if (entry) entry.createdAt = createdAt;
        },
      };
    },
  };
}

// Mirrors the real Cloudflare Rate Limiting binding's shape (see app.test.js).
function fakeCloudflareLimiter(limit = 5) {
  const counts = new Map();
  return {
    async limit({ key }) {
      const count = (counts.get(key) ?? 0) + 1;
      counts.set(key, count);
      return { success: count <= limit };
    },
  };
}

const REGISTRY_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateRegistryTestCode() {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => REGISTRY_CODE_ALPHABET[value % 32]).join("");
}

// Stands in for the real UserRegistry Durable Object (user-registry.js):
// same get-or-create logic against the same KV store, but — like a real
// Durable Object handling one request at a time per instance — calls for the
// same key are chained so a second call for a key that's still being
// registered waits for the first to finish, instead of racing it.
function fakeUserRegistryBinding(studiquoData) {
  const queues = new Map();

  async function ensureUserAtomic(key, name) {
    const storageKey = `chat:user:${key}`;
    let user = await studiquoData.get(storageKey, "json");
    if (user) {
      const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
      if (cleaned && cleaned !== user.name) {
        user.name = cleaned;
        await studiquoData.put(storageKey, JSON.stringify(user));
      }
      return user;
    }
    let friendCode;
    do { friendCode = generateRegistryTestCode(); } while (await studiquoData.get(`chat:code:${friendCode}`));
    user = { key, name: String(name ?? "").trim().slice(0, 80) || "Studiquoユーザー", code: friendCode, friends: [] };
    await Promise.all([
      studiquoData.put(storageKey, JSON.stringify(user)),
      studiquoData.put(`chat:code:${friendCode}`, key),
    ]);
    return user;
  }

  async function addIncomingRequestAtomic(key, requesterCode, requesterName) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.friends ?? []).some(item => item.code === requesterCode)) {
      return { status: "already_friends" };
    }
    if (!(user.incomingRequests ?? []).some(item => item.code === requesterCode)) {
      user.incomingRequests = [
        ...(user.incomingRequests ?? []),
        { code: requesterCode, name: requesterName, requestedAt: Date.now() },
      ].slice(-500);
      await studiquoData.put(storageKey, JSON.stringify(user));
    }
    return { status: "pending", recipient: { code: user.code, name: user.name } };
  }

  async function addOutgoingRequestAtomic(key, recipientCode, recipientName) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return;
    if (!(user.outgoingRequests ?? []).some(item => item.code === recipientCode)) {
      user.outgoingRequests = [
        ...(user.outgoingRequests ?? []),
        { code: recipientCode, name: recipientName, requestedAt: Date.now() },
      ].slice(-500);
      await studiquoData.put(storageKey, JSON.stringify(user));
    }
  }

  async function removeOutgoingRequestAtomic(key, recipientCode) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return;
    const filtered = (user.outgoingRequests ?? []).filter(item => item.code !== recipientCode);
    if (filtered.length !== (user.outgoingRequests ?? []).length) {
      user.outgoingRequests = filtered;
      await studiquoData.put(storageKey, JSON.stringify(user));
    }
  }

  async function resolveIncomingRequestAtomic(key, action, otherCode, otherName, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user || !(user.incomingRequests ?? []).some(item => item.code === otherCode)) {
      return { status: "not_found" };
    }
    user.incomingRequests = (user.incomingRequests ?? []).filter(item => item.code !== otherCode);
    if (action === "reject") {
      await studiquoData.put(storageKey, JSON.stringify(user));
      return { status: "rejected", recipient: { code: user.code, name: user.name } };
    }
    if ((user.friends ?? []).length >= 500) {
      return { status: "friends_full" };
    }
    user.friends = [...(user.friends ?? []).filter(item => item.code !== otherCode), { code: otherCode, name: otherName, roomID }];
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "accepted", friend: { code: user.code, name: user.name } };
  }

  // All methods share the same per-key queue, mirroring how a single real
  // Durable Object instance serializes every call it receives — regardless
  // of which method is called — one at a time.
  function enqueue(key, run) {
    const previous = queues.get(key) ?? Promise.resolve();
    const next = previous.then(run);
    queues.set(key, next.catch(() => {}));
    return next;
  }

  return {
    getByName(key) {
      return {
        ensureUser(k, name) {
          return enqueue(key, () => ensureUserAtomic(k, name));
        },
        addIncomingRequest(k, requesterCode, requesterName) {
          return enqueue(key, () => addIncomingRequestAtomic(k, requesterCode, requesterName));
        },
        addOutgoingRequest(k, recipientCode, recipientName) {
          return enqueue(key, () => addOutgoingRequestAtomic(k, recipientCode, recipientName));
        },
        removeOutgoingRequest(k, recipientCode) {
          return enqueue(key, () => removeOutgoingRequestAtomic(k, recipientCode));
        },
        resolveIncomingRequest(k, action, otherCode, otherName, roomID) {
          return enqueue(key, () => resolveIncomingRequestAtomic(k, action, otherCode, otherName, roomID));
        },
      };
    },
  };
}

function environment() {
  const values = new Map();
  const studiquoData = {
    async get(key, type) {
      // A real KV read is a network round trip, not a same-tick microtask —
      // without this, two "concurrent" requests in these tests never
      // actually interleave (each runs to completion before the next's
      // relevant read fires), so a race like the one UserRegistry guards
      // against couldn't be reproduced here at all.
      await new Promise(resolve => setImmediate(resolve));
      let value = values.get(key) ?? null;
      // These tests aren't exercising session-authenticity enforcement
      // itself (see app.test.js's "requireRealSession" tests) — treat any
      // well-formed bearer token as if it came from a real sign-in, so
      // freshToken()'s many call sites don't each need to seed one by hand.
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
    CHAT_ROOM: fakeChatRoomBinding(),
    USER_REGISTRY: fakeUserRegistryBinding(studiquoData),
    RATE_LIMIT_APPLE_AUTH: { async limit() { return { success: true }; } },
    RATE_LIMIT_CHAT_FRIEND_ADD: fakeCloudflareLimiter(),
    RATE_LIMIT_CHAT_MESSAGE: fakeCloudflareLimiter(30),
    _kv: values,
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

async function registerUser(env, token, name) {
  const response = await worker.fetch(
    request("/api/chat/me", { method: "POST", token, body: { name } }),
    env,
    noopCtx
  );
  assert.equal(response.status, 200);
  return response.json();
}

async function reportStudyStats(env, token, todayStudySeconds, studyDate) {
  return worker.fetch(
    request("/api/chat/me", { method: "POST", token, body: { todayStudySeconds, studyDate } }),
    env,
    noopCtx
  );
}

async function friends(env, token) {
  const response = await worker.fetch(request("/api/chat/friends", { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function incomingRequests(env, token) {
  const response = await worker.fetch(request("/api/chat/friends/requests", { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function outgoingRequests(env, token) {
  const response = await worker.fetch(request("/api/chat/friends/outgoing", { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function addFriend(env, token, code) {
  return worker.fetch(request("/api/chat/friends", { method: "POST", token, body: { code } }), env, noopCtx);
}

async function acceptRequest(env, token, code) {
  return worker.fetch(request("/api/chat/friends/requests/accept", { method: "POST", token, body: { code } }), env, noopCtx);
}

async function rejectRequest(env, token, code) {
  return worker.fetch(request("/api/chat/friends/requests/reject", { method: "POST", token, body: { code } }), env, noopCtx);
}

async function sendMessage(env, token, roomID, text, clientMessageID) {
  const body = clientMessageID === undefined ? { text } : { text, clientMessageID };
  return worker.fetch(request(`/api/chat/rooms/${roomID}/messages`, { method: "POST", token, body }), env, noopCtx);
}

async function cancelMessage(env, token, roomID, messageID) {
  return worker.fetch(request(`/api/chat/rooms/${roomID}/messages/${messageID}/cancel`, { method: "POST", token }), env, noopCtx);
}

async function readMessages(env, token, roomID) {
  const response = await worker.fetch(request(`/api/chat/rooms/${roomID}/messages`, { token }), env, noopCtx);
  return response;
}

async function readMessagesWithAfter(env, token, roomID, afterRaw) {
  const path = `/api/chat/rooms/${roomID}/messages?after=${encodeURIComponent(afterRaw)}`;
  return worker.fetch(request(path, { token }), env, noopCtx);
}

async function uploadAttachment(env, token, roomID, contentType, data) {
  return worker.fetch(
    request(`/api/chat/rooms/${roomID}/attachments`, { method: "POST", token, body: { contentType, data } }),
    env,
    noopCtx
  );
}

async function downloadAttachment(env, token, roomID, id) {
  return worker.fetch(request(`/api/chat/rooms/${roomID}/attachments/${id}`, { token }), env, noopCtx);
}

// Regression coverage for "registering a brand-new user is a race condition":
// two concurrent first-time registrations for the same caller must not each
// mint and persist a different friend code, leaving one orphaned.

test("concurrent registration of a brand-new user creates exactly one friend code", async () => {
  const env = environment();
  const token = freshToken("z0");

  const [a, b] = await Promise.all([
    registerUser(env, token, "Alice"),
    registerUser(env, token, "Alice"),
  ]);

  assert.equal(a.code, b.code);

  const codeKeys = [...env._kv.keys()].filter(k => k.startsWith("chat:code:"));
  assert.deepEqual(codeKeys, [`chat:code:${a.code}`]);
});

// Regression coverage for "a friend request can be silently lost": two
// different people requesting the same recipient at nearly the same moment
// must both end up recorded, not have one overwrite the other via a
// read-modify-write race on the recipient's incomingRequests array.
test("two different people requesting the same recipient at the same time both get recorded", async () => {
  const env = environment();
  const aliceToken = freshToken("z5");
  const carolToken = freshToken("z6");
  const bobToken = freshToken("z7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const carol = await registerUser(env, carolToken, "Carol");
  const bob = await registerUser(env, bobToken, "Bob");

  const [aliceResponse, carolResponse] = await Promise.all([
    addFriend(env, aliceToken, bob.code),
    addFriend(env, carolToken, bob.code),
  ]);
  assert.equal(aliceResponse.status, 200);
  assert.equal(carolResponse.status, 200);

  const bobsRequests = await incomingRequests(env, bobToken);
  assert.deepEqual(
    bobsRequests.map(item => item.code).sort(),
    [alice.code, carol.code].sort(),
    "both requests must be present — neither should be silently dropped"
  );
});

test("adding a friend by code creates a pending request, not an immediate friendship", async () => {
  const env = environment();
  const aliceToken = freshToken("a");
  const bobToken = freshToken("b");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  const response = await addFriend(env, aliceToken, bob.code);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "pending" });

  assert.deepEqual(await friends(env, aliceToken), []);
  assert.deepEqual(await friends(env, bobToken), []);

  const bobsRequests = await incomingRequests(env, bobToken);
  assert.equal(bobsRequests.length, 1);
  assert.equal(bobsRequests[0].code, alice.code);
  assert.equal(bobsRequests[0].name, "Alice");
  assert.ok(bobsRequests[0].requestedAt > 0);

  assert.deepEqual(await incomingRequests(env, aliceToken), []);

  // Lets the requester see "sent, awaiting approval" for their own request.
  const alicesOutgoing = await outgoingRequests(env, aliceToken);
  assert.equal(alicesOutgoing.length, 1);
  assert.equal(alicesOutgoing[0].code, bob.code);
  assert.equal(alicesOutgoing[0].name, "Bob");
  assert.deepEqual(await outgoingRequests(env, bobToken), []);
});

test("requesting the same friend twice does not duplicate the pending request", async () => {
  const env = environment();
  const aliceToken = freshToken("c");
  const bobToken = freshToken("d");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, aliceToken, "Alice");

  assert.equal((await addFriend(env, aliceToken, bob.code)).status, 200);
  assert.equal((await addFriend(env, aliceToken, bob.code)).status, 200);

  assert.equal((await incomingRequests(env, bobToken)).length, 1);
  assert.equal((await outgoingRequests(env, aliceToken)).length, 1);
});

test("accepting a request clears it from the requester's outgoing list", async () => {
  const env = environment();
  const aliceToken = freshToken("c2");
  const bobToken = freshToken("c3");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);
  assert.equal((await outgoingRequests(env, aliceToken)).length, 1);

  await acceptRequest(env, bobToken, alice.code);

  assert.deepEqual(await outgoingRequests(env, aliceToken), []);
});

test("rejecting a request clears it from the requester's outgoing list", async () => {
  const env = environment();
  const aliceToken = freshToken("c4");
  const bobToken = freshToken("c5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);
  assert.equal((await outgoingRequests(env, aliceToken)).length, 1);

  await rejectRequest(env, bobToken, alice.code);

  assert.deepEqual(await outgoingRequests(env, aliceToken), []);
});

test("requesting a code that does not exist returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("e");
  await registerUser(env, aliceToken, "Alice");

  const response = await addFriend(env, aliceToken, "NOSUCH1");
  assert.equal(response.status, 404);
  assert.match((await response.json()).error, /not found/i);
});

test("requesting your own code is rejected with a specific message and does not create a self-request", async () => {
  const env = environment();
  const aliceToken = freshToken("f");
  const alice = await registerUser(env, aliceToken, "Alice");

  const response = await addFriend(env, aliceToken, alice.code);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /cannot add yourself/i);
  assert.deepEqual(await incomingRequests(env, aliceToken), []);
});

test("requesting an existing mutual friend again reports already_friends and adds no pending request", async () => {
  const env = environment();
  const aliceToken = freshToken("g");
  const bobToken = freshToken("h");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  // Seed an already-accepted friendship directly, independent of the
  // accept flow under test elsewhere.
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);
  const bobKey = await env.STUDIQUO_DATA.get(`chat:code:${bob.code}`);
  const aliceRecord = await env.STUDIQUO_DATA.get(`chat:user:${aliceKey}`, "json");
  const bobRecord = await env.STUDIQUO_DATA.get(`chat:user:${bobKey}`, "json");
  aliceRecord.friends = [{ code: bob.code, name: bob.name, roomID: "room" }];
  bobRecord.friends = [{ code: alice.code, name: alice.name, roomID: "room" }];
  await env.STUDIQUO_DATA.put(`chat:user:${aliceKey}`, JSON.stringify(aliceRecord));
  await env.STUDIQUO_DATA.put(`chat:user:${bobKey}`, JSON.stringify(bobRecord));

  const response = await addFriend(env, aliceToken, bob.code);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "already_friends" });
  assert.deepEqual(await incomingRequests(env, bobToken), []);
  // Re-requesting an existing friend must not touch the chat room at all —
  // there is nothing to (re-)initialize.
  assert.equal(env.CHAT_ROOM.initializeCalls.count, 0);
});

// Regression coverage for "the room is (re-)initialized on every add, even
// when already friends": that was only possible under the old immediate-
// friendship design. Under the request/accept flow, re-requesting an
// established friend short-circuits on "already_friends" before ever
// reaching CHAT_ROOM, and accept can't fire twice for the same pair since
// the pending request is consumed the first time — so the room is
// initialized exactly once no matter how many times either side re-requests.
test("the chat room is initialized exactly once, even after repeated re-requests before and after acceptance", async () => {
  const env = environment();
  const aliceToken = freshToken("w0");
  const bobToken = freshToken("w1");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);
  await addFriend(env, aliceToken, bob.code); // re-request while still pending
  assert.equal(env.CHAT_ROOM.initializeCalls.count, 0);

  await acceptRequest(env, bobToken, alice.code);
  assert.equal(env.CHAT_ROOM.initializeCalls.count, 1);

  await addFriend(env, aliceToken, bob.code); // re-request now that they're friends
  await addFriend(env, bobToken, alice.code);
  assert.equal(env.CHAT_ROOM.initializeCalls.count, 1);
});

test("accepting a pending request makes both users friends with a matching room ID", async () => {
  const env = environment();
  const aliceToken = freshToken("i");
  const bobToken = freshToken("j");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);

  const response = await acceptRequest(env, bobToken, alice.code);
  assert.equal(response.status, 200);
  const accepted = await response.json();
  assert.equal(accepted.code, alice.code);
  assert.equal(accepted.name, "Alice");
  assert.ok(accepted.roomID);

  const bobsFriends = await friends(env, bobToken);
  assert.equal(bobsFriends.length, 1);
  assert.equal(bobsFriends[0].code, alice.code);
  assert.equal(bobsFriends[0].roomID, accepted.roomID);

  const alicesFriends = await friends(env, aliceToken);
  assert.equal(alicesFriends.length, 1);
  assert.equal(alicesFriends[0].code, bob.code);
  assert.equal(alicesFriends[0].roomID, accepted.roomID);

  assert.deepEqual(await incomingRequests(env, bobToken), []);
});

// Regression coverage for "a friend's today-study-time always shows as
// zero": each friend's own current stats must come back in GET
// /api/chat/friends, looked up live rather than frozen at accept time.

test("friends() reports each friend's own current study stats", async () => {
  const env = environment();
  const aliceToken = freshToken("y0");
  const bobToken = freshToken("y1");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);

  await reportStudyStats(env, aliceToken, 1_800, "2026-09-03");

  const bobsFriends = await friends(env, bobToken);
  assert.equal(bobsFriends[0].todayStudySeconds, 1_800);
  assert.equal(bobsFriends[0].studyDate, "2026-09-03");

  // Bob himself never reported anything, so Alice sees zero for him.
  const alicesFriends = await friends(env, aliceToken);
  assert.equal(alicesFriends[0].todayStudySeconds, 0);
  assert.equal(alicesFriends[0].studyDate, null);
});

// Regression coverage for "a friend's displayed name never updates after
// they rename themselves": friends() used to return the name snapshotted at
// accept time, frozen forever after.
test("friends() reports a friend's current name, not the one snapshotted when they were accepted", async () => {
  const env = environment();
  const aliceToken = freshToken("y6");
  const bobToken = freshToken("y7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);

  assert.equal((await friends(env, bobToken))[0].name, "Alice");

  await registerUser(env, aliceToken, "Alice (renamed)");

  assert.equal((await friends(env, bobToken))[0].name, "Alice (renamed)");
});

test("study stats reported after becoming friends are still picked up live", async () => {
  const env = environment();
  const aliceToken = freshToken("y2");
  const bobToken = freshToken("y3");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);

  assert.equal((await friends(env, bobToken))[0].todayStudySeconds, 0);

  await reportStudyStats(env, aliceToken, 900, "2026-09-03");
  assert.equal((await friends(env, bobToken))[0].todayStudySeconds, 900);

  await reportStudyStats(env, aliceToken, 2_400, "2026-09-03");
  assert.equal((await friends(env, bobToken))[0].todayStudySeconds, 2_400);
});

test("invalid study stats are ignored rather than stored", async () => {
  const env = environment();
  const aliceToken = freshToken("y4");
  const bobToken = freshToken("y5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);

  for (const [seconds, date] of [
    [-1, "2026-09-03"],
    [90_000, "2026-09-03"],
    [1_000, "not-a-date"],
    [Number.NaN, "2026-09-03"],
  ]) {
    const response = await reportStudyStats(env, aliceToken, seconds, date);
    assert.equal(response.status, 200);
  }

  assert.equal((await friends(env, bobToken))[0].todayStudySeconds, 0);
});

// Regression coverage for "accept and reject racing the same pending request
// can leave an inconsistent state": firing both at once for the same request
// must never let both succeed, and must never leave one side thinking
// they're friends while the other doesn't.
test("accept and reject racing the same pending request never both succeed and never disagree about the outcome", async () => {
  const env = environment();
  const aliceToken = freshToken("i4");
  const bobToken = freshToken("i5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);

  const [acceptResponse, rejectResponse] = await Promise.all([
    acceptRequest(env, bobToken, alice.code),
    rejectRequest(env, bobToken, alice.code),
  ]);

  assert.deepEqual(
    [acceptResponse.status, rejectResponse.status].sort(),
    [200, 404],
    "exactly one of accept/reject must win; the loser must find the request already resolved"
  );

  const bobsFriends = await friends(env, bobToken);
  const alicesFriends = await friends(env, aliceToken);
  const bobHasAlice = bobsFriends.some(item => item.code === alice.code);
  const aliceHasBob = alicesFriends.some(item => item.code === bob.code);
  assert.equal(bobHasAlice, aliceHasBob, "both sides must agree on whether the friendship exists");
  assert.equal(bobHasAlice, acceptResponse.status === 200, "the friendship must exist exactly when accept was the winner");
  assert.deepEqual(await incomingRequests(env, bobToken), [], "the pending request must be gone either way");
});

// Regression coverage for "the friends list is silently truncated at 500":
// accepting a 501st friend must not silently evict an existing friendship —
// it should be rejected outright, leaving the existing 500 untouched.
test("accepting a request when already at the 500-friend cap is rejected instead of evicting an existing friend", async () => {
  const env = environment();
  const aliceToken = freshToken("i2");
  const bobToken = freshToken("i3");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  const bobKey = await env.STUDIQUO_DATA.get(`chat:code:${bob.code}`);
  const bobRecord = await env.STUDIQUO_DATA.get(`chat:user:${bobKey}`, "json");
  const oldestFriend = { code: "OLDEST1", name: "Oldest Friend", roomID: "room-oldest" };
  bobRecord.friends = [oldestFriend, ...Array.from({ length: 499 }, (_, i) => ({
    code: `FRIEND${i}`, name: `Friend ${i}`, roomID: `room-${i}`,
  }))];
  await env.STUDIQUO_DATA.put(`chat:user:${bobKey}`, JSON.stringify(bobRecord));

  await addFriend(env, aliceToken, bob.code);
  const response = await acceptRequest(env, bobToken, alice.code);

  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /full/i);

  const bobsFriends = await friends(env, bobToken);
  assert.equal(bobsFriends.length, 500);
  assert.ok(bobsFriends.some(item => item.code === "OLDEST1"), "the existing oldest friend must not have been evicted");
  assert.ok(!bobsFriends.some(item => item.code === alice.code), "the new friend must not have been added past the cap");
});

test("accepting a request that was never sent returns 404 and creates no friendship", async () => {
  const env = environment();
  const aliceToken = freshToken("k");
  const bobToken = freshToken("l");
  const alice = await registerUser(env, aliceToken, "Alice");
  await registerUser(env, bobToken, "Bob");

  const response = await acceptRequest(env, bobToken, alice.code);
  assert.equal(response.status, 404);
  assert.deepEqual(await friends(env, bobToken), []);
  assert.deepEqual(await friends(env, aliceToken), []);
});

test("accepting your own code is rejected with a specific message, not a generic not-found", async () => {
  const env = environment();
  const aliceToken = freshToken("k2");
  const alice = await registerUser(env, aliceToken, "Alice");

  const response = await acceptRequest(env, aliceToken, alice.code);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /cannot accept a request from yourself/i);
});

test("rejecting a pending request clears it without creating a friendship", async () => {
  const env = environment();
  const aliceToken = freshToken("m");
  const bobToken = freshToken("n");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);

  const response = await rejectRequest(env, bobToken, alice.code);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "rejected" });

  assert.deepEqual(await incomingRequests(env, bobToken), []);
  assert.deepEqual(await friends(env, bobToken), []);
  assert.deepEqual(await friends(env, aliceToken), []);
});

test("rejecting a request that does not exist returns 404", async () => {
  const env = environment();
  const bobToken = freshToken("o");
  await registerUser(env, bobToken, "Bob");

  const response = await rejectRequest(env, bobToken, "NOSUCH2");
  assert.equal(response.status, 404);
});

test("after acceptance, both friends can actually send and read messages in their room", async () => {
  const env = environment();
  const aliceToken = freshToken("p");
  const bobToken = freshToken("q");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "Hi Bob")).json();
  assert.equal(sent.text, "Hi Bob");
  assert.equal(sent.isMine, true);

  const bobsView = await (await readMessages(env, bobToken, roomID)).json();
  assert.equal(bobsView.length, 1);
  assert.equal(bobsView[0].text, "Hi Bob");
  assert.equal(bobsView[0].isMine, false);

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].isMine, true);
});

// Regression coverage for "canceling a message only hides it on the
// sender's own screen": retracting a message must actually clear it
// server-side, so every reader of the room — not just the sender's own
// device — stops seeing the original content.

test("canceling a message clears its text for both the sender and the recipient", async () => {
  const env = environment();
  const aliceToken = freshToken("cx1");
  const bobToken = freshToken("cx2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "oops, wrong chat")).json();
  const cancelResponse = await cancelMessage(env, aliceToken, roomID, sent.id);
  assert.equal(cancelResponse.status, 200);
  assert.equal((await cancelResponse.json()).status, "canceled");

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].text, "");
  assert.equal(alicesView[0].isCanceled, true);

  const bobsView = await (await readMessages(env, bobToken, roomID)).json();
  assert.equal(bobsView[0].text, "", "the recipient must not still see the original text");
  assert.equal(bobsView[0].isCanceled, true);
});

test("only the original sender can cancel their own message", async () => {
  const env = environment();
  const aliceToken = freshToken("cx3");
  const bobToken = freshToken("cx4");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "Alice's message")).json();
  const bobsAttempt = await cancelMessage(env, bobToken, roomID, sent.id);
  assert.equal(bobsAttempt.status, 403);

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].text, "Alice's message", "an unauthorized cancel attempt must not have any effect");
});

test("someone outside the room cannot cancel a message in it", async () => {
  const env = environment();
  const aliceToken = freshToken("cx5");
  const bobToken = freshToken("cx6");
  const eveToken = freshToken("cx7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "private")).json();
  const evesAttempt = await cancelMessage(env, eveToken, roomID, sent.id);
  assert.equal(evesAttempt.status, 403);
});

test("canceling a nonexistent message id returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("cx8");
  const bobToken = freshToken("cx9");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const response = await cancelMessage(env, aliceToken, accepted.roomID, 999);
  assert.equal(response.status, 404);
});

// Regression coverage for "same-text reconciliation could mismatch order":
// the sender's own client needs a way to match its optimistic local message
// to its confirmed server echo by exact identity, not by guessing from text
// content — which breaks down as soon as two in-flight messages share the
// same text. `clientMessageID` is an opaque token the client attaches to a
// send and gets back unchanged on every future read of that same message.

test("clientMessageID round-trips through send and later reads of the same message", async () => {
  const env = environment();
  const aliceToken = freshToken("cm1");
  const bobToken = freshToken("cm2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "hi", "local-token-abc")).json();
  assert.equal(sent.clientMessageID, "local-token-abc");

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].clientMessageID, "local-token-abc");
});

test("two messages with identical text keep their own distinct clientMessageID, in send order", async () => {
  const env = environment();
  const aliceToken = freshToken("cm3");
  const bobToken = freshToken("cm4");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  await sendMessage(env, aliceToken, roomID, "hi", "first");
  await sendMessage(env, aliceToken, roomID, "hi", "second");

  const view = await (await readMessages(env, aliceToken, roomID)).json();
  assert.deepEqual(view.map(item => item.clientMessageID), ["first", "second"]);
});

test("a message sent with no clientMessageID reads back with a null one, not an error", async () => {
  const env = environment();
  const aliceToken = freshToken("cm5");
  const bobToken = freshToken("cm6");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "no token here")).json();
  assert.equal(sent.clientMessageID, null);
  const view = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(view[0].clientMessageID, null);
});

// Regression coverage for "an attachment can't be opened by anyone but the
// sender": an attachment previously only ever carried the sender's local
// file path or local database id — meaningless off the sender's own device.
// The actual bytes must now be retrievable by the other participant too.

test("an attachment uploaded by one friend can be downloaded by the other, with the right bytes and content type", async () => {
  const env = environment();
  const aliceToken = freshToken("z10");
  const bobToken = freshToken("z11");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const original = Buffer.from("this is a fake jpeg", "utf8");
  const uploadResponse = await uploadAttachment(env, aliceToken, roomID, "image/jpeg", original.toString("base64"));
  assert.equal(uploadResponse.status, 201);
  const { id } = await uploadResponse.json();
  assert.ok(id);

  const downloadResponse = await downloadAttachment(env, bobToken, roomID, id);
  assert.equal(downloadResponse.status, 200);
  assert.equal(downloadResponse.headers.get("content-type"), "image/jpeg");
  const downloaded = Buffer.from(await downloadResponse.arrayBuffer());
  assert.ok(downloaded.equals(original), "the recipient must get back the exact bytes the sender uploaded");

  // The sender can also fetch their own upload back (e.g. after reinstalling).
  const selfDownload = await downloadAttachment(env, aliceToken, roomID, id);
  assert.equal(selfDownload.status, 200);
});

test("someone outside the friendship cannot upload to or download from the room", async () => {
  const env = environment();
  const aliceToken = freshToken("z12");
  const bobToken = freshToken("z13");
  const eveToken = freshToken("z14");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const uploadAsEve = await uploadAttachment(env, eveToken, roomID, "image/jpeg", Buffer.from("x").toString("base64"));
  assert.equal(uploadAsEve.status, 403);

  const legitUpload = await uploadAttachment(env, aliceToken, roomID, "image/jpeg", Buffer.from("x").toString("base64"));
  const { id } = await legitUpload.json();
  const downloadAsEve = await downloadAttachment(env, eveToken, roomID, id);
  assert.equal(downloadAsEve.status, 403);
});

test("an oversized or invalid-content-type attachment is rejected with 400", async () => {
  const env = environment();
  const aliceToken = freshToken("z15");
  const bobToken = freshToken("z16");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const badContentType = await uploadAttachment(env, aliceToken, roomID, "not-a-mime-type", Buffer.from("x").toString("base64"));
  assert.equal(badContentType.status, 400);

  const tooLarge = Buffer.alloc(4 * 1024 * 1024, 1).toString("base64");
  const oversized = await uploadAttachment(env, aliceToken, roomID, "image/jpeg", tooLarge);
  assert.equal(oversized.status, 400);
});

test("downloading a nonexistent attachment id returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("z17");
  const bobToken = freshToken("z18");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const response = await downloadAttachment(env, aliceToken, accepted.roomID, "00000000-0000-4000-8000-000000000000");
  assert.equal(response.status, 404);
});

// Regression coverage for "attachment storage has no expiry and grows
// forever": there's no cron/alarm wired up for a room, so cleanup is
// piggybacked onto every new upload instead.

test("an attachment past the retention window is purged the next time something is uploaded to the room", async () => {
  const env = environment();
  const aliceToken = freshToken("ret1");
  const bobToken = freshToken("ret2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const old = await (await uploadAttachment(env, aliceToken, roomID, "image/jpeg", Buffer.from("old").toString("base64"))).json();
  await env.CHAT_ROOM.getByName(roomID)._setAttachmentCreatedAtForTesting(old.id, Date.now() - 91 * 24 * 60 * 60 * 1000);

  // An unrelated second upload is what triggers the opportunistic sweep.
  await uploadAttachment(env, aliceToken, roomID, "image/jpeg", Buffer.from("new").toString("base64"));

  const response = await downloadAttachment(env, aliceToken, roomID, old.id);
  assert.equal(response.status, 404);
});

test("an attachment well within the retention window survives another upload", async () => {
  const env = environment();
  const aliceToken = freshToken("ret3");
  const bobToken = freshToken("ret4");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const recent = await (await uploadAttachment(env, aliceToken, roomID, "image/jpeg", Buffer.from("recent").toString("base64"))).json();
  await uploadAttachment(env, aliceToken, roomID, "image/jpeg", Buffer.from("new").toString("base64"));

  const response = await downloadAttachment(env, aliceToken, roomID, recent.id);
  assert.equal(response.status, 200);
});

// Regression coverage for "an out-of-range after value crashes with 500":
// Number("1e400") and friends parse to Infinity, which SQLite's bind used to
// reject with an uncaught exception. Every one of these must fall back to a
// normal, successful response instead.
test("GET messages tolerates a malformed after value instead of 500ing", async () => {
  const env = environment();
  const aliceToken = freshToken("p2");
  const bobToken = freshToken("q2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;
  await sendMessage(env, aliceToken, roomID, "Hi Bob");

  for (const badAfter of ["1e400", "Infinity", "-5", "1.5", "not-a-number", "9".repeat(400)]) {
    const response = await readMessagesWithAfter(env, bobToken, roomID, badAfter);
    assert.equal(response.status, 200, `expected 200 for after=${badAfter}`);
    const messages = await response.json();
    assert.equal(messages.length, 1, `expected the one message to still come back for after=${badAfter}`);
  }
});

test("a request that was only sent, not yet accepted, has no working room", async () => {
  const env = environment();
  const aliceToken = freshToken("r");
  const bobToken = freshToken("s");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  await addFriend(env, aliceToken, bob.code);

  const guessedRoomID = "a".repeat(64);
  const response = await sendMessage(env, aliceToken, guessedRoomID, "too early");
  assert.equal(response.status, 403);
  assert.match((await response.json()).error, /not a participant/i);
});

test("someone outside the friendship cannot read or send in the room", async () => {
  const env = environment();
  const aliceToken = freshToken("t");
  const bobToken = freshToken("u");
  const eveToken = freshToken("v");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");

  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const readAttempt = await readMessages(env, eveToken, accepted.roomID);
  assert.equal(readAttempt.status, 403);

  const sendAttempt = await sendMessage(env, eveToken, accepted.roomID, "let me in");
  assert.equal(sendAttempt.status, 403);
});

// Regression coverage for "friend codes can be brute-forced": the 200/404
// split on a guessed code must not be callable an unlimited number of times.

test("POST /api/chat/friends allows up to 5 attempts per minute, then 429s", async () => {
  const env = environment();
  const aliceToken = freshToken("z1");
  await registerUser(env, aliceToken, "Alice");

  for (let i = 0; i < 5; i++) {
    const response = await addFriend(env, aliceToken, `NOSUCH${i}`);
    assert.equal(response.status, 404);
  }
  const sixth = await addFriend(env, aliceToken, "NOSUCH5");
  assert.equal(sixth.status, 429);
});

test("one caller's exhausted friend-add limit does not affect a different caller", async () => {
  const env = environment();
  const aliceToken = freshToken("z2");
  const bobToken = freshToken("z3");
  await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  for (let i = 0; i < 5; i++) {
    await addFriend(env, aliceToken, `NOSUCH${i}`);
  }
  assert.equal((await addFriend(env, aliceToken, "NOSUCH9")).status, 429);

  const bobsAttempt = await addFriend(env, bobToken, bob.code);
  assert.equal(bobsAttempt.status, 400); // self-add, but proves Bob wasn't rate limited
});

// Regression coverage for "no rate limiting on sendMessage": a single
// compromised or misbehaving client could otherwise flood a room (and the
// ChatRoom Durable Object's storage) with unlimited messages.

test("POST /api/chat/rooms/:id/messages allows up to 30 per minute, then 429s", async () => {
  const env = environment();
  const aliceToken = freshToken("z4");
  const bobToken = freshToken("z5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  for (let i = 0; i < 30; i++) {
    const response = await sendMessage(env, aliceToken, accepted.roomID, `message ${i}`);
    assert.equal(response.status, 200);
  }
  const overLimit = await sendMessage(env, aliceToken, accepted.roomID, "one too many");
  assert.equal(overLimit.status, 429);
});

test("one caller's exhausted message-send limit does not affect a different caller", async () => {
  const env = environment();
  const aliceToken = freshToken("z6");
  const bobToken = freshToken("z7");
  const eveToken = freshToken("z8");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  const eve = await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const aliceAndBob = await (await acceptRequest(env, bobToken, alice.code)).json();
  await addFriend(env, aliceToken, eve.code);
  const aliceAndEve = await (await acceptRequest(env, eveToken, alice.code)).json();

  for (let i = 0; i < 30; i++) {
    await sendMessage(env, aliceToken, aliceAndBob.roomID, `message ${i}`);
  }
  assert.equal((await sendMessage(env, aliceToken, aliceAndBob.roomID, "one too many")).status, 429);

  const eveSideAttempt = await sendMessage(env, aliceToken, aliceAndEve.roomID, "still limited: same caller");
  assert.equal(eveSideAttempt.status, 429, "the limit is keyed by caller, not by room");

  const bobsOwnAttempt = await sendMessage(env, bobToken, aliceAndBob.roomID, "Bob is unaffected");
  assert.equal(bobsOwnAttempt.status, 200);
});

// Regression coverage for "the code parameter isn't format-checked on the
// server": a malformed code must be rejected with 400 before it ever reaches
// a KV lookup keyed on it — not just trimmed/uppercased and passed through.

test("POST /api/chat/friends rejects a malformed code with 400 instead of treating it as not-found", async () => {
  const env = environment();
  const aliceToken = freshToken("m0");
  await registerUser(env, aliceToken, "Alice");

  for (const badCode of ["", "AB", "has-a-dash", "TOOLONG".repeat(10), "emoji🙂code"]) {
    const response = await addFriend(env, aliceToken, badCode);
    assert.equal(response.status, 400, `expected 400 for code ${JSON.stringify(badCode)}`);
    assert.match((await response.json()).error, /invalid/i);
  }
});

test("POST /api/chat/friends/requests/accept rejects a malformed code with 400", async () => {
  const env = environment();
  const bobToken = freshToken("m1");
  await registerUser(env, bobToken, "Bob");

  const response = await acceptRequest(env, bobToken, "no");
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /invalid/i);
});

test("POST /api/chat/friends/requests/reject rejects a malformed code with 400", async () => {
  const env = environment();
  const bobToken = freshToken("m2");
  await registerUser(env, bobToken, "Bob");

  const response = await rejectRequest(env, bobToken, "no");
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /invalid/i);
});

test("an oversized code cannot reach the KV lookup — it is rejected with 400, not a 500 from a too-long key", async () => {
  const env = environment();
  const aliceToken = freshToken("m3");
  await registerUser(env, aliceToken, "Alice");

  const response = await addFriend(env, aliceToken, "X".repeat(5_000));
  assert.equal(response.status, 400);
});

test("a well-formed but unregistered code still reports not-found, unaffected by the format check", async () => {
  const env = environment();
  const aliceToken = freshToken("m4");
  await registerUser(env, aliceToken, "Alice");

  const response = await addFriend(env, aliceToken, "NOSUCH9");
  assert.equal(response.status, 404);
});
