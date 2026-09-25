import { DurableObject } from "cloudflare:workers";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_FRIENDS = 500;

function generateCode() {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => CODE_ALPHABET[value % 32]).join("");
}

// Every request for the same key resolves to the same object instance, and a
// Durable Object handles its incoming requests one at a time — so two
// concurrent "this user doesn't exist yet" registrations for the same key
// can no longer each mint and persist a different friend code for it.
export class UserRegistry extends DurableObject {
  async resolveChatKey(identityHash, legacyTokenHash) {
    const existing = await this.ctx.storage.get("chatIdentityKey");
    if (existing) return existing;
    // Only initialization needs to hold the gate across the legacy KV read.
    return this.ctx.blockConcurrencyWhile(async () => {
      const saved = await this.ctx.storage.get("chatIdentityKey");
      if (saved) return saved;
      const key = await this.env.STUDIQUO_DATA.get(`chat:user:${legacyTokenHash}`)
        ? legacyTokenHash : identityHash;
      await this.ctx.storage.put("chatIdentityKey", key);
      return key;
    });
  }

  async ensureUser(key, name) {
    const storageKey = `chat:user:${key}`;
    let user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (user) {
      let changed = false;
      const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
      if (cleaned && cleaned !== user.name) {
        user.name = cleaned;
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
  async addIncomingRequest(key, requesterCode, requesterName) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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
  async addOutgoingRequest(key, recipientCode, recipientName) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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
  async removeOutgoingRequest(key, recipientCode) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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
  async resolveIncomingRequest(key, action, otherCode, otherName, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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
  async addFriendDirectly(key, otherCode, otherName, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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
  async removeFriend(key, otherCode, blockedContact = null) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
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

  // Records a pending group invitation on the invitee's own record — routed
  // through this per-key instance (getByName(key), the invitee's own key)
  // for the same race-safety reason addIncomingRequest is: two different
  // inviters (or the same group inviting the same person twice in quick
  // succession) can't race and drop one another's addition. `name` is the
  // group's name at invite time, denormalized here the same way
  // addIncomingRequest denormalizes the requester's name — a listed,
  // not-yet-accepted invite has no room membership yet to look it up live
  // through.
  async addIncomingGroupInvite(key, roomID, name, inviterCode, inviterName) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.groups ?? []).some(item => item.roomID === roomID)) {
      return { status: "already_member" };
    }
    if (!(user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) {
      user.incomingGroupInvites = [
        ...(user.incomingGroupInvites ?? []),
        { roomID, name, inviterCode, inviterName, invitedAt: Date.now() },
      ].slice(-500);
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return { status: "pending" };
  }

  // Accept and reject are both initiated by the invitee (called via
  // getByName(key), the invitee's own key) against their own
  // incomingGroupInvites/groups — mirrors resolveIncomingRequest's own
  // race-safety reasoning for the same "both fire at nearly the same
  // moment" scenario.
  async resolveIncomingGroupInvite(key, action, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user || !(user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) {
      return { status: "not_found" };
    }
    user.incomingGroupInvites = (user.incomingGroupInvites ?? []).filter(item => item.roomID !== roomID);
    if (action === "accept") {
      user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    }
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: action === "accept" ? "accepted" : "rejected" };
  }

  // Adds this key's own groups-list entry directly — used only for the
  // creator of a brand-new group, who doesn't go through an invite/accept
  // step for their own membership. Routed through this per-key instance for
  // the same race-safety reason every other groups-list mutation here is.
  async addGroupForCreator(key, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "added" };
  }

  // Removes this key's own groups-list entry — called against whichever
  // member's own record needs updating (getByName(targetKey)), whether they
  // left on their own or were removed by someone else; the room-side
  // removal (ChatRoom.removeParticipant) is a separate call groups.js makes
  // alongside this one.
  async removeGroup(key, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    const before = user.groups ?? [];
    user.groups = before.filter(item => item.roomID !== roomID);
    if (user.groups.length !== before.length) {
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return { status: "removed" };
  }
}
