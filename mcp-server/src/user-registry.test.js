import assert from "node:assert/strict";
import test from "node:test";
import { register } from "node:module";

// Same technique as mcp-inbox.test.js: shim the Workers-only
// "cloudflare:workers" import so the real UserRegistry class runs under
// `node --test`. (chat.test.js drives a hand-written mirror of this class;
// these tests pin the real one.)
register(
  "data:text/javascript," + encodeURIComponent(`
    export function resolve(specifier, context, next) {
      if (specifier === "cloudflare:workers") return { url: "cloudflare-workers-shim:", shortCircuit: true };
      return next(specifier, context);
    }
    export function load(url, context, next) {
      if (url === "cloudflare-workers-shim:") {
        return {
          format: "module",
          shortCircuit: true,
          source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }",
        };
      }
      return next(url, context);
    }
  `),
  import.meta.url
);

const { UserRegistry } = await import("./user-registry.js");

function makeKV() {
  const values = new Map();
  return {
    values,
    async get(key, type) {
      const value = values.get(key) ?? null;
      return type === "json" && value ? JSON.parse(value) : value;
    },
    async put(key, value) { values.set(key, value); },
  };
}

function makeRegistry() {
  const kv = makeKV();
  const storage = new Map();
  const ctx = {
    storage: {
      async get(key) { return storage.get(key); },
      async put(key, value) { storage.set(key, value); },
    },
    async blockConcurrencyWhile(fn) { return fn(); },
  };
  return { registry: new UserRegistry(ctx, { STUDIQUO_DATA: kv }), kv, storage };
}

const userOf = (kv, key) => kv.get(`chat:user:${key}`, "json");

// MARK: resolveChatKey

test("resolveChatKey uses the identity hash for a brand-new user and remembers it", async () => {
  const { registry } = makeRegistry();
  assert.equal(await registry.resolveChatKey("identity", "legacy"), "identity");
  assert.equal(await registry.resolveChatKey("identity", "legacy"), "identity");
});

test("resolveChatKey keeps the legacy token hash when a legacy user record exists", async () => {
  const { registry, kv } = makeRegistry();
  await kv.put("chat:user:legacy", JSON.stringify({ key: "legacy" }));
  assert.equal(await registry.resolveChatKey("identity", "legacy"), "legacy");
});

test("resolveChatKey is sticky: a later legacy record does not change the saved key", async () => {
  const { registry, kv } = makeRegistry();
  assert.equal(await registry.resolveChatKey("identity", "legacy"), "identity");
  await kv.put("chat:user:legacy", JSON.stringify({ key: "legacy" }));
  assert.equal(await registry.resolveChatKey("identity", "legacy"), "identity");
});

// MARK: ensureUser

test("ensureUser creates a user with friend code, link token, and reverse indexes", async () => {
  const { registry, kv } = makeRegistry();
  const user = await registry.ensureUser("k1", "  Alice  ");
  assert.equal(user.name, "Alice");
  assert.match(user.code, /^[A-HJ-NP-Z2-9]{7}$/);
  assert.match(user.linkToken, /^[A-HJ-NP-Z2-9]{7}$/);
  assert.notEqual(user.code, user.linkToken);
  assert.deepEqual(user.friends, []);
  assert.equal(await kv.get(`chat:code:${user.code}`), "k1");
  assert.equal(await kv.get(`chat:linktoken:${user.linkToken}`), "k1");
  assert.deepEqual(await userOf(kv, "k1"), user);
});

test("ensureUser falls back to the default name for blank or missing names and caps length at 80", async () => {
  const { registry } = makeRegistry();
  assert.equal((await registry.ensureUser("a", "   ")).name, "Studiquoユーザー");
  assert.equal((await registry.ensureUser("b", null)).name, "Studiquoユーザー");
  assert.equal((await registry.ensureUser("c", "x".repeat(200))).name.length, 80);
});

test("ensureUser stores bio and study stats on creation", async () => {
  const { registry } = makeRegistry();
  const user = await registry.ensureUser("k1", "A", { seconds: 120, date: "2026-10-16" }, "hello");
  assert.equal(user.bio, "hello");
  assert.equal(user.todayStudySeconds, 120);
  assert.equal(user.studyDate, "2026-10-16");
});

test("ensureUser on an existing user keeps the code, updates a changed name, and ignores blank names", async () => {
  const { registry } = makeRegistry();
  const first = await registry.ensureUser("k1", "Alice");
  const renamed = await registry.ensureUser("k1", "Alicia");
  assert.equal(renamed.code, first.code);
  assert.equal(renamed.linkToken, first.linkToken);
  assert.equal(renamed.name, "Alicia");
  assert.equal((await registry.ensureUser("k1", "   ")).name, "Alicia");
  assert.equal((await registry.ensureUser("k1", undefined)).name, "Alicia");
});

test("ensureUser updates bio and study stats on an existing user, and leaves bio alone when undefined", async () => {
  const { registry } = makeRegistry();
  await registry.ensureUser("k1", "A", null, "first");
  const kept = await registry.ensureUser("k1", "A");
  assert.equal(kept.bio, "first");
  const changed = await registry.ensureUser("k1", "A", { seconds: 5, date: "2026-10-17" }, "second");
  assert.equal(changed.bio, "second");
  assert.equal(changed.todayStudySeconds, 5);
  assert.equal(changed.studyDate, "2026-10-17");
});

test("ensureUser backfills a link token for a user created before invite links existed", async () => {
  const { registry, kv } = makeRegistry();
  await kv.put("chat:user:old", JSON.stringify({ key: "old", name: "Old", code: "ABCDEFG", friends: [] }));
  const user = await registry.ensureUser("old", "Old");
  assert.match(user.linkToken, /^[A-HJ-NP-Z2-9]{7}$/);
  assert.equal(await kv.get(`chat:linktoken:${user.linkToken}`), "old");
  assert.equal((await userOf(kv, "old")).linkToken, user.linkToken);
});

test("two users never get the same friend code", async () => {
  const { registry } = makeRegistry();
  const codes = new Set();
  for (let i = 0; i < 25; i += 1) codes.add((await registry.ensureUser(`k${i}`, "U")).code);
  assert.equal(codes.size, 25);
});

// MARK: friend requests

test("addIncomingRequest records a pending request once and returns the recipient", async () => {
  const { registry, kv } = makeRegistry();
  const bob = await registry.ensureUser("bob", "Bob");
  const first = await registry.addIncomingRequest("bob", "ALICE22", "Alice");
  assert.deepEqual(first, { status: "pending", recipient: { code: bob.code, name: "Bob" } });
  await registry.addIncomingRequest("bob", "ALICE22", "Alice");
  assert.equal((await userOf(kv, "bob")).incomingRequests.length, 1);
});

test("addIncomingRequest reports not_found and already_friends", async () => {
  const { registry } = makeRegistry();
  assert.deepEqual(await registry.addIncomingRequest("ghost", "X", "X"), { status: "not_found" });
  await registry.ensureUser("bob", "Bob");
  await registry.addFriendDirectly("bob", "ALICE22", "Alice", "room");
  assert.deepEqual(await registry.addIncomingRequest("bob", "ALICE22", "Alice"), { status: "already_friends" });
});

test("incoming and outgoing request lists keep only the latest 500", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  for (let i = 0; i < 505; i += 1) {
    await registry.addIncomingRequest("bob", `C${i}`, "n");
    await registry.addOutgoingRequest("bob", `C${i}`, "n");
  }
  const user = await userOf(kv, "bob");
  assert.equal(user.incomingRequests.length, 500);
  assert.equal(user.incomingRequests[0].code, "C5");
  assert.equal(user.outgoingRequests.length, 500);
  assert.equal(user.outgoingRequests.at(-1).code, "C504");
});

test("addOutgoingRequest ignores duplicates and unknown users; removeOutgoingRequest clears one", async () => {
  const { registry, kv } = makeRegistry();
  await registry.addOutgoingRequest("ghost", "X", "X");
  assert.equal(await userOf(kv, "ghost"), null);
  await registry.ensureUser("alice", "Alice");
  await registry.addOutgoingRequest("alice", "BOB2222", "Bob");
  await registry.addOutgoingRequest("alice", "BOB2222", "Bob");
  assert.equal((await userOf(kv, "alice")).outgoingRequests.length, 1);
  await registry.removeOutgoingRequest("alice", "NOPE");
  assert.equal((await userOf(kv, "alice")).outgoingRequests.length, 1);
  await registry.removeOutgoingRequest("alice", "BOB2222");
  assert.deepEqual((await userOf(kv, "alice")).outgoingRequests, []);
  await registry.removeOutgoingRequest("ghost", "X");
});

test("resolveIncomingRequest accept creates a friend and removes the request", async () => {
  const { registry, kv } = makeRegistry();
  const bob = await registry.ensureUser("bob", "Bob");
  await registry.addIncomingRequest("bob", "ALICE22", "Alice");
  const result = await registry.resolveIncomingRequest("bob", "accept", "ALICE22", "Alice", "room-1");
  assert.deepEqual(result, { status: "accepted", friend: { code: bob.code, name: "Bob" } });
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.incomingRequests, []);
  assert.deepEqual(stored.friends, [{ code: "ALICE22", name: "Alice", roomID: "room-1" }]);
});

test("resolveIncomingRequest reject removes the request without adding a friend", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addIncomingRequest("bob", "ALICE22", "Alice");
  assert.equal((await registry.resolveIncomingRequest("bob", "reject", "ALICE22", "Alice", "r")).status, "rejected");
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.incomingRequests, []);
  assert.deepEqual(stored.friends, []);
});

test("resolveIncomingRequest is not_found without a pending request, and a second resolve cannot undo the first", async () => {
  const { registry, kv } = makeRegistry();
  assert.equal((await registry.resolveIncomingRequest("ghost", "accept", "X", "X", "r")).status, "not_found");
  await registry.ensureUser("bob", "Bob");
  assert.equal((await registry.resolveIncomingRequest("bob", "accept", "ALICE22", "Alice", "r")).status, "not_found");
  await registry.addIncomingRequest("bob", "ALICE22", "Alice");
  await registry.resolveIncomingRequest("bob", "accept", "ALICE22", "Alice", "r");
  assert.equal((await registry.resolveIncomingRequest("bob", "reject", "ALICE22", "Alice", "r")).status, "not_found");
  assert.equal((await userOf(kv, "bob")).friends.length, 1);
});

test("friend lists are capped at 500 for accept and addFriendDirectly", async () => {
  const { registry, kv } = makeRegistry();
  const bob = await registry.ensureUser("bob", "Bob");
  const stored = await userOf(kv, "bob");
  stored.friends = Array.from({ length: 500 }, (_, i) => ({ code: `F${i}`, name: "f", roomID: `r${i}` }));
  stored.incomingRequests = [{ code: "NEW", name: "New", requestedAt: 1 }];
  await kv.put("chat:user:bob", JSON.stringify(stored));
  assert.equal((await registry.resolveIncomingRequest("bob", "accept", "NEW", "New", "r")).status, "friends_full");
  assert.equal((await registry.addFriendDirectly("bob", "OTHER", "Other", "r")).status, "friends_full");
  assert.equal((await userOf(kv, "bob")).friends.length, 500);
  assert.equal(bob.name, "Bob");
});

test("addFriendDirectly adds once, then reports already_friends; unknown user is not_found", async () => {
  const { registry, kv } = makeRegistry();
  assert.equal((await registry.addFriendDirectly("ghost", "X", "X", "r")).status, "not_found");
  await registry.ensureUser("bob", "Bob");
  assert.equal((await registry.addFriendDirectly("bob", "ALICE22", "Alice", "r")).status, "added");
  assert.equal((await registry.addFriendDirectly("bob", "ALICE22", "Alice", "r")).status, "already_friends");
  assert.equal((await userOf(kv, "bob")).friends.length, 1);
});

// MARK: removeFriend / confirmFriendship / avatar

test("removeFriend removes the friend and archives a blocked contact once", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addFriendDirectly("bob", "ALICE22", "Alice", "r");
  const blocked = { code: "ALICE22", name: "Alice" };
  assert.equal((await registry.removeFriend("bob", "ALICE22", blocked)).status, "removed");
  await registry.removeFriend("bob", "ALICE22", blocked);
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.friends, []);
  assert.deepEqual(stored.blockedContacts, [blocked]);
  assert.equal((await registry.removeFriend("ghost", "X")).status, "not_found");
});

test("removeFriend without a block only removes the friend and writes nothing for a stranger", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addFriendDirectly("bob", "ALICE22", "Alice", "r");
  await registry.removeFriend("bob", "ALICE22");
  assert.equal((await userOf(kv, "bob")).blockedContacts, undefined);
  await registry.removeFriend("bob", "NOBODY");
  assert.deepEqual((await userOf(kv, "bob")).friends, []);
});

test("confirmFriendship replaces an existing entry instead of duplicating, and can clear the outgoing request", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("alice", "Alice");
  await registry.addOutgoingRequest("alice", "BOB2222", "Bob");
  await registry.confirmFriendship("alice", { code: "BOB2222", name: "Bob", roomID: "r1" }, { clearOutgoing: true });
  await registry.confirmFriendship("alice", { code: "BOB2222", name: "Bobby", roomID: "r2" });
  const stored = await userOf(kv, "alice");
  assert.deepEqual(stored.friends, [{ code: "BOB2222", name: "Bobby", roomID: "r2" }]);
  assert.deepEqual(stored.outgoingRequests, []);
  assert.equal((await registry.confirmFriendship("ghost", { code: "X" })).status, "not_found");
});

test("setAvatarUpdatedAt stores the timestamp; unknown user is not_found", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("alice", "Alice");
  assert.equal((await registry.setAvatarUpdatedAt("alice", 1234)).status, "updated");
  assert.equal((await userOf(kv, "alice")).avatarUpdatedAt, 1234);
  assert.equal((await registry.setAvatarUpdatedAt("ghost", 1)).status, "not_found");
});

// MARK: removeAccountReferences

test("removeAccountReferences scrubs a deleted account from every list and keeps a labelled history entry", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addFriendDirectly("bob", "GONE222", "Gone", "r1");
  await registry.addFriendDirectly("bob", "KEEP222", "Keep", "r2");
  await registry.addIncomingRequest("bob", "GONE222", "Gone");
  await registry.addOutgoingRequest("bob", "GONE222", "Gone");
  await registry.addIncomingGroupInvite("bob", "g1", "G", "GONE222", "Gone");
  await registry.addIncomingGroupInvite("bob", "g2", "G2", "KEEP222", "Keep");

  assert.equal((await registry.removeAccountReferences("bob", "GONE222")).status, "removed");
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.friends.map(f => f.code), ["KEEP222"]);
  assert.deepEqual(stored.incomingRequests, []);
  assert.deepEqual(stored.outgoingRequests, []);
  assert.deepEqual(stored.incomingGroupInvites.map(i => i.roomID), ["g2"]);
  assert.deepEqual(stored.blockedContacts.map(c => ({ code: c.code, name: c.name, deleted: c.deleted })), [
    { code: "GONE222", name: "削除済みユーザー", deleted: true },
  ]);
});

test("removeAccountReferences relabels a previously blocked contact, and ignores strangers and unknown users", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addFriendDirectly("bob", "GONE222", "Gone", "r");
  await registry.removeFriend("bob", "GONE222", { code: "GONE222", name: "Gone" });
  await registry.removeAccountReferences("bob", "GONE222");
  const stored = await userOf(kv, "bob");
  assert.equal(stored.blockedContacts.length, 1);
  assert.equal(stored.blockedContacts[0].deleted, true);

  await registry.removeAccountReferences("bob", "STRANGER");
  assert.equal((await userOf(kv, "bob")).blockedContacts.length, 1);
  assert.equal((await registry.removeAccountReferences("ghost", "X")).status, "not_found");
});

// MARK: group invites

test("addIncomingGroupInvite records a pending invite and rejects duplicates and members", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  assert.deepEqual(await registry.addIncomingGroupInvite("bob", "g1", "Group", "ALICE22", "Alice"), { status: "pending" });
  assert.deepEqual(await registry.addIncomingGroupInvite("bob", "g1", "Group", "ALICE22", "Alice"), { status: "already_pending" });
  const invite = (await userOf(kv, "bob")).incomingGroupInvites[0];
  assert.deepEqual({ ...invite, invitedAt: undefined }, {
    roomID: "g1", name: "Group", inviterCode: "ALICE22", inviterName: "Alice", invitedAt: undefined,
  });

  await registry.addGroupForCreator("bob", "g2");
  assert.deepEqual(await registry.addIncomingGroupInvite("bob", "g2", "Other", "X", "X"), { status: "already_member" });
  assert.deepEqual(await registry.addIncomingGroupInvite("ghost", "g", "G", "X", "X"), { status: "not_found" });
});

test("resolveIncomingGroupInvite accept moves the invite into groups and returns the invite", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addIncomingGroupInvite("bob", "g1", "Group", "ALICE22", "Alice");
  const result = await registry.resolveIncomingGroupInvite("bob", "accept", "g1");
  assert.equal(result.status, "accepted");
  assert.equal(result.invite.inviterName, "Alice");
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.incomingGroupInvites, []);
  assert.deepEqual(stored.groups, [{ roomID: "g1" }]);
});

test("resolveIncomingGroupInvite reject drops the invite without joining; a second resolve is not_found", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addIncomingGroupInvite("bob", "g1", "Group", "ALICE22", "Alice");
  assert.equal((await registry.resolveIncomingGroupInvite("bob", "reject", "g1")).status, "rejected");
  assert.equal((await registry.resolveIncomingGroupInvite("bob", "accept", "g1")).status, "not_found");
  assert.equal((await userOf(kv, "bob")).groups, undefined);
  assert.equal((await registry.resolveIncomingGroupInvite("ghost", "accept", "g1")).status, "not_found");
});

test("undoAcceptedGroupInvite reverses an accept: leaves the group and restores the invite exactly once", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addIncomingGroupInvite("bob", "g1", "Group", "ALICE22", "Alice");
  const { invite } = await registry.resolveIncomingGroupInvite("bob", "accept", "g1");

  assert.equal((await registry.undoAcceptedGroupInvite("bob", "g1", invite.name, invite.inviterCode, invite.inviterName)).status, "restored");
  await registry.undoAcceptedGroupInvite("bob", "g1", invite.name, invite.inviterCode, invite.inviterName);
  const stored = await userOf(kv, "bob");
  assert.deepEqual(stored.groups, []);
  assert.equal(stored.incomingGroupInvites.length, 1);
  assert.equal(stored.incomingGroupInvites[0].roomID, "g1");
  assert.equal((await registry.undoAcceptedGroupInvite("ghost", "g1")).status, "not_found");
});

test("incoming group invites keep only the latest 500", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  for (let i = 0; i < 503; i += 1) await registry.addIncomingGroupInvite("bob", `g${i}`, "G", "A", "A");
  const invites = (await userOf(kv, "bob")).incomingGroupInvites;
  assert.equal(invites.length, 500);
  assert.equal(invites[0].roomID, "g3");
});

test("addGroupForCreator is idempotent; removeGroup removes only that group and tolerates repeats", async () => {
  const { registry, kv } = makeRegistry();
  await registry.ensureUser("bob", "Bob");
  await registry.addGroupForCreator("bob", "g1");
  await registry.addGroupForCreator("bob", "g1");
  await registry.addGroupForCreator("bob", "g2");
  assert.deepEqual((await userOf(kv, "bob")).groups, [{ roomID: "g1" }, { roomID: "g2" }]);
  assert.equal((await registry.removeGroup("bob", "g1")).status, "removed");
  assert.equal((await registry.removeGroup("bob", "g1")).status, "removed");
  assert.deepEqual((await userOf(kv, "bob")).groups, [{ roomID: "g2" }]);
  assert.equal((await registry.removeGroup("ghost", "g")).status, "not_found");
  assert.equal((await registry.addGroupForCreator("ghost", "g")).status, "not_found");
});
