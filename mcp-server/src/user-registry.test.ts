// The real UserRegistry Durable Object. chat.test.ts runs the chat routes against
// a hand-written copy of its logic; these tests run the class itself, so the
// friend, request, block and group bookkeeping that every route relies on is
// checked where it is written.
import assert from "node:assert/strict";
import test from "node:test";
import { register } from "node:module";
import { partialEnv, partialState, partialStorage, type LooseEnv, type Untyped } from "./test-env.ts";

// user-registry.ts extends the real DurableObject from "cloudflare:workers",
// which only exists inside the Workers runtime; stand in for that one import
// (as low-priority-hardening.test.ts does) so the real class runs here.
register(
  "data:text/javascript," + encodeURIComponent(`
    export function resolve(specifier, context, next) {
      if (specifier === "cloudflare:workers") return { url: "cloudflare-workers-shim:", shortCircuit: true };
      return next(specifier, context);
    }
    export function load(url, context, next) {
      if (url === "cloudflare-workers-shim:") {
        return { format: "module", shortCircuit: true,
          source: "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }" };
      }
      return next(url, context);
    }
  `),
  import.meta.url
);

const { UserRegistry } = await import("./user-registry.ts");

function setup() {
  const values = new Map<string, string>();
  const stored = new Map<string, unknown>();
  const puts: string[] = [];
  const env: LooseEnv & { values: Map<string, string>; puts: string[] } = partialEnv({
    values, puts,
    STUDIQUO_DATA: {
      async get(key: string, type?: string) { const v = values.get(key) ?? null; return type === "json" && v ? JSON.parse(v) : v; },
      async put(key: string, value: string) { puts.push(key); values.set(key, value); },
    },
  });
  const storage = partialStorage({
    async get(key: string) { return stored.get(key); },
    async put(key: string, value: unknown) { stored.set(key, value); },
    async delete(key: string) { return stored.delete(key); },
    async deleteAll() { stored.clear(); },
  });
  const registry = new UserRegistry(partialState({ storage, blockConcurrencyWhile: (fn: Untyped) => fn() }), env);
  const record = (key: string) => JSON.parse(values.get(`chat:user:${key}`)!);
  const seed = (key: string, user: Record<string, unknown> = {}) =>
    values.set(`chat:user:${key}`, JSON.stringify({ key, name: "Me", code: `CODE${key}`.toUpperCase(), linkToken: `LINK${key}`.toUpperCase(), friends: [], ...user }));
  return { registry, env, values, puts, record, seed };
}

// ---- ensureUser ----

test("a new account without a name is called the default name; names are trimmed and cut to 80 characters", async () => {
  const { registry } = setup();
  assert.equal((await registry.ensureUser("a", undefined)).name, "Studiquoユーザー");
  assert.equal((await registry.ensureUser("b", "   ")).name, "Studiquoユーザー");
  assert.equal((await registry.ensureUser("c", "  Alice  ")).name, "Alice");
  assert.equal((await registry.ensureUser("d", "あ".repeat(120))).name.length, 80);
});

test("a new account is stored with its code and invite token pointing back to it, and its study stats and bio", async () => {
  const { registry, env, record } = setup();
  const user = await registry.ensureUser("k", "Kei", { seconds: 90, date: "2026-10-21" }, "よろしく");
  assert.equal(env.values.get(`chat:code:${user.code}`), "k");
  assert.equal(env.values.get(`chat:linktoken:${user.linkToken}`), "k");
  assert.deepEqual([record("k").todayStudySeconds, record("k").studyDate, record("k").bio], [90, "2026-10-21", "よろしく"]);
});

test("two new accounts never share a code, even when the first pick is taken", async () => {
  const { registry, env } = setup();
  const codes = new Set<string>();
  for (let i = 0; i < 30; i++) codes.add((await registry.ensureUser(`user${i}`, "x")).code);
  assert.equal(codes.size, 30);
  assert.equal([...env.values.keys()].filter(key => key.startsWith("chat:code:")).length, 30);
});

test("an existing account changes only what was given: a new name, stats or bio; an empty name is ignored", async () => {
  const { registry, record, seed } = setup();
  seed("k", { name: "Old", bio: "b1" });
  await registry.ensureUser("k", "  ");
  assert.equal(record("k").name, "Old", "an empty name never erases the name");
  await registry.ensureUser("k", "New", { seconds: 5, date: "2026-10-22" }, "b2");
  assert.deepEqual([record("k").name, record("k").todayStudySeconds, record("k").bio], ["New", 5, "b2"]);
  await registry.ensureUser("k", "New");
  assert.equal(record("k").bio, "b2", "no bio given leaves the bio alone");
  await registry.ensureUser("k", "New", null, null);
  assert.equal(record("k").bio, null, "null clears it");
});

test("an unchanged account is not written again", async () => {
  const { registry, puts, seed } = setup();
  seed("k", { name: "Same", bio: "b" });
  await registry.ensureUser("k", "Same", null, "b");
  assert.deepEqual(puts, []);
});

test("an account made before invite links existed is given a token, and it points back to the account", async () => {
  const { registry, env, record, seed } = setup();
  seed("old", { linkToken: undefined });
  const user = await registry.ensureUser("old", "Me");
  assert.match(user.linkToken!, /^[A-HJ-NP-Z2-9]{10}$/);
  assert.equal(record("old").linkToken, user.linkToken);
  assert.equal(env.values.get(`chat:linktoken:${user.linkToken}`), "old");
});

test("getUser reads the stored record, or nothing", async () => {
  const { registry, seed } = setup();
  seed("k");
  assert.equal((await registry.getUser("k"))!.key, "k");
  assert.equal(await registry.getUser("nobody"), null);
});

// ---- chat identity and library id ----

test("the chat identity is the old token hash when that account already exists, otherwise the new identity, and it then never changes", async () => {
  const fresh = setup();
  assert.equal(await fresh.registry.resolveChatKey("identity-hash", "legacy-hash"), "identity-hash");
  fresh.seed("legacy-hash");
  assert.equal(await fresh.registry.resolveChatKey("identity-hash", "legacy-hash"), "identity-hash", "decided once");

  const legacy = setup();
  legacy.seed("legacy-hash");
  assert.equal(await legacy.registry.resolveChatKey("identity-hash", "legacy-hash"), "legacy-hash");
  legacy.values.delete("chat:user:legacy-hash");
  assert.equal(await legacy.registry.resolveChatKey("identity-hash", "legacy-hash"), "legacy-hash", "still decided");
});

test("the library id is made once, is 64 hex characters, and is replaced after it is erased", async () => {
  const { registry } = setup();
  const first = await registry.libraryID();
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(await registry.libraryID(), first);
  await registry.eraseLibraryID();
  const second = await registry.libraryID();
  assert.match(second, /^[0-9a-f]{64}$/);
  assert.notEqual(second, first);
});

// ---- friend requests ----

test("a request is recorded once, reports the recipient's own code and name, and is refused for existing friends and unknown people", async () => {
  const { registry, record, seed } = setup();
  seed("r", { name: "Rin", code: "RINCODE1" });
  assert.deepEqual(await registry.addIncomingRequest("nobody", "REQ", "Req"), { status: "not_found" });

  const first = await registry.addIncomingRequest("r", "REQ0001", "Req");
  assert.deepEqual(first, { status: "pending", recipient: { code: "RINCODE1", name: "Rin" } });
  await registry.addIncomingRequest("r", "REQ0001", "Req (renamed)");
  assert.equal(record("r").incomingRequests.length, 1, "asking twice leaves one request");
  assert.equal(record("r").incomingRequests[0].name, "Req", "and the first one is kept");

  seed("s", { friends: [{ code: "FRIEND1", name: "F", roomID: "room" }] });
  assert.deepEqual(await registry.addIncomingRequest("s", "FRIEND1", "F"), { status: "already_friends" });
});

test("only the newest 500 pending requests are kept", async () => {
  const { registry, record, seed } = setup();
  seed("r");
  for (let i = 0; i < 502; i++) await registry.addIncomingRequest("r", `C${i}`, "x");
  const codes = record("r").incomingRequests.map((item: Untyped) => item.code);
  assert.equal(codes.length, 500);
  assert.equal(codes[0], "C2");
  assert.equal(codes.at(-1), "C501");
});

test("an outgoing request is noted once and can be cleared; unknown accounts are ignored", async () => {
  const { registry, record, seed, puts } = setup();
  seed("q");
  await registry.addOutgoingRequest("q", "TO1", "To");
  await registry.addOutgoingRequest("q", "TO1", "To");
  await registry.addOutgoingRequest("q", "TO2", "Two");
  assert.deepEqual(record("q").outgoingRequests.map((item: Untyped) => item.code), ["TO1", "TO2"]);
  await registry.removeOutgoingRequest("q", "TO1");
  assert.deepEqual(record("q").outgoingRequests.map((item: Untyped) => item.code), ["TO2"]);
  const writes = puts.length;
  await registry.removeOutgoingRequest("q", "NOTHERE");
  assert.equal(puts.length, writes, "clearing what isn't there writes nothing");
  await registry.addOutgoingRequest("nobody", "X", "x");
  await registry.removeOutgoingRequest("nobody", "X");
  assert.equal(setup().env.values.size, 0);
});

test("accepting a request makes the friend and removes the request; rejecting removes it and makes no friend", async () => {
  const { registry, record, seed } = setup();
  seed("r", { name: "Rin", code: "RINCODE1", incomingRequests: [{ code: "A1", name: "A" }, { code: "B1", name: "B" }] });
  const rejected = await registry.resolveIncomingRequest("r", "reject", "A1", null, null);
  assert.deepEqual(rejected, { status: "rejected", recipient: { code: "RINCODE1", name: "Rin" } });
  assert.deepEqual([record("r").incomingRequests.map((item: Untyped) => item.code), record("r").friends], [["B1"], []]);

  const accepted = await registry.resolveIncomingRequest("r", "accept", "B1", "Bee", "room-b");
  assert.deepEqual(accepted, { status: "accepted", friend: { code: "RINCODE1", name: "Rin" } });
  assert.deepEqual(record("r").friends, [{ code: "B1", name: "Bee", roomID: "room-b" }]);
  assert.deepEqual(record("r").incomingRequests, []);

  assert.deepEqual(await registry.resolveIncomingRequest("r", "accept", "B1", "Bee", "room-b"), { status: "not_found" }, "answered already");
  assert.deepEqual(await registry.resolveIncomingRequest("nobody", "accept", "B1", "Bee", null), { status: "not_found" });
});

test("accepting when the friend list is full changes nothing; an accepted friend already listed is replaced, not doubled", async () => {
  const { registry, record, seed } = setup();
  const full = Array.from({ length: 500 }, (_, i) => ({ code: `F${i}`, name: "f", roomID: null }));
  seed("r", { friends: full, incomingRequests: [{ code: "NEW", name: "n" }] });
  assert.deepEqual(await registry.resolveIncomingRequest("r", "accept", "NEW", "New", "room"), { status: "friends_full" });
  assert.equal(record("r").friends.length, 500);
  assert.equal(record("r").incomingRequests.length, 1, "the request is still there to retry");

  seed("s", { friends: [{ code: "SAME", name: "old", roomID: "old-room" }], incomingRequests: [{ code: "SAME", name: "s" }] });
  await registry.resolveIncomingRequest("s", "accept", "SAME", "fresh", "new-room");
  assert.deepEqual(record("s").friends, [{ code: "SAME", name: "fresh", roomID: "new-room" }]);
});

test("a friend added by invite link is added once, and not beyond the limit", async () => {
  const { registry, record, seed } = setup();
  seed("k", { name: "Kei", code: "KEICODE1" });
  assert.deepEqual(await registry.addFriendDirectly("nobody", "X", "x", null), { status: "not_found" });
  assert.deepEqual(await registry.addFriendDirectly("k", "ALI1", "Ali", "room-a"), { status: "added", friend: { code: "KEICODE1", name: "Kei" } });
  assert.deepEqual(await registry.addFriendDirectly("k", "ALI1", "Ali", "room-a"), { status: "already_friends", friend: { code: "KEICODE1", name: "Kei" } });
  assert.equal(record("k").friends.length, 1);
  seed("full", { friends: Array.from({ length: 500 }, (_, i) => ({ code: `F${i}`, name: "f" })) });
  assert.deepEqual(await registry.addFriendDirectly("full", "ONE", "one", null), { status: "friends_full" });
});

// ---- removing friends, blocks, deleted accounts ----

test("removing a friend keeps a block record that outlives the friendship, once", async () => {
  const { registry, record, seed, puts } = setup();
  seed("k", { friends: [{ code: "A1", name: "A", roomID: "ra" }, { code: "B1", name: "B", roomID: "rb" }] });
  assert.deepEqual(await registry.removeFriend("nobody", "A1"), { status: "not_found" });
  assert.deepEqual(await registry.removeFriend("k", "A1", { code: "A1", name: "A", roomID: "ra" }), { status: "removed" });
  assert.deepEqual(record("k").friends.map((item: Untyped) => item.code), ["B1"]);
  assert.equal(record("k").blockedContacts.length, 1);
  await registry.removeFriend("k", "A1", { code: "A1", name: "A", roomID: "ra" });
  assert.equal(record("k").blockedContacts.length, 1, "blocking again doesn't list them twice");
  // A block can be recorded for someone who is no longer a friend.
  await registry.removeFriend("k", "GONE", { code: "GONE", name: "g", roomID: null });
  assert.deepEqual(record("k").blockedContacts.map((item: Untyped) => item.code), ["A1", "GONE"]);
  const writes = puts.length;
  await registry.removeFriend("k", "NOT-A-FRIEND");
  assert.equal(puts.length, writes, "removing someone who isn't there, with no block, writes nothing");
});

test("confirming a friendship replaces an older entry for the same person and can clear the outgoing request", async () => {
  const { registry, record, seed } = setup();
  seed("k", { friends: [{ code: "A1", name: "old", roomID: "r0" }], outgoingRequests: [{ code: "A1", name: "A" }, { code: "B1", name: "B" }] });
  assert.deepEqual(await registry.confirmFriendship("k", { code: "A1", name: "new", roomID: "r1" }), { status: "confirmed" });
  assert.deepEqual(record("k").friends, [{ code: "A1", name: "new", roomID: "r1" }]);
  assert.equal(record("k").outgoingRequests.length, 2, "outgoing requests stay unless asked");
  await registry.confirmFriendship("k", { code: "A1", name: "new", roomID: "r1" }, { clearOutgoing: true });
  assert.deepEqual(record("k").outgoingRequests.map((item: Untyped) => item.code), ["B1"]);
  assert.deepEqual(await registry.confirmFriendship("nobody", { code: "X", name: "x" }), { status: "not_found" });
});

test("the avatar's update time is recorded on the account", async () => {
  const { registry, record, seed } = setup();
  seed("k");
  assert.deepEqual(await registry.setAvatarUpdatedAt("k", 1234), { status: "updated" });
  assert.equal(record("k").avatarUpdatedAt, 1234);
  assert.deepEqual(await registry.setAvatarUpdatedAt("nobody", 1), { status: "not_found" });
});

test("when someone deletes their account, a friend or blocked contact stays only as 削除済みユーザー and every request or invite from them goes", async () => {
  const { registry, record, seed } = setup();
  seed("k", {
    friends: [{ code: "GONE", name: "Gone", roomID: "room-g" }, { code: "STAY", name: "Stay", roomID: "room-s" }],
    incomingRequests: [{ code: "GONE", name: "Gone" }, { code: "STAY", name: "Stay" }],
    outgoingRequests: [{ code: "GONE", name: "Gone" }],
    incomingGroupInvites: [{ roomID: "g1", inviterCode: "GONE" }, { roomID: "g2", inviterCode: "STAY" }],
  });
  assert.deepEqual(await registry.removeAccountReferences("k", "GONE"), { status: "removed" });
  const user = record("k");
  assert.deepEqual(user.friends.map((item: Untyped) => item.code), ["STAY"]);
  assert.deepEqual(user.blockedContacts, [{ code: "GONE", name: "削除済みユーザー", roomID: "room-g", deleted: true }]);
  assert.deepEqual(user.incomingRequests.map((item: Untyped) => item.code), ["STAY"]);
  assert.deepEqual(user.outgoingRequests, []);
  assert.deepEqual(user.incomingGroupInvites.map((item: Untyped) => item.roomID), ["g2"]);

  seed("b", { blockedContacts: [{ code: "GONE", name: "Gone", roomID: "rb" }] });
  await registry.removeAccountReferences("b", "GONE");
  assert.deepEqual(record("b").blockedContacts, [{ code: "GONE", name: "削除済みユーザー", roomID: "rb", deleted: true }], "a block stays one entry, marked deleted");

  seed("c", { friends: [{ code: "STAY", name: "Stay" }] });
  await registry.removeAccountReferences("c", "UNKNOWN");
  assert.deepEqual(record("c").blockedContacts, [], "someone who was never a contact leaves no entry behind");
  assert.deepEqual(await registry.removeAccountReferences("nobody", "GONE"), { status: "not_found" });
});

// ---- groups ----

test("a group invitation is listed once, and not at all for a member or for an unknown account", async () => {
  const { registry, record, seed } = setup();
  seed("k", { groups: [{ roomID: "member" }] });
  assert.deepEqual(await registry.addIncomingGroupInvite("nobody", "g1", "G", "INV", "Inviter"), { status: "not_found" });
  assert.deepEqual(await registry.addIncomingGroupInvite("k", "member", "G", "INV", "Inviter"), { status: "already_member" });
  assert.deepEqual(await registry.addIncomingGroupInvite("k", "g1", "勉強会", "INV", "Inviter"), { status: "pending" });
  assert.deepEqual(await registry.addIncomingGroupInvite("k", "g1", "勉強会", "INV", "Inviter"), { status: "already_pending" });
  assert.equal(record("k").incomingGroupInvites.length, 1);
  assert.equal(record("k").incomingGroupInvites[0].name, "勉強会");
});

test("accepting a group invitation joins the group and consumes the invite; rejecting only consumes it", async () => {
  const { registry, record, seed } = setup();
  seed("k", { incomingGroupInvites: [{ roomID: "g1", name: "A", inviterCode: "I" }, { roomID: "g2", name: "B", inviterCode: "I" }] });
  const accepted = await registry.resolveIncomingGroupInvite("k", "accept", "g1");
  assert.equal(accepted.status, "accepted");
  assert.equal(accepted.invite!.roomID, "g1", "the invite is handed back so it can be restored");
  assert.deepEqual(record("k").groups, [{ roomID: "g1" }]);
  assert.deepEqual(record("k").incomingGroupInvites.map((item: Untyped) => item.roomID), ["g2"]);

  const rejected = await registry.resolveIncomingGroupInvite("k", "reject", "g2");
  assert.equal(rejected.status, "rejected");
  assert.deepEqual(record("k").groups, [{ roomID: "g1" }]);
  assert.deepEqual(record("k").incomingGroupInvites, []);

  assert.deepEqual(await registry.resolveIncomingGroupInvite("k", "accept", "g1"), { status: "not_found" }, "already answered");
  assert.deepEqual(await registry.resolveIncomingGroupInvite("nobody", "accept", "g1"), { status: "not_found" });
});

test("an accept that didn't take is undone: the group entry goes and the invite comes back, once", async () => {
  const { registry, record, seed } = setup();
  seed("k", { incomingGroupInvites: [{ roomID: "g1", name: "A", inviterCode: "I", inviterName: "Inv" }] });
  await registry.resolveIncomingGroupInvite("k", "accept", "g1");
  assert.deepEqual(await registry.undoAcceptedGroupInvite("k", "g1", "A", "I", "Inv"), { status: "restored" });
  assert.deepEqual(record("k").groups, []);
  assert.equal(record("k").incomingGroupInvites.length, 1);
  assert.equal(record("k").incomingGroupInvites[0].inviterName, "Inv");
  await registry.undoAcceptedGroupInvite("k", "g1", "A", "I", "Inv");
  assert.equal(record("k").incomingGroupInvites.length, 1, "undoing twice doesn't list the invite twice");
  assert.deepEqual(await registry.undoAcceptedGroupInvite("nobody", "g1", "A", "I", "Inv"), { status: "not_found" });
});

test("the creator is added to their group once; leaving a group removes only that group", async () => {
  const { registry, record, seed, puts } = setup();
  seed("k");
  assert.deepEqual(await registry.addGroupForCreator("k", "g1"), { status: "added" });
  await registry.addGroupForCreator("k", "g1");
  await registry.addGroupForCreator("k", "g2");
  assert.deepEqual(record("k").groups, [{ roomID: "g1" }, { roomID: "g2" }]);
  assert.deepEqual(await registry.removeGroup("k", "g1"), { status: "removed" });
  assert.deepEqual(record("k").groups, [{ roomID: "g2" }]);
  const writes = puts.length;
  await registry.removeGroup("k", "never-joined");
  assert.equal(puts.length, writes, "leaving a group they weren't in writes nothing");
  assert.deepEqual(await registry.addGroupForCreator("nobody", "g1"), { status: "not_found" });
  assert.deepEqual(await registry.removeGroup("nobody", "g1"), { status: "not_found" });
});
