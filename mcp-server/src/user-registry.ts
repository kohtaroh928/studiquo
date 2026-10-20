import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";
import type { ChatUser, GroupEntry } from "./records.ts";
import { eraseLibraryID, getOrCreateLibraryID } from "./library-id.ts";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_FRIENDS = 500;

// New codes are 10 characters (about 50 bits). They used to be 7 (about 35 bits),
// which is few enough to be guessed at scale by many accounts each trying a few
// codes. Existing 7-character codes stay valid: nothing here or in the app
// checks for an exact length, only the 6-32 character pattern.
function generateCode() {
  const bytes = new Uint8Array(10);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => CODE_ALPHABET[value % 32]).join("");
}

// Every request for the same key resolves to the same object instance, and a
// Durable Object handles its incoming requests one at a time — so two
// concurrent "this user doesn't exist yet" registrations for the same key
// can no longer each mint and persist a different friend code for it.
export class UserRegistry extends DurableObject<Env> {
  // The opaque id the app keeps one on-device library per account under
  // (GET /api/account/library-id). Made at random the first time it is asked
  // for and kept here, in an object named for the account; nothing about the
  // account can be worked out from it. This object is single-threaded and its
  // storage is strongly consistent, so two first requests at once get the same
  // id. Erased with the account (eraseLibraryID), so signing up again gives a
  // new id and a previous library is not handed to the new account.
  async libraryID() {
    return getOrCreateLibraryID(this.ctx);
  }

  async eraseLibraryID() {
    await eraseLibraryID(this.ctx);
  }

  async resolveChatKey(identityHash: string, legacyTokenHash: string): Promise<string> {
    const existing = await this.ctx.storage.get<string>("chatIdentityKey");
    if (existing) return existing;
    // Only initialization needs to hold the gate across the legacy KV read.
    return this.ctx.blockConcurrencyWhile(async () => {
      const saved = await this.ctx.storage.get<string>("chatIdentityKey");
      if (saved) return saved;
      const key = await this.env.STUDIQUO_DATA.get(`chat:user:${legacyTokenHash}`)
        ? legacyTokenHash : identityHash;
      await this.ctx.storage.put("chatIdentityKey", key);
      return key;
    });
  }

  // Reads a user's record through the Durable Object that also writes it. A
  // KV read from elsewhere can return a value up to a minute old, so a friend
  // who was just removed could still be listed; the writes (removeFriend and
  // the like) happen in this object's location, where a read sees them at once.
  async getUser(key: string) {
    return await this.env.STUDIQUO_DATA.get<ChatUser>(`chat:user:${key}`, "json");
  }

  async ensureUser(key: string, name: string | null | undefined, studyStats: any = null, bio: any = undefined): Promise<ChatUser> {
    const storageKey = `chat:user:${key}`;
    let user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (user) {
      let changed = false;
      const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
      if (cleaned && cleaned !== user.name) {
        user.name = cleaned;
        changed = true;
      }
      if (studyStats) {
        user.todayStudySeconds = studyStats.seconds;
        user.studyDate = studyStats.date;
        changed = true;
      }
      if (bio !== undefined && bio !== user.bio) {
        user.bio = bio;
        changed = true;
      }
      // Backfills a link token for a user created before invite links
      // existed — see the brand-new-user branch below for why this has to
      // be a second, separate value from `code`.
      if (!user.linkToken) {
        do { user.linkToken = generateCode(); } while (await this.env.STUDIQUO_DATA.get(`chat:linktoken:${user.linkToken}`));
        await this.env.STUDIQUO_DATA.put(`chat:linktoken:${user.linkToken}`, key);
        changed = true;
      }
      if (changed) {
        await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
      }
      return user;
    }
    let friendCode;
    do { friendCode = generateCode(); } while (await this.env.STUDIQUO_DATA.get(`chat:code:${friendCode}`));
    // A second code, distinct from `friendCode`, embedded only in a
    // shareable invite link/QR — never typed manually. Keeping it separate
    // from `friendCode` is what lets `/api/chat/friends/link-add` treat
    // redeeming it as consent enough for an instant, no-approval
    // friendship, without also letting anyone bypass manual entry's
    // approval step by just typing the same value `friendCode` would give
    // them.
    let linkToken;
    do { linkToken = generateCode(); } while (await this.env.STUDIQUO_DATA.get(`chat:linktoken:${linkToken}`));
    user = { key, name: String(name ?? "").trim().slice(0, 80) || "Studiquoユーザー", code: friendCode, linkToken, friends: [] };
    if (bio !== undefined) user.bio = bio;
    if (studyStats) {
      user.todayStudySeconds = studyStats.seconds;
      user.studyDate = studyStats.date;
    }
    await Promise.all([
      this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user)),
      this.env.STUDIQUO_DATA.put(`chat:code:${friendCode}`, key),
      this.env.STUDIQUO_DATA.put(`chat:linktoken:${linkToken}`, key),
    ]);
    return user;
  }

  // Recording a pending request is also routed through this per-key instance
  // (called via getByName(key), the recipient's own key) so that two people
  // requesting the same recipient at nearly the same moment can't each read
  // the same stale incomingRequests array and overwrite one another's
  // addition — the DO's one-at-a-time handling serializes them instead.
  async addIncomingRequest(key: string, requesterCode: string, requesterName: string): Promise<{ status: "not_found" | "already_friends" | "pending"; recipient?: { code: string; name: string } }> {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.friends ?? []).some(item => item.code === requesterCode)) {
      return { status: "already_friends" };
    }
    if (!(user.incomingRequests ?? []).some(item => item.code === requesterCode)) {
      user.incomingRequests = [
        ...(user.incomingRequests ?? []),
        { code: requesterCode, name: requesterName, requestedAt: Date.now() },
      ].slice(-500);
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    // The recipient's own code/name is already loaded here, so the caller
    // (the requester, recording this on their own outgoingRequests list) can
    // use it without a second KV read.
    return { status: "pending", recipient: { code: user.code, name: user.name } };
  }

  // Lets the requester show "sent, awaiting approval" for their own pending
  // requests. Routed through this per-key instance for the same reason as
  // addIncomingRequest: a requester sending to two different people at
  // nearly the same moment must not have one addition overwrite the other.
  async addOutgoingRequest(key: string, recipientCode: string, recipientName: string) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return;
    if (!(user.outgoingRequests ?? []).some(item => item.code === recipientCode)) {
      user.outgoingRequests = [
        ...(user.outgoingRequests ?? []),
        { code: recipientCode, name: recipientName, requestedAt: Date.now() },
      ].slice(-500);
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
  }

  // Clears a resolved (accepted or rejected) request from the original
  // requester's own outgoingRequests list, keyed by the recipient's code.
  async removeOutgoingRequest(key: string, recipientCode: string) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return;
    const filtered = (user.outgoingRequests ?? []).filter(item => item.code !== recipientCode);
    if (filtered.length !== (user.outgoingRequests ?? []).length) {
      user.outgoingRequests = filtered;
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
  }

  // Accept and reject are both initiated by the recipient (called via
  // getByName(key), the recipient's own key) against their own
  // incomingRequests/friends. Routing both through this one per-key
  // instance closes the race where accept and reject fire for the same
  // pending request at nearly the same moment: without this, both read the
  // same stale record and whichever writes last silently wins — even
  // undoing a friendship the other one just created.
  async resolveIncomingRequest(key: string, action: string, otherCode: string, otherName: any, roomID: string | null): Promise<{ status: "not_found" | "rejected" | "friends_full" | "accepted"; recipient?: { code: string; name: string }; friend?: { code: string; name: string } }> {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user || !(user.incomingRequests ?? []).some(item => item.code === otherCode)) {
      return { status: "not_found" };
    }
    user.incomingRequests = (user.incomingRequests ?? []).filter(item => item.code !== otherCode);
    if (action === "reject") {
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
      return { status: "rejected", recipient: { code: user.code, name: user.name } };
    }
    if ((user.friends ?? []).length >= MAX_FRIENDS) {
      return { status: "friends_full" };
    }
    user.friends = [...(user.friends ?? []).filter(item => item.code !== otherCode), { code: otherCode, name: otherName, roomID }];
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "accepted", friend: { code: user.code, name: user.name } };
  }

  // Instant, no-approval friendship — used only for `/api/chat/friends/link-add`,
  // when the caller redeemed the *other* person's invite-link token (a
  // value only someone who actually received the link/QR could have,
  // never a manually typed friend code). Mirrors resolveIncomingRequest's
  // "accept" branch, but there's no pending request to remove first since
  // none was ever created for this path. Routed through this per-key
  // instance (called via getByName(key), the caller's own key) for the
  // same race-safety reason every other friends-list mutation here is.
  async addFriendDirectly(key: string, otherCode: string, otherName: string, roomID: string | null) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.friends ?? []).some(item => item.code === otherCode)) {
      return { status: "already_friends", friend: { code: user.code, name: user.name } };
    }
    if ((user.friends ?? []).length >= MAX_FRIENDS) {
      return { status: "friends_full" };
    }
    user.friends = [...(user.friends ?? []), { code: otherCode, name: otherName, roomID }];
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "added", friend: { code: user.code, name: user.name } };
  }

  // Called for both participants after their room has been closed. Keeping
  // the blocked-contact archive independent of `friends` makes an existing
  // block removable even after the friendship disappears from both lists.
  async removeFriend(key: string, otherCode: string, blockedContact: any = null) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    const before = user.friends ?? [];
    user.friends = before.filter(item => item.code !== otherCode);
    if (blockedContact && !(user.blockedContacts ?? []).some(item => item.code === otherCode)) {
      user.blockedContacts = [...(user.blockedContacts ?? []), blockedContact];
    }
    if (user.friends.length !== before.length || blockedContact) {
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return { status: "removed" };
  }

  // Records the other half of a new friendship on `key`'s own record. These
  // used to be written straight from the request handlers (chat.ts) as a
  // whole-record overwrite of a possibly stale read, which could silently
  // undo a concurrent removeFriend / request change on the same record — the
  // "deleted friend comes back" bug. Routing every write of `chat:user:*`
  // through this per-key instance serializes them.
  async confirmFriendship(key: string, friend: any, { clearOutgoing = false } = {}) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.friends = [...(user.friends ?? []).filter(item => item.code !== friend.code), friend];
    if (clearOutgoing) {
      user.outgoingRequests = (user.outgoingRequests ?? []).filter(item => item.code !== friend.code);
    }
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "confirmed" };
  }

  async setAvatarUpdatedAt(key: string, updatedAt: string | number | null | undefined) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.avatarUpdatedAt = updatedAt;
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "updated" };
  }

  async removeAccountReferences(key: string, deletedCode: string | undefined) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    const deletedFriend = (user.friends ?? []).find(item => item.code === deletedCode);
    const blockedContact = (user.blockedContacts ?? []).find(item => item.code === deletedCode);
    user.friends = (user.friends ?? []).filter(item => item.code !== deletedCode);
    user.blockedContacts = (user.blockedContacts ?? []).filter(item => item.code !== deletedCode);
    const historicalContact = deletedFriend ?? blockedContact;
    if (historicalContact) {
      user.blockedContacts = [
        ...(user.blockedContacts ?? []),
        { ...historicalContact, name: "削除済みユーザー", deleted: true },
      ];
    }
    user.incomingRequests = (user.incomingRequests ?? []).filter(item => item.code !== deletedCode);
    user.outgoingRequests = (user.outgoingRequests ?? []).filter(item => item.code !== deletedCode);
    user.incomingGroupInvites = (user.incomingGroupInvites ?? []).filter(item => item.inviterCode !== deletedCode);
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "removed" };
  }

  // Records a pending group invitation on the invitee's own record — routed
  // through this per-key instance (getByName(key), the invitee's own key)
  // for the same race-safety reason addIncomingRequest is: two different
  // inviters (or the same group inviting the same person twice in quick
  // succession) can't race and drop one another's addition. `name` is the
  // group's name at invite time, denormalized here the same way
  // addIncomingRequest denormalizes the requester's name — a listed,
  // not-yet-accepted invite has no room membership yet to look it up live
  // through.
  async addIncomingGroupInvite(key: string, roomID: string, name: string | null, inviterCode: string, inviterName: string) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.groups ?? []).some(item => item.roomID === roomID)) {
      return { status: "already_member" };
    }
    if ((user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) {
      return { status: "already_pending" };
    }
    user.incomingGroupInvites = [
      ...(user.incomingGroupInvites ?? []),
      { roomID, name, inviterCode, inviterName, invitedAt: Date.now() },
    ].slice(-500);
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "pending" };
  }

  // Accept and reject are both initiated by the invitee (called via
  // getByName(key), the invitee's own key) against their own
  // incomingGroupInvites/groups — mirrors resolveIncomingRequest's own
  // race-safety reasoning for the same "both fire at nearly the same
  // moment" scenario.
  async resolveIncomingGroupInvite(key: string, action: string, roomID: string): Promise<{ status: "not_found" | "accepted" | "rejected"; invite?: GroupEntry }> {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    const invite = (user?.incomingGroupInvites ?? []).find(item => item.roomID === roomID);
    if (!user || !invite) {
      return { status: "not_found" };
    }
    user.incomingGroupInvites = (user.incomingGroupInvites ?? []).filter(item => item.roomID !== roomID);
    if (action === "accept") {
      user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    }
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    // `invite` is handed back so groups.ts can restore it verbatim if the
    // accept it's about to attempt (addParticipant, one call up) turns out
    // not to actually take — see undoAcceptedGroupInvite below.
    return { status: action === "accept" ? "accepted" : "rejected", invite };
  }

  // Reverses exactly the "accept" mutation resolveIncomingGroupInvite just
  // made, for the one case where it turns out to have been premature: the
  // invite is consumed and `groups` optimistically updated *before*
  // ChatRoom.addParticipant is actually attempted (see groups.ts), so that
  // an accept racing a reject of the same invite still resolves atomically.
  // If addParticipant then fails (e.g. the group filled up in the meantime),
  // the invitee must not be left with a phantom `groups` entry for a room
  // they were never added to, nor with their invite silently discarded —
  // this puts both back so they can retry once a seat opens up.
  async undoAcceptedGroupInvite(key: string, roomID: string, name: string | null | undefined, inviterCode: string | undefined, inviterName: string | undefined) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.groups = (user.groups ?? []).filter(item => item.roomID !== roomID);
    if (!(user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) {
      user.incomingGroupInvites = [
        ...(user.incomingGroupInvites ?? []),
        { roomID, name, inviterCode, inviterName, invitedAt: Date.now() },
      ].slice(-500);
    }
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "restored" };
  }

  // Adds this key's own groups-list entry directly — used only for the
  // creator of a brand-new group, who doesn't go through an invite/accept
  // step for their own membership. Routed through this per-key instance for
  // the same race-safety reason every other groups-list mutation here is.
  async addGroupForCreator(key: string, roomID: string) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "added" };
  }

  // Removes this key's own groups-list entry — called against whichever
  // member's own record needs updating (getByName(targetKey)), whether they
  // left on their own or were removed by someone else; the room-side
  // removal (ChatRoom.removeParticipant) is a separate call groups.ts makes
  // alongside this one.
  async removeGroup(key: string, roomID: string) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get<ChatUser>(storageKey, "json");
    if (!user) return { status: "not_found" };
    const before = user.groups ?? [];
    user.groups = before.filter(item => item.roomID !== roomID);
    if (user.groups.length !== before.length) {
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return { status: "removed" };
  }
}
