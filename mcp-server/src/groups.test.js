import assert from "node:assert/strict";
import test from "node:test";
import { handleGroupRoutes } from "./groups.js";

// chat.test.js covers groups end to end through the Worker. These call
// handleGroupRoutes directly with stubs for the cases that need no real
// chat room: routing boundaries and input validation.

const ROOM = "a".repeat(64);

function makeEnv({ user = null, codes = {}, rateAllowed = true, room = {}, registry = {} } = {}) {
  const calls = [];
  return {
    calls,
    STUDIQUO_DATA: {
      async get(key, type) {
        if (key.startsWith("chat:user:")) return user && type === "json" ? user : null;
        if (key.startsWith("chat:code:")) return codes[key.slice("chat:code:".length)] ?? null;
        return null;
      },
      async put() {},
    },
    RATE_LIMIT_CHAT_GROUP_ACTION: { async limit() { return { success: rateAllowed }; } },
    RATE_LIMIT_CHAT_ATTACHMENT_UPLOAD: { async limit() { return { success: rateAllowed }; } },
    CHAT_ROOM: { getByName: () => room },
    USER_REGISTRY: { getByName: () => registry },
  };
}

function call(path, { method = "GET", body, env = makeEnv() } = {}) {
  const url = new URL(`https://example.test${path}`);
  const request = new Request(url, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return handleGroupRoutes(url, request, env, "me", undefined);
}

async function status(promise) {
  const response = await promise;
  return { status: response.status, body: await response.json() };
}

test("paths outside the group routes return null so chat.js can continue", async () => {
  assert.equal(await call("/api/chat/friends"), null);
  assert.equal(await call("/api/chat/group"), null);
});

test("unmatched group paths and methods return null", async () => {
  assert.equal(await call("/api/chat/groups", { method: "DELETE" }), null);
  assert.equal(await call(`/api/chat/groups/${ROOM}/unknown`, { method: "POST" }), null);
  assert.equal(await call("/api/chat/groups/not-hex/invites", { method: "POST", body: {} }), null);
  assert.equal(await call(`/api/chat/groups/${"A".repeat(64)}`, { method: "PATCH", body: { name: "x" } }), null);
});

test("GET group-invites returns an empty list for a user with none or no record", async () => {
  assert.deepEqual(await status(call("/api/chat/group-invites", { env: makeEnv({ user: { incomingGroupInvites: [] } }) })), { status: 200, body: [] });
  assert.deepEqual(await status(call("/api/chat/group-invites")), { status: 200, body: [] });
});

test("POST /groups validates name and member codes before touching anything", async () => {
  const user = { code: "ME12345", name: "Me", friends: [{ code: "FRIEND1", name: "F" }] };
  const env = makeEnv({ user });
  assert.equal((await status(call("/api/chat/groups", { method: "POST", body: { name: "   " }, env }))).status, 400);
  assert.equal((await status(call("/api/chat/groups", { method: "POST", body: {}, env }))).status, 400);
  const badCode = await status(call("/api/chat/groups", { method: "POST", body: { name: "G", memberCodes: ["abc!"] }, env }));
  assert.deepEqual(badCode, { status: 400, body: { error: "Invalid member code." } });
  const tooShort = await status(call("/api/chat/groups", { method: "POST", body: { name: "G", memberCodes: ["ABC"] }, env }));
  assert.equal(tooShort.status, 400);
});

test("POST /groups rejects an unregistered caller and a non-friend invitee", async () => {
  const noUser = await status(call("/api/chat/groups", { method: "POST", body: { name: "G", memberCodes: [] } }));
  assert.deepEqual(noUser, { status: 400, body: { error: "Register with the server before creating a group." } });
  const env = makeEnv({ user: { code: "ME12345", name: "Me", friends: [] } });
  const stranger = await status(call("/api/chat/groups", { method: "POST", body: { name: "G", memberCodes: ["STRANGER"] }, env }));
  assert.deepEqual(stranger, { status: 400, body: { error: "You can only invite your own friends." } });
});

test("POST /groups returns 429 when rate limited, before reading the body", async () => {
  const env = makeEnv({ rateAllowed: false });
  const result = await status(call("/api/chat/groups", { method: "POST", body: { name: "G" }, env }));
  assert.equal(result.status, 429);
});

test("invite route validates the friend code and ownership", async () => {
  const env = makeEnv({ user: { code: "ME12345", name: "Me", friends: [] } });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "!" }, env })),
    { status: 400, body: { error: "Invalid code." } },
  );
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "friend1" }, env })),
    { status: 400, body: { error: "You can only invite your own friends." } },
  );
});

test("invite route maps room errors and a missing friend record", async () => {
  const user = { code: "ME12345", name: "Me", friends: [{ code: "FRIEND1" }] };
  const forbidden = makeEnv({ user, room: { async groupInfo() { throw new Error("Forbidden"); } } });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "FRIEND1" }, env: forbidden }))).status, 403);

  const notAGroup = makeEnv({ user, room: { async groupInfo() { throw new Error("NotAGroup"); } } });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "FRIEND1" }, env: notAGroup }))).status, 400);

  const gone = makeEnv({ user, room: { async groupInfo() { return { name: "G", members: [] }; } } });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "FRIEND1" }, env: gone })),
    { status: 404, body: { error: "Friend not found." } },
  );
});

test("invite route rejects an existing member and a full group", async () => {
  const user = { code: "ME12345", name: "Me", friends: [{ code: "FRIEND1" }] };
  const member = makeEnv({
    user,
    codes: { FRIEND1: "friend-key" },
    room: { async groupInfo() { return { name: "G", members: [{ key: "friend-key" }] }; } },
  });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "FRIEND1" }, env: member })),
    { status: 400, body: { error: "Already a member of this group." } },
  );
  const full = makeEnv({
    user,
    codes: { FRIEND1: "friend-key" },
    room: { async groupInfo() { return { name: "G", members: Array.from({ length: 50 }, (_, i) => ({ key: `k${i}` })) }; } },
  });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites`, { method: "POST", body: { code: "FRIEND1" }, env: full })),
    { status: 400, body: { error: "This group is full." } },
  );
});

test("accept and reject return 404 when there is no such invitation", async () => {
  const registry = { async resolveIncomingGroupInvite() { return { status: "not_found" }; } };
  const env = makeEnv({ registry });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites/accept`, { method: "POST", env })),
    { status: 404, body: { error: "Invitation not found." } },
  );
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites/reject`, { method: "POST", env })),
    { status: 404, body: { error: "Invitation not found." } },
  );
});

test("reject reports rejected without touching the chat room", async () => {
  const registry = { async resolveIncomingGroupInvite(_k, action) { return { status: "rejected", action }; } };
  const env = makeEnv({ registry, room: new Proxy({}, { get() { throw new Error("room must not be used"); } }) });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/invites/reject`, { method: "POST", env })),
    { status: 200, body: { status: "rejected" } },
  );
});

test("accept restores the invite and returns the mapped error when joining fails", async () => {
  const undone = [];
  const registry = {
    async resolveIncomingGroupInvite() {
      return { status: "accepted", invite: { name: "G", inviterCode: "ALICE22", inviterName: "Alice" } };
    },
    async undoAcceptedGroupInvite(...args) { undone.push(args); },
  };
  const room = { async addParticipant() { throw new Error("GroupFull"); } };
  const env = makeEnv({ user: { code: "ME12345", name: "Me" }, room, registry });
  const result = await status(call(`/api/chat/groups/${ROOM}/invites/accept`, { method: "POST", env }));
  assert.deepEqual(result, { status: 400, body: { error: "This group is full." } });
  assert.deepEqual(undone, [["me", ROOM, "G", "ALICE22", "Alice"]]);
});

test("accept lets an unexpected room error propagate", async () => {
  const registry = { async resolveIncomingGroupInvite() { return { status: "accepted", invite: {} }; } };
  const room = { async addParticipant() { throw new Error("boom"); } };
  const env = makeEnv({ user: { code: "ME12345", name: "Me" }, room, registry });
  await assert.rejects(call(`/api/chat/groups/${ROOM}/invites/accept`, { method: "POST", env }), /boom/);
});

test("rename validates the name and maps room errors", async () => {
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}`, { method: "PATCH", body: { name: "  " } })),
    { status: 400, body: { error: "Group name is required." } },
  );
  const forbidden = makeEnv({ room: { async renameRoom() { throw new Error("Forbidden"); } } });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}`, { method: "PATCH", body: { name: "New" }, env: forbidden }))).status, 403);
  const invalid = makeEnv({ room: { async renameRoom() { throw new Error("InvalidName"); } } });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}`, { method: "PATCH", body: { name: "New" }, env: invalid }))).status, 400);
});

test("rename trims and caps the name at 80 characters", async () => {
  let received;
  const env = makeEnv({ room: { async renameRoom(_key, name) { received = name; return { status: "renamed", name }; } } });
  await call(`/api/chat/groups/${ROOM}`, { method: "PATCH", body: { name: `  ${"x".repeat(120)}  ` }, env });
  assert.equal(received.length, 80);
});

test("an unexpected rename error propagates instead of being swallowed", async () => {
  const env = makeEnv({ room: { async renameRoom() { throw new Error("boom"); } } });
  await assert.rejects(call(`/api/chat/groups/${ROOM}`, { method: "PATCH", body: { name: "New" }, env }), /boom/);
});

test("member removal: unknown code is 404, room errors are mapped, success updates the target's record", async () => {
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/members/NOBODY22`, { method: "DELETE" })),
    { status: 404, body: { error: "Member not found." } },
  );
  const forbidden = makeEnv({ codes: { TARGET22: "target" }, room: { async removeParticipant() { throw new Error("Forbidden"); } } });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/members/TARGET22`, { method: "DELETE", env: forbidden }))).status, 403);

  const removed = [];
  const ok = makeEnv({
    codes: { TARGET22: "target" },
    room: { async removeParticipant(caller, target) { removed.push(["room", caller, target]); } },
    registry: { async removeGroup(key, roomID) { removed.push(["registry", key, roomID]); } },
  });
  assert.deepEqual(
    await status(call(`/api/chat/groups/${ROOM}/members/TARGET22`, { method: "DELETE", env: ok })),
    { status: 200, body: { status: "removed" } },
  );
  assert.deepEqual(removed, [["room", "me", "target"], ["registry", "target", ROOM]]);
});

test("avatar upload validates content type, emptiness and size after the membership check", async () => {
  const room = { async groupInfo() { return { name: "G", members: [] }; } };
  const env = makeEnv({ room });
  const upload = body => status(call(`/api/chat/groups/${ROOM}/avatar`, { method: "POST", body, env }));
  assert.equal((await upload({ contentType: "image/gif", data: "AAAA" })).status, 400);
  assert.equal((await upload({ contentType: "image/png", data: "" })).status, 400);
  assert.equal((await upload({ contentType: "image/png" })).status, 400);
  assert.equal((await upload({ contentType: "image/png", data: "A".repeat(400_100) })).status, 400);
});

test("avatar upload and download both reject non-members with 403 and rate limiting with 429", async () => {
  const room = { async groupInfo() { throw new Error("Forbidden"); } };
  const env = makeEnv({ room });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/avatar`, { method: "POST", body: { contentType: "image/png", data: "AAAA" }, env }))).status, 403);
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/avatar`, { env }))).status, 403);
  const limited = makeEnv({ rateAllowed: false });
  assert.equal((await status(call(`/api/chat/groups/${ROOM}/avatar`, { method: "POST", body: {}, env: limited }))).status, 429);
});

test("GET /groups skips groups the caller no longer belongs to and propagates other errors", async () => {
  const user = { groups: [{ roomID: ROOM }] };
  const forbidden = makeEnv({ user, room: { async groupInfo() { throw new Error("Forbidden"); } } });
  assert.deepEqual(await status(call("/api/chat/groups", { env: forbidden })), { status: 200, body: [] });
  const broken = makeEnv({ user, room: { async groupInfo() { throw new Error("boom"); } } });
  await assert.rejects(call("/api/chat/groups", { env: broken }), /boom/);
});
