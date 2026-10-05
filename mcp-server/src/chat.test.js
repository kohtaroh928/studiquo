import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
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
  const FAKE_MAX_GROUP_MEMBERS = 50;
  function room(name) {
    if (!rooms.has(name)) rooms.set(name, { participants: new Set(), memberInfo: new Map(), messages: [], attachments: new Map(), blocks: new Set(), readPositions: new Map(), closed: false, kind: "direct", name: null });
    return rooms.get(name);
  }
  return {
    initializeCalls,
    _rooms: rooms,
    getByName(name) {
      const state = room(name);
      const other = userKey => [...state.participants].find(candidate => candidate !== userKey) ?? null;
      const requireGroup = userKey => {
        if (!state.participants.has(userKey)) throw new Error("Forbidden");
        if (state.kind !== "group") throw new Error("NotAGroup");
      };
      return {
        async initialize(_roomID, participants, options = {}) {
          initializeCalls.count += 1;
          const kind = options.kind ?? "direct";
          if (state.participants.size > 0) { state.closed = false; return; }
          const capped = kind === "group" ? participants : participants.slice(0, 2);
          for (const key of capped) {
            state.participants.add(key);
            if (kind === "group") state.memberInfo.set(key, { code: options.creatorCode ?? null, name: options.creatorName ?? null });
          }
          if (kind === "group") {
            state.kind = "group";
            state.name = String(options.name ?? "").trim().slice(0, 80) || null;
          }
        },
        // Mirrors chat-room.js's real addParticipant: always self-initiated
        // by whoever just had their group invite accepted (see groups.js) —
        // the real authorization already happened one level up, so this
        // doesn't require the new member to already be a participant.
        async addParticipant(newKey, code, name) {
          if (state.kind !== "group") throw new Error("NotAGroup");
          if (state.participants.size >= FAKE_MAX_GROUP_MEMBERS) throw new Error("GroupFull");
          state.participants.add(newKey);
          state.memberInfo.set(newKey, { code: code ?? null, name: name ?? null });
          state.readPositions.set(newKey, state.messages.at(-1)?.id ?? 0);
          return { status: "added" };
        },
        // Mirrors chat-room.js's real removeParticipant: any current member
        // may remove any other (or themselves) — no admin/owner concept.
        async removeParticipant(callerKey, targetKey) {
          requireGroup(callerKey);
          if (!state.participants.has(targetKey)) throw new Error("Forbidden");
          state.participants.delete(targetKey);
          state.memberInfo.delete(targetKey);
          state.readPositions.delete(targetKey);
          return { status: "removed" };
        },
        async renameRoom(callerKey, name) {
          requireGroup(callerKey);
          const trimmed = String(name ?? "").trim().slice(0, 80);
          if (!trimmed) throw new Error("InvalidName");
          state.name = trimmed;
          return { status: "renamed", name: trimmed };
        },
        async groupInfo(callerKey) {
          requireGroup(callerKey);
          const members = [...state.participants].map(participantKey => ({
            key: participantKey,
            code: state.memberInfo.get(participantKey)?.code ?? null,
            name: state.memberInfo.get(participantKey)?.name ?? null,
          }));
          return { name: state.name, members };
        },
        async close(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const latestID = state.messages.at(-1)?.id ?? 0;
          for (const participant of state.participants) state.readPositions.set(participant, latestID);
          state.closed = true;
          return { status: "closed" };
        },
        async inboxState(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const latestID = state.messages.at(-1)?.id ?? 0;
          if (state.closed) return { latestID, unreadCount: 0, closed: true };
          if (!state.readPositions.has(userKey)) state.readPositions.set(userKey, latestID);
          return {
            latestID,
            unreadCount: state.messages.filter(item => item.id > state.readPositions.get(userKey) && item.senderKey !== userKey && !item.isCanceled).length,
            closed: false,
          };
        },
        async markRead(userKey, throughID) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const safeID = Math.min(state.messages.at(-1)?.id ?? 0, throughID);
          state.readPositions.set(userKey, Math.max(state.readPositions.get(userKey) ?? 0, safeID));
          return { status: "read", throughID: safeID };
        },
        // Mirrors chat-room.js's real requireParticipant: throws for a
        // non-participant, otherwise resolves with nothing meaningful — a
        // pure access-control check, not a data read.
        async requireParticipant(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
        },
        async blockOtherParticipant(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          if (state.kind === "group") throw new Error("NotSupported");
          state.blocks.add(userKey);
          return { status: "blocked" };
        },
        async unblockOtherParticipant(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          if (state.kind === "group") throw new Error("NotSupported");
          state.blocks.delete(userKey);
          return { status: "unblocked" };
        },
        async blockStatus(userKey) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          if (state.kind === "group") throw new Error("NotSupported");
          const theOther = other(userKey);
          return {
            blockedByMe: state.blocks.has(userKey),
            blockedByOther: theOther ? state.blocks.has(theOther) : false,
          };
        },
        async sendMessage(userKey, text, clientMessageID = null) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          if (state.closed) throw new Error("Closed");
          if (state.kind !== "group") {
            const theOther = other(userKey);
            if (theOther && state.blocks.has(theOther)) throw new Error("Blocked");
            if (theOther && !state.readPositions.has(theOther)) {
              state.readPositions.set(theOther, state.messages.at(-1)?.id ?? 0);
            }
          }
          const message = { id: state.messages.length + 1, text, sentAt: Date.now(), isMine: true, clientMessageID, isCanceled: false, senderKey: userKey };
          state.messages.push(message);
          return message;
        },
        async listMessages(userKey, after = 0) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          return state.messages
            .filter(item => item.id > after)
            .map(item => ({ ...item, isMine: item.senderKey === userKey }));
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
        // Mirrors chat-room.js's real editMessage: only the original sender
        // may edit, and a canceled message can never be resurrected by one.
        async editMessage(userKey, messageID, text) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const message = state.messages.find(item => item.id === messageID);
          if (!message) return { status: "not_found" };
          if (message.senderKey !== userKey) throw new Error("Forbidden");
          if (message.isCanceled) return { status: "canceled" };
          message.text = text;
          return { status: "edited" };
        },
        // Mirrors chat-room.js's real getMessagesByIDs: a direct-by-id
        // lookup independent of the `after` cursor, for reconciling ids old
        // enough to have scrolled out of the normal rolling window.
        async getMessagesByIDs(userKey, ids) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          const idSet = new Set(ids);
          return state.messages
            .filter(item => idSet.has(item.id))
            .map(item => ({ ...item, isMine: item.senderKey === userKey }));
        },
        // Mirrors chat-room.js's real storeAttachment/getAttachment: same
        // validation, same Forbidden gate, same in-room storage — so the
        // fake actually exercises the same access-control path.
        // Mirrors chat-room.js's opportunistic cleanup too: every new
        // upload purges attachments past the retention window first, since
        // there's no cron/alarm to do it on a schedule.
        async storeAttachment(userKey, contentType, base64Data) {
          if (!state.participants.has(userKey)) throw new Error("Forbidden");
          if (state.closed) throw new Error("Closed");
          const type = String(contentType ?? "").slice(0, 100);
          if (!ATTACHMENT_CONTENT_TYPE_PATTERN.test(type)) throw new Error("InvalidContentType");
          const data = String(base64Data ?? "");
          const approxBytes = Math.floor((data.length * 3) / 4);
          if (!data || approxBytes > FAKE_MAX_ATTACHMENT_BYTES) throw new Error("AttachmentTooLarge");
          for (const [existingId, existing] of state.attachments) {
            if (Date.now() - existing.createdAt >= FAKE_ATTACHMENT_RETENTION_MS) state.attachments.delete(existingId);
          }
          const id = `00000000-0000-4000-8000-${String(nextAttachmentId++).padStart(12, "0")}`;
          state.attachments.set(id, { contentType: type, data, createdAt: Date.now(), uploadedBy: userKey });
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
        async removeDeletedAccount(userKey) {
          const deletedSenderKey = `deleted:${createHash("sha256").update(userKey).digest("hex")}`;
          for (const message of state.messages) {
            if (message.senderKey === userKey) message.senderKey = deletedSenderKey;
          }
          for (const [id, attachment] of state.attachments) {
            if (attachment.uploadedBy === userKey) state.attachments.delete(id);
          }
          state.participants.delete(userKey);
          state.memberInfo.delete(userKey);
          state.readPositions.delete(userKey);
          state.blocks.delete(userKey);
          return { status: "removed" };
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
  const chatIdentityKeys = new Map();

  async function ensureUserAtomic(key, name) {
    const storageKey = `chat:user:${key}`;
    let user = await studiquoData.get(storageKey, "json");
    if (user) {
      let changed = false;
      const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
      if (cleaned && cleaned !== user.name) {
        user.name = cleaned;
        changed = true;
      }
      if (!user.linkToken) {
        do { user.linkToken = generateRegistryTestCode(); } while (await studiquoData.get(`chat:linktoken:${user.linkToken}`));
        await studiquoData.put(`chat:linktoken:${user.linkToken}`, key);
        changed = true;
      }
      if (changed) await studiquoData.put(storageKey, JSON.stringify(user));
      return user;
    }
    let friendCode;
    do { friendCode = generateRegistryTestCode(); } while (await studiquoData.get(`chat:code:${friendCode}`));
    let linkToken;
    do { linkToken = generateRegistryTestCode(); } while (await studiquoData.get(`chat:linktoken:${linkToken}`));
    user = { key, name: String(name ?? "").trim().slice(0, 80) || "Studiquoユーザー", code: friendCode, linkToken, friends: [] };
    await Promise.all([
      studiquoData.put(storageKey, JSON.stringify(user)),
      studiquoData.put(`chat:code:${friendCode}`, key),
      studiquoData.put(`chat:linktoken:${linkToken}`, key),
    ]);
    return user;
  }

  async function addFriendDirectlyAtomic(key, otherCode, otherName, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.friends ?? []).some(item => item.code === otherCode)) {
      return { status: "already_friends", friend: { code: user.code, name: user.name } };
    }
    if ((user.friends ?? []).length >= 500) {
      return { status: "friends_full" };
    }
    user.friends = [...(user.friends ?? []), { code: otherCode, name: otherName, roomID }];
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "added", friend: { code: user.code, name: user.name } };
  }

  async function removeFriendAtomic(key, otherCode, blockedContact = null) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.friends = (user.friends ?? []).filter(item => item.code !== otherCode);
    if (blockedContact && !(user.blockedContacts ?? []).some(item => item.code === otherCode)) {
      user.blockedContacts = [...(user.blockedContacts ?? []), blockedContact];
    }
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "removed" };
  }

  async function removeAccountReferencesAtomic(key, deletedCode) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    const deletedFriend = (user.friends ?? []).find(item => item.code === deletedCode);
    const blockedContact = (user.blockedContacts ?? []).find(item => item.code === deletedCode);
    user.friends = (user.friends ?? []).filter(item => item.code !== deletedCode);
    user.blockedContacts = (user.blockedContacts ?? []).filter(item => item.code !== deletedCode);
    const historicalContact = deletedFriend ?? blockedContact;
    if (historicalContact) {
      user.blockedContacts.push({ ...historicalContact, name: "削除済みユーザー", deleted: true });
    }
    user.incomingRequests = (user.incomingRequests ?? []).filter(item => item.code !== deletedCode);
    user.outgoingRequests = (user.outgoingRequests ?? []).filter(item => item.code !== deletedCode);
    user.incomingGroupInvites = (user.incomingGroupInvites ?? []).filter(item => item.inviterCode !== deletedCode);
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "removed" };
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

  async function addGroupForCreatorAtomic(key, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "added" };
  }

  async function addIncomingGroupInviteAtomic(key, roomID, name, inviterCode, inviterName) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.groups ?? []).some(item => item.roomID === roomID)) return { status: "already_member" };
    if ((user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) return { status: "already_pending" };
    user.incomingGroupInvites = [
      ...(user.incomingGroupInvites ?? []),
      { roomID, name, inviterCode, inviterName, invitedAt: Date.now() },
    ].slice(-500);
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "pending" };
  }

  async function resolveIncomingGroupInviteAtomic(key, action, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    const invite = (user?.incomingGroupInvites ?? []).find(item => item.roomID === roomID);
    if (!user || !invite) {
      return { status: "not_found" };
    }
    user.incomingGroupInvites = (user.incomingGroupInvites ?? []).filter(item => item.roomID !== roomID);
    if (action === "accept") {
      user.groups = [...(user.groups ?? []).filter(item => item.roomID !== roomID), { roomID }];
    }
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: action === "accept" ? "accepted" : "rejected", invite };
  }

  async function undoAcceptedGroupInviteAtomic(key, roomID, name, inviterCode, inviterName) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    user.groups = (user.groups ?? []).filter(item => item.roomID !== roomID);
    if (!(user.incomingGroupInvites ?? []).some(item => item.roomID === roomID)) {
      user.incomingGroupInvites = [
        ...(user.incomingGroupInvites ?? []),
        { roomID, name, inviterCode, inviterName, invitedAt: Date.now() },
      ].slice(-500);
    }
    await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "restored" };
  }

  async function removeGroupAtomic(key, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await studiquoData.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    const before = user.groups ?? [];
    user.groups = before.filter(item => item.roomID !== roomID);
    if (user.groups.length !== before.length) await studiquoData.put(storageKey, JSON.stringify(user));
    return { status: "removed" };
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
        resolveChatKey(identityHash, legacyTokenHash) {
          return enqueue(key, async () => {
            if (chatIdentityKeys.has(identityHash)) return chatIdentityKeys.get(identityHash);
            const chatKey = await studiquoData.get(`chat:user:${legacyTokenHash}`)
              ? legacyTokenHash : identityHash;
            chatIdentityKeys.set(identityHash, chatKey);
            return chatKey;
          });
        },
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
        addFriendDirectly(k, otherCode, otherName, roomID) {
          return enqueue(key, () => addFriendDirectlyAtomic(k, otherCode, otherName, roomID));
        },
        removeFriend(k, otherCode, blockedContact) {
          return enqueue(key, () => removeFriendAtomic(k, otherCode, blockedContact));
        },
        removeAccountReferences(k, deletedCode) {
          return enqueue(key, () => removeAccountReferencesAtomic(k, deletedCode));
        },
        addGroupForCreator(k, roomID) {
          return enqueue(key, () => addGroupForCreatorAtomic(k, roomID));
        },
        addIncomingGroupInvite(k, roomID, name, inviterCode, inviterName) {
          return enqueue(key, () => addIncomingGroupInviteAtomic(k, roomID, name, inviterCode, inviterName));
        },
        resolveIncomingGroupInvite(k, action, roomID) {
          return enqueue(key, () => resolveIncomingGroupInviteAtomic(k, action, roomID));
        },
        undoAcceptedGroupInvite(k, roomID, name, inviterCode, inviterName) {
          return enqueue(key, () => undoAcceptedGroupInviteAtomic(k, roomID, name, inviterCode, inviterName));
        },
        removeGroup(k, roomID) {
          return enqueue(key, () => removeGroupAtomic(k, roomID));
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
        value = JSON.stringify({ sub: `test:${key.slice(8)}`, issuedAt: Math.floor(Date.now() / 1000) });
      }
      return type === "json" && value ? JSON.parse(value) : value;
    },
    async put(key, value) { values.set(key, value); },
    async delete(key) { values.delete(key); },
    async list({ prefix = "", cursor } = {}) {
      void cursor;
      return {
        keys: [...values.keys()].filter(key => key.startsWith(prefix)).map(name => ({ name })),
        list_complete: true,
      };
    },
  };
  return {
    STUDIQUO_DATA: studiquoData,
    CHAT_ROOM: fakeChatRoomBinding(),
    USER_REGISTRY: fakeUserRegistryBinding(studiquoData),
    RATE_LIMIT_APPLE_AUTH: { async limit() { return { success: true }; } },
    RATE_LIMIT_CHAT_FRIEND_ADD: fakeCloudflareLimiter(),
    RATE_LIMIT_CHAT_MESSAGE: fakeCloudflareLimiter(30),
    RATE_LIMIT_CHAT_ATTACHMENT_UPLOAD: fakeCloudflareLimiter(10),
    RATE_LIMIT_CHAT_REPORT: fakeCloudflareLimiter(5),
    RATE_LIMIT_CHAT_GROUP_ACTION: fakeCloudflareLimiter(10),
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

async function addFriendViaLink(env, token, linkToken) {
  return worker.fetch(request("/api/chat/friends/link-add", { method: "POST", token, body: { token: linkToken } }), env, noopCtx);
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

async function editMessage(env, token, roomID, messageID, text) {
  return worker.fetch(
    request(`/api/chat/rooms/${roomID}/messages/${messageID}/edit`, { method: "POST", token, body: { text } }),
    env,
    noopCtx
  );
}

async function lookupMessages(env, token, roomID, ids) {
  return worker.fetch(
    request(`/api/chat/rooms/${roomID}/messages/lookup`, { method: "POST", token, body: { ids } }),
    env,
    noopCtx
  );
}

async function readMessages(env, token, roomID) {
  const response = await worker.fetch(request(`/api/chat/rooms/${roomID}/messages`, { token }), env, noopCtx);
  return response;
}

async function readMessagesWithAfter(env, token, roomID, afterRaw) {
  const path = `/api/chat/rooms/${roomID}/messages?after=${encodeURIComponent(afterRaw)}`;
  return worker.fetch(request(path, { token }), env, noopCtx);
}

async function blockOtherParticipant(env, token, roomID) {
  return worker.fetch(request(`/api/chat/rooms/${roomID}/block`, { method: "POST", token }), env, noopCtx);
}

async function unblockOtherParticipant(env, token, roomID) {
  return worker.fetch(request(`/api/chat/rooms/${roomID}/unblock`, { method: "POST", token }), env, noopCtx);
}

async function blockStatus(env, token, roomID) {
  const response = await worker.fetch(request(`/api/chat/rooms/${roomID}/block-status`, { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function reportMessage(env, token, roomID, messageID, reason) {
  return worker.fetch(
    request(`/api/chat/rooms/${roomID}/messages/${messageID}/report`, { method: "POST", token, body: { reason } }),
    env,
    noopCtx
  );
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

async function uploadAvatar(env, token, contentType, data) {
  return worker.fetch(request("/api/chat/me/avatar", { method: "POST", token, body: { contentType, data } }), env, noopCtx);
}

async function downloadAvatar(env, token, code) {
  return worker.fetch(request(`/api/chat/avatar/${code}`, { token }), env, noopCtx);
}

async function seedAccountSession(env, token, sub) {
  const tokenHash = createHash("sha256").update(token).digest("hex");
  await env.STUDIQUO_DATA.put(`session:${tokenHash}`, JSON.stringify({ sub, issuedAt: Math.floor(Date.now() / 1000) }));
  await env.STUDIQUO_DATA.put(`identity-canonical:${sub}`, sub);
  return createHash("sha256").update(`chat-account:${sub}`).digest("hex");
}

async function deleteAccount(env, token) {
  return worker.fetch(request("/api/account", { method: "DELETE", token, body: { confirmation: "DELETE" } }), env, noopCtx);
}

async function deletionFriendFixture() {
  const env = environment();
  const aliceToken = freshToken("da");
  const bobToken = freshToken("db");
  const aliceSub = "email:deleted-alice@example.test";
  const bobSub = "email:remaining-bob@example.test";
  const aliceKey = await seedAccountSession(env, aliceToken, aliceSub);
  const bobKey = await seedAccountSession(env, bobToken, bobSub);
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  return { env, aliceToken, bobToken, aliceSub, bobSub, aliceKey, bobKey, alice, bob, roomID: accepted.roomID };
}

async function deletionGroupFixture({ acceptInvite = true, solo = false } = {}) {
  const fixture = await deletionFriendFixture();
  const createdResponse = await createGroup(
    fixture.env,
    fixture.aliceToken,
    "削除テストグループ",
    solo ? [] : [fixture.bob.code],
  );
  assert.equal(createdResponse.status, 201);
  const created = await createdResponse.json();
  if (!solo && acceptInvite) {
    assert.equal((await acceptGroupInvite(fixture.env, fixture.bobToken, created.roomID)).status, 200);
  }
  return { ...fixture, groupRoomID: created.roomID };
}

async function createGroup(env, token, name, memberCodes) {
  return worker.fetch(request("/api/chat/groups", { method: "POST", token, body: { name, memberCodes } }), env, noopCtx);
}

async function groups(env, token) {
  const response = await worker.fetch(request("/api/chat/groups", { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function groupInvites(env, token) {
  const response = await worker.fetch(request("/api/chat/group-invites", { token }), env, noopCtx);
  assert.equal(response.status, 200);
  return response.json();
}

async function inviteToGroup(env, token, roomID, code) {
  return worker.fetch(request(`/api/chat/groups/${roomID}/invites`, { method: "POST", token, body: { code } }), env, noopCtx);
}

async function acceptGroupInvite(env, token, roomID) {
  return worker.fetch(request(`/api/chat/groups/${roomID}/invites/accept`, { method: "POST", token }), env, noopCtx);
}

async function rejectGroupInvite(env, token, roomID) {
  return worker.fetch(request(`/api/chat/groups/${roomID}/invites/reject`, { method: "POST", token }), env, noopCtx);
}

async function renameGroup(env, token, roomID, name) {
  return worker.fetch(request(`/api/chat/groups/${roomID}`, { method: "PATCH", token, body: { name } }), env, noopCtx);
}

async function removeGroupMember(env, token, roomID, code) {
  return worker.fetch(request(`/api/chat/groups/${roomID}/members/${code}`, { method: "DELETE", token }), env, noopCtx);
}

async function uploadGroupAvatar(env, token, roomID, contentType, data) {
  return worker.fetch(
    request(`/api/chat/groups/${roomID}/avatar`, { method: "POST", token, body: { contentType, data } }),
    env, noopCtx
  );
}

async function downloadGroupAvatar(env, token, roomID) {
  return worker.fetch(request(`/api/chat/groups/${roomID}/avatar`, { token }), env, noopCtx);
}

// Registers three friends of each other (Alice, Bob, Carol — all mutual
// friends) and returns their tokens/codes, so group tests can start from
// "three people who could plausibly form a group" without repeating the
// same three-way friend setup in every test.
async function threeMutualFriends(env, suffix) {
  const aliceToken = freshToken(`${suffix}a`);
  const bobToken = freshToken(`${suffix}b`);
  const carolToken = freshToken(`${suffix}c`);
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  const carol = await registerUser(env, carolToken, "Carol");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);
  await addFriend(env, aliceToken, carol.code);
  await acceptRequest(env, carolToken, alice.code);
  await addFriend(env, bobToken, carol.code);
  await acceptRequest(env, carolToken, bob.code);
  return { alice: { token: aliceToken, ...alice }, bob: { token: bobToken, ...bob }, carol: { token: carolToken, ...carol } };
}

test("a group can be created with no invited friends at all — just its creator", async () => {
  const env = environment();
  const { alice } = await threeMutualFriends(env, "g1");
  const response = await createGroup(env, alice.token, "Study Group", []);
  assert.equal(response.status, 201);
  const created = await response.json();
  assert.match(created.code, /^[A-HJ-NP-Z2-9]{10}$/);
  assert.deepEqual(created.members, [{ code: alice.code, name: "Alice" }]);
  const listed = await groups(env, alice.token);
  assert.deepEqual(listed.map(g => g.roomID), [created.roomID]);
  assert.equal(listed[0].code, created.code, "the public group code remains stable across refreshes");
  assert.equal(listed[0].avatarUpdatedAt, null);
});

test("creating a group with someone who isn't the caller's own friend is rejected", async () => {
  const env = environment();
  const { alice, bob } = await threeMutualFriends(env, "g2");
  const strangerToken = freshToken("g2d");
  const stranger = await registerUser(env, strangerToken, "Dave");
  const response = await createGroup(env, alice.token, "Study Group", [bob.code, stranger.code]);
  assert.equal(response.status, 400);
});

test("creating a group with the same friend listed twice sends only one invite, not two", async () => {
  const env = environment();
  const { alice, bob } = await threeMutualFriends(env, "g1b");
  const response = await createGroup(env, alice.token, "Study Group", [bob.code, bob.code]);
  assert.equal(response.status, 201);
  const bobInvites = await groupInvites(env, bob.token);
  assert.equal(bobInvites.length, 1);
});

test("creating a group adds only the creator immediately, and sends a pending invite to everyone else", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g3");

  const response = await createGroup(env, alice.token, "Study Group", [bob.code, carol.code]);
  assert.equal(response.status, 201);
  const created = await response.json();
  assert.equal(created.name, "Study Group");
  assert.deepEqual(created.members, [{ code: alice.code, name: "Alice" }]);

  assert.deepEqual((await groups(env, alice.token)).map(g => g.roomID), [created.roomID]);
  assert.deepEqual(await groups(env, bob.token), []);

  const bobInvites = await groupInvites(env, bob.token);
  assert.equal(bobInvites.length, 1);
  assert.equal(bobInvites[0].roomID, created.roomID);
  assert.equal(bobInvites[0].name, "Study Group");
  assert.equal(bobInvites[0].inviterCode, alice.code);
});

test("accepting a group invite adds the room to the invitee's own group list and lets them send messages", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g4");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const accepted = await (await acceptGroupInvite(env, bob.token, created.roomID)).json();
  assert.equal(accepted.members.length, 2);

  assert.deepEqual((await groupInvites(env, bob.token)), []);
  assert.deepEqual((await groups(env, bob.token)).map(g => g.roomID), [created.roomID]);

  const sent = await sendMessage(env, bob.token, created.roomID, "よろしく");
  assert.equal(sent.status, 200);
});

test("rejecting a group invite never adds the room to the invitee's group list", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g5");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const response = await rejectGroupInvite(env, bob.token, created.roomID);
  assert.equal(response.status, 200);
  assert.deepEqual(await groupInvites(env, bob.token), []);
  assert.deepEqual(await groups(env, bob.token), []);

  const sent = await sendMessage(env, bob.token, created.roomID, "内緒で送ってみる");
  assert.equal(sent.status, 403);
});

test("an existing member can invite one of their own friends into the group", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  // Bob invites Dave — Dave is a friend of Bob's, not of Alice's or Carol's.
  const daveToken = freshToken("g6d");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, bob.token, dave.code);
  await acceptRequest(env, daveToken, bob.code);

  const response = await inviteToGroup(env, bob.token, created.roomID, dave.code);
  assert.equal(response.status, 200);
  const daveInvites = await groupInvites(env, daveToken);
  assert.equal(daveInvites.length, 1);
  assert.equal(daveInvites[0].inviterCode, bob.code);
});

test("re-inviting someone who already has a pending invite to the group reports already_pending instead of pending", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6b");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();

  const daveToken = freshToken("g6bd");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);

  const first = await inviteToGroup(env, alice.token, created.roomID, dave.code);
  assert.equal(first.status, 200);
  assert.equal((await first.json()).status, "pending");

  const second = await inviteToGroup(env, alice.token, created.roomID, dave.code);
  assert.equal(second.status, 200);
  assert.equal((await second.json()).status, "already_pending");
});

test("re-inviting someone who already has a pending invite does not create a second, duplicate invite on their side", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6c");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();

  const daveToken = freshToken("g6cd");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);

  await inviteToGroup(env, alice.token, created.roomID, dave.code);
  await inviteToGroup(env, alice.token, created.roomID, dave.code);
  await inviteToGroup(env, alice.token, created.roomID, dave.code);

  const daveInvites = await groupInvites(env, daveToken);
  assert.equal(daveInvites.length, 1);
  assert.equal(daveInvites[0].roomID, created.roomID);
});

test("re-inviting someone already pending does not overwrite who invited them or when", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6e");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  const daveToken = freshToken("g6ed");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);
  await addFriend(env, bob.token, dave.code);
  await acceptRequest(env, daveToken, bob.code);

  await inviteToGroup(env, alice.token, created.roomID, dave.code);
  const original = (await groupInvites(env, daveToken))[0];

  // Bob (a different member) re-invites the same pending Dave.
  await inviteToGroup(env, bob.token, created.roomID, dave.code);
  const afterSecondInvite = (await groupInvites(env, daveToken))[0];

  assert.equal(afterSecondInvite.inviterCode, original.inviterCode, "still credited to Alice, not overwritten by Bob's repeat invite");
  assert.equal(afterSecondInvite.invitedAt, original.invitedAt, "the original invite timestamp is preserved, not refreshed");
});

test("rejecting an invite and then being re-invited creates a genuinely new, acceptable invite", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6f");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();

  const daveToken = freshToken("g6fd");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);

  await inviteToGroup(env, alice.token, created.roomID, dave.code);
  const rejectResponse = await rejectGroupInvite(env, daveToken, created.roomID);
  assert.equal(rejectResponse.status, 200);
  assert.deepEqual(await groupInvites(env, daveToken), []);

  const reinvite = await inviteToGroup(env, alice.token, created.roomID, dave.code);
  assert.equal(reinvite.status, 200);
  assert.equal((await reinvite.json()).status, "pending");
  const daveInvites = await groupInvites(env, daveToken);
  assert.equal(daveInvites.length, 1);
  assert.equal(daveInvites[0].roomID, created.roomID);
});

test("accepting a re-invite sent after an earlier rejection joins the group normally", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6g");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();

  const daveToken = freshToken("g6gd");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);

  await inviteToGroup(env, alice.token, created.roomID, dave.code);
  await rejectGroupInvite(env, daveToken, created.roomID);
  await inviteToGroup(env, alice.token, created.roomID, dave.code);

  const acceptResponse = await acceptGroupInvite(env, daveToken, created.roomID);
  assert.equal(acceptResponse.status, 200);
  const accepted = await acceptResponse.json();
  assert.ok(accepted.members.some(member => member.code === dave.code));
  assert.deepEqual((await groups(env, daveToken)).map(g => g.roomID), [created.roomID]);

  const sent = await sendMessage(env, daveToken, created.roomID, "入りました");
  assert.equal(sent.status, 200);
});

test("repeated invite-then-reject cycles keep working the same way each time, with no hidden cooldown", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6h");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();

  const daveToken = freshToken("g6hd");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, alice.token, dave.code);
  await acceptRequest(env, daveToken, alice.code);

  for (let cycle = 0; cycle < 3; cycle++) {
    const inviteResponse = await inviteToGroup(env, alice.token, created.roomID, dave.code);
    assert.equal(inviteResponse.status, 200, `cycle ${cycle}: invite should succeed`);
    assert.equal((await inviteResponse.json()).status, "pending", `cycle ${cycle}: a fresh invite after a full reject cycle is pending, not already_pending`);
    const rejectResponse = await rejectGroupInvite(env, daveToken, created.roomID);
    assert.equal(rejectResponse.status, 200, `cycle ${cycle}: reject should succeed`);
  }
  assert.deepEqual(await groups(env, daveToken), [], "never actually joined across any of the cycles");
});

test("inviting someone who is already a current member of the group is rejected", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g6i");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  const response = await inviteToGroup(env, alice.token, created.roomID, bob.code);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /already a member/i);
});

test("inviting someone who is not the caller's own friend is rejected even by an existing group member", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g7");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  const strangerToken = freshToken("g7d");
  const stranger = await registerUser(env, strangerToken, "Dave");
  const response = await inviteToGroup(env, bob.token, created.roomID, stranger.code);
  assert.equal(response.status, 400);
});

test("a member who leaves no longer sees the group, but the group survives for the rest", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g8");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);
  await acceptGroupInvite(env, carol.token, created.roomID);

  const response = await removeGroupMember(env, bob.token, created.roomID, bob.code);
  assert.equal(response.status, 200);
  assert.deepEqual(await groups(env, bob.token), []);
  const remaining = await groups(env, alice.token);
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].members.length, 2);
});

test("re-inviting someone who left the group is treated the same as inviting a brand-new member", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g8b");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);
  await removeGroupMember(env, bob.token, created.roomID, bob.code);

  const response = await inviteToGroup(env, alice.token, created.roomID, bob.code);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "pending");
  const bobInvites = await groupInvites(env, bob.token);
  assert.equal(bobInvites.length, 1);
  assert.equal(bobInvites[0].roomID, created.roomID);
});

// A former member's read position must not resurface once they rejoin —
// otherwise leaving and being re-invited would either dump years of
// history on them as unread, or (worse) silently mark genuinely new
// messages as already read from their old position.
test("accepting a re-invite after leaving starts unread counting fresh, not from the old membership's read position", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g8c");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  await sendMessage(env, alice.token, created.roomID, "第一便");
  await sendMessage(env, alice.token, created.roomID, "第二便");
  const bobKey = await env.STUDIQUO_DATA.get(`chat:code:${bob.code}`);
  const beforeLeave = await env.CHAT_ROOM.getByName(created.roomID).inboxState(bobKey);
  assert.equal(beforeLeave.unreadCount, 2);
  await env.CHAT_ROOM.getByName(created.roomID).markRead(bobKey, beforeLeave.latestID);

  await removeGroupMember(env, bob.token, created.roomID, bob.code);
  await sendMessage(env, alice.token, created.roomID, "抜けた後のメッセージ");

  await inviteToGroup(env, alice.token, created.roomID, bob.code);
  await acceptGroupInvite(env, bob.token, created.roomID);

  const afterRejoin = await env.CHAT_ROOM.getByName(created.roomID).inboxState(bobKey);
  assert.equal(afterRejoin.unreadCount, 0, "rejoining starts from the current end of history, not from the pre-leave read position");

  await sendMessage(env, alice.token, created.roomID, "再参加後の新着");
  const afterNewMessage = await env.CHAT_ROOM.getByName(created.roomID).inboxState(bobKey);
  assert.equal(afterNewMessage.unreadCount, 1, "genuinely new messages after rejoining still count as unread");
});

test("re-inviting immediately after leaving does not trip the already-a-member check", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g8d");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  // No await gap between leaving and re-inviting — the very next call after
  // removeParticipant resolves must already see the member gone.
  await removeGroupMember(env, bob.token, created.roomID, bob.code);
  const response = await inviteToGroup(env, alice.token, created.roomID, bob.code);

  assert.equal(response.status, 200, "must not be rejected as \"already a member\" right after leaving");
  assert.equal((await response.json()).status, "pending");
  const bobInvites = await groupInvites(env, bob.token);
  assert.equal(bobInvites.length, 1);
});

test("any current member can remove a different member, with no admin/owner distinction", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g9");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);
  await acceptGroupInvite(env, carol.token, created.roomID);

  // Bob (not the creator) removes Carol.
  const response = await removeGroupMember(env, bob.token, created.roomID, carol.code);
  assert.equal(response.status, 200);
  assert.deepEqual(await groups(env, carol.token), []);
});

test("renaming a group is reflected for every remaining member's own group list", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g10");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  const response = await renameGroup(env, alice.token, created.roomID, "受験対策グループ");
  assert.equal(response.status, 200);
  const aliceGroups = await groups(env, alice.token);
  const bobGroups = await groups(env, bob.token);
  assert.equal(aliceGroups[0].name, "受験対策グループ");
  assert.equal(bobGroups[0].name, "受験対策グループ");
});

test("a group can never be blocked — every blocking endpoint rejects it", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g11");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const response = await blockOtherParticipant(env, alice.token, created.roomID);
  assert.equal(response.status, 400);
});

test("group messages carry the sender's code and name, resolved once per distinct sender", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g13");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);

  await sendMessage(env, alice.token, created.roomID, "こんにちは");
  const sentByBob = await (await sendMessage(env, bob.token, created.roomID, "よろしく")).json();
  assert.equal(sentByBob.senderCode, bob.code);
  assert.equal(sentByBob.senderName, "Bob");
  assert.equal(sentByBob.senderKey, undefined);

  const list = await (await readMessages(env, alice.token, created.roomID)).json();
  assert.deepEqual(list.map(m => m.senderCode), [alice.code, bob.code]);
  assert.deepEqual(list.map(m => m.senderName), ["Alice", "Bob"]);
  assert.ok(list.every(m => m.senderKey === undefined));
});

test("inbox includes group conversations with their unread message count", async () => {
  const fixture = await deletionGroupFixture();
  await sendMessage(fixture.env, fixture.aliceToken, fixture.groupRoomID, "一件目");
  await sendMessage(fixture.env, fixture.aliceToken, fixture.groupRoomID, "二件目");

  const response = await worker.fetch(request("/api/chat/inbox", { token: fixture.bobToken }), fixture.env, noopCtx);
  assert.equal(response.status, 200);
  const entries = await response.json();
  const group = entries.find(entry => entry.roomID === fixture.groupRoomID);

  assert.ok(group, "the joined group must be present beside direct chats");
  assert.equal(group.kind, "group");
  assert.equal(group.unreadCount, 2);
  assert.equal(group.latestID, 2);
});

test("a group sender can cancel their message and every member sees it retracted", async () => {
  const fixture = await deletionGroupFixture();
  const sent = await (await sendMessage(
    fixture.env, fixture.aliceToken, fixture.groupRoomID, "取り消すメッセージ",
  )).json();

  const response = await cancelMessage(fixture.env, fixture.aliceToken, fixture.groupRoomID, sent.id);
  assert.equal(response.status, 200);

  const sendersView = await (await readMessages(
    fixture.env, fixture.aliceToken, fixture.groupRoomID,
  )).json();
  const membersView = await (await readMessages(
    fixture.env, fixture.bobToken, fixture.groupRoomID,
  )).json();
  for (const messages of [sendersView, membersView]) {
    assert.equal(messages[0].text, "");
    assert.equal(messages[0].isCanceled, true);
  }
});

test("POST /api/chat/groups allows up to 10 group actions per minute, then 429s", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "g12");

  let lastStatus = 200;
  for (let i = 0; i < 11; i += 1) {
    const response = await createGroup(env, alice.token, `Group ${i}`, [bob.code, carol.code]);
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

test("a group member can upload a group photo, and it's stored under the group rather than any one member", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga1");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  // Sized like an actual (resized) photo rather than a token few bytes —
  // well under the 300KB raw cap, but big enough to have caught the group
  // route once quietly capping the whole request body at 16KB regardless.
  const photo = Buffer.alloc(80_000, 7).toString("base64");
  const response = await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", photo);
  assert.equal(response.status, 200);
  const { avatarUpdatedAt } = await response.json();
  assert.ok(avatarUpdatedAt);

  const listed = await groups(env, alice.token);
  assert.equal(listed[0].avatarUpdatedAt, avatarUpdatedAt, "group listings expose the current icon revision");
  assert.equal(listed[0].code, created.code, "changing the icon does not rotate the group code");

  const downloaded = await downloadGroupAvatar(env, alice.token, created.roomID);
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.headers.get("content-type"), "image/jpeg");
  assert.equal(Buffer.from(await downloaded.arrayBuffer()).toString("base64"), photo);
});

test("an oversized group photo upload is rejected", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga2");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  // Decodes to 320,000 bytes — over the 300,000 raw cap — while its base64
  // encoding (~427,000 chars) still fits under the request body's own
  // 450,000-char ceiling, so this exercises the decoded-size check itself
  // rather than being rejected earlier for a merely-oversized request body.
  const oversized = Buffer.alloc(320_000, 1).toString("base64");
  const response = await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", oversized);
  assert.equal(response.status, 400);
});

test("a group photo upload with a disallowed content type is rejected", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga3");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const response = await uploadGroupAvatar(env, alice.token, created.roomID, "image/gif", Buffer.from("fake gif bytes").toString("base64"));
  assert.equal(response.status, 400);
});

test("a group photo upload with no image data is rejected", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga4");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const response = await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", "");
  assert.equal(response.status, 400);
});

test("someone who isn't a member of the group cannot upload its photo", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga5");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  // Bob was invited but never accepted — not yet a member.

  const response = await uploadGroupAvatar(env, bob.token, created.roomID, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));
  assert.equal(response.status, 403);
});

test("uploading a photo for a group that doesn't exist is rejected the same way as not being a member", async () => {
  const env = environment();
  const { alice } = await threeMutualFriends(env, "ga6");

  const response = await uploadGroupAvatar(env, alice.token, "f".repeat(64), "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));
  assert.equal(response.status, 403);
});

test("uploading a photo through a group-avatar URL that actually names a direct chat is rejected", async () => {
  const env = environment();
  const aliceToken = freshToken("ga7a");
  const bobToken = freshToken("ga7b");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);
  const directRoomID = (await friends(env, aliceToken))[0].roomID;

  const response = await uploadGroupAvatar(env, aliceToken, directRoomID, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));
  assert.equal(response.status, 400);
});

test("group photo uploads are rate-limited the same way other attachment uploads are", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga8");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  let lastStatus = 200;
  for (let i = 0; i < 11; i += 1) {
    const response = await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", Buffer.from(`photo ${i}`).toString("base64"));
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

test("uploading a new group photo replaces the old one rather than sitting alongside it", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "ga9");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", Buffer.from("first photo").toString("base64"));
  await uploadGroupAvatar(env, alice.token, created.roomID, "image/png", Buffer.from("second photo").toString("base64"));

  const downloaded = await downloadGroupAvatar(env, alice.token, created.roomID);
  assert.equal(downloaded.headers.get("content-type"), "image/png");
  assert.equal(Buffer.from(await downloaded.arrayBuffer()).toString(), "second photo");
});

test("any member of the group — not just whoever uploaded it — can download the group's photo", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "gb1");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await acceptGroupInvite(env, bob.token, created.roomID);
  await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));

  const downloaded = await downloadGroupAvatar(env, bob.token, created.roomID);
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.headers.get("content-type"), "image/jpeg");
  assert.equal(Buffer.from(await downloaded.arrayBuffer()).toString(), "fake jpeg bytes");
});

test("downloading a group's photo before anyone has uploaded one returns 404", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "gb2");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();

  const response = await downloadGroupAvatar(env, alice.token, created.roomID);
  assert.equal(response.status, 404);
});

test("someone who isn't a member of the group cannot download its photo", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "gb3");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  // Bob was invited but never accepted — not yet a member.
  await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));

  const response = await downloadGroupAvatar(env, bob.token, created.roomID);
  assert.equal(response.status, 403);
});

test("downloading a photo for a group that doesn't exist is rejected the same way as not being a member", async () => {
  const env = environment();
  const { alice } = await threeMutualFriends(env, "gb4");

  const response = await downloadGroupAvatar(env, alice.token, "f".repeat(64));
  assert.equal(response.status, 403);
});

test("downloading a group photo through a URL that actually names a direct chat is rejected", async () => {
  const env = environment();
  const aliceToken = freshToken("gb5a");
  const bobToken = freshToken("gb5b");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);
  const directRoomID = (await friends(env, aliceToken))[0].roomID;

  const response = await downloadGroupAvatar(env, aliceToken, directRoomID);
  assert.equal(response.status, 400);
});

test("a downloaded group photo is cached only privately and only briefly", async () => {
  const env = environment();
  const { alice, bob, carol } = await threeMutualFriends(env, "gb6");
  const created = await (await createGroup(env, alice.token, "Study Group", [bob.code, carol.code])).json();
  await uploadGroupAvatar(env, alice.token, created.roomID, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));

  const downloaded = await downloadGroupAvatar(env, alice.token, created.roomID);
  assert.equal(downloaded.headers.get("cache-control"), "private, max-age=60");
});

// Boundary coverage for the group member cap: chat-room.js's own
// MAX_GROUP_MEMBERS (50) is the real, hard limit (enforced at accept time),
// while groups.js's MAX_INVITED_MEMBERS (49) is a matching cap on a single
// create-group request's invite list and a "soft", early check on sending a
// further invite — the two are meant to describe the exact same limit from
// either side of "creator" vs. "everyone else". Directly seeds a room's
// participants (mirroring how the 500-friend-cap test below seeds a user's
// `friends` array) instead of driving 49 real people through real invite
// flows — only the one boundary-crossing action in each test needs to be
// real. Filler participant keys don't correspond to registered users; that's
// fine, since these tests only care about how many people are in the room.

// Seeds `count` fake friend entries directly onto `key`'s own record, the
// same shortcut the 500-friend-cap test below uses — these codes are never
// looked up as real users, so a create-group request that only cares about
// "how many codes were passed" doesn't need real registered friends.
async function seedFakeFriends(env, key, count, prefix) {
  const storageKey = `chat:user:${key}`;
  const user = await env.STUDIQUO_DATA.get(storageKey, "json");
  user.friends = [
    ...(user.friends ?? []),
    ...Array.from({ length: count }, (_, i) => ({
      code: `${prefix}${String(i).padStart(4, "0")}`, name: `Friend ${i}`, roomID: `room-${prefix}${i}`,
    })),
  ];
  await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
}

test("creating a group with exactly 49 invited friends succeeds — the cap is 49 invited plus the creator", async () => {
  const env = environment();
  const aliceToken = freshToken("cap1");
  const alice = await registerUser(env, aliceToken, "Alice");
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);
  await seedFakeFriends(env, aliceKey, 49, "CAP1F");

  const codes = Array.from({ length: 49 }, (_, i) => `CAP1F${String(i).padStart(4, "0")}`);
  const response = await createGroup(env, aliceToken, "Big Group", codes);
  assert.equal(response.status, 201);
});

test("creating a group with 50 invited friends is rejected — one over the cap", async () => {
  const env = environment();
  const aliceToken = freshToken("cap2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);
  await seedFakeFriends(env, aliceKey, 50, "CAP2F");

  const codes = Array.from({ length: 50 }, (_, i) => `CAP2F${String(i).padStart(4, "0")}`);
  const response = await createGroup(env, aliceToken, "Too Big Group", codes);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /many/i);
});

test("the 50th member can join once the group has exactly 49 — filling the very last seat", async () => {
  const env = environment();
  const aliceToken = freshToken("cap3a");
  const bobToken = freshToken("cap3b");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);

  const roomID = "3".repeat(64);
  const fillerKeys = Array.from({ length: 48 }, (_, i) => `filler-cap3-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, [aliceKey, ...fillerKeys], { kind: "group", name: "Almost Full Group", creatorCode: alice.code, creatorName: "Alice" },
  );
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(aliceKey)).members.length, 49);

  const inviteResponse = await inviteToGroup(env, aliceToken, roomID, bob.code);
  assert.equal(inviteResponse.status, 200);

  const acceptResponse = await acceptGroupInvite(env, bobToken, roomID);
  assert.equal(acceptResponse.status, 200);
  const accepted = await acceptResponse.json();
  assert.equal(accepted.members.length, 50);
});

test("inviting a new friend into an already-full (50-member) group is rejected before any invite is sent", async () => {
  const env = environment();
  const aliceToken = freshToken("cap4a");
  const daveToken = freshToken("cap4d");
  const alice = await registerUser(env, aliceToken, "Alice");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, aliceToken, dave.code);
  await acceptRequest(env, daveToken, alice.code);
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);

  const roomID = "4".repeat(64);
  const fillerKeys = Array.from({ length: 49 }, (_, i) => `filler-cap4-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, [aliceKey, ...fillerKeys], { kind: "group", name: "Full Group", creatorCode: alice.code, creatorName: "Alice" },
  );
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(aliceKey)).members.length, 50);

  const response = await inviteToGroup(env, aliceToken, roomID, dave.code);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /full/i);
  assert.deepEqual(await groupInvites(env, daveToken), []);
});

// Regression coverage for "accepting into a group that filled up in the
// meantime leaves the invitee in limbo": groups.js's accept handler
// atomically consumes the invitee's pending invite (and optimistically adds
// the room to their own group list) *before* it knows whether
// chat-room.js's addParticipant will actually succeed — that ordering exists
// so an accept racing a reject of the very same invite still resolves
// atomically (see resolveIncomingGroupInvite's own comment). If
// addParticipant then fails because the group filled up first, that
// optimistic mutation must be rolled back — otherwise the invitee is left
// with a phantom `groups` entry for a room they were never actually added
// to, and no invite left to retry once a seat opens up.
test("accepting a pending invite into a group that filled up in the meantime is rejected, not silently added past the cap", async () => {
  const env = environment();
  const daveToken = freshToken("cap5d");
  const dave = await registerUser(env, daveToken, "Dave");
  const daveKey = await env.STUDIQUO_DATA.get(`chat:code:${dave.code}`);

  const roomID = "5".repeat(64);
  const fillerKeys = Array.from({ length: 50 }, (_, i) => `filler-cap5-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, fillerKeys, { kind: "group", name: "Full Group", creatorCode: "SEEDCODE", creatorName: "Seed" },
  );
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(fillerKeys[0])).members.length, 50);

  // Dave's invite was issued back when the group still had room — seeded
  // directly, since the real invite endpoint would itself now be blocked by
  // the "already full" check exercised in the previous test.
  await env.USER_REGISTRY.getByName(daveKey).addIncomingGroupInvite(daveKey, roomID, "Full Group", "SEEDCODE", "Seed");

  const response = await acceptGroupInvite(env, daveToken, roomID);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /full/i);

  // Dave must not have actually joined the room...
  const roomMembers = await env.CHAT_ROOM.getByName(roomID).groupInfo(fillerKeys[0]);
  assert.equal(roomMembers.members.length, 50);
  assert.ok(!roomMembers.members.some(member => member.key === daveKey));
  // ...nor be left with a phantom entry in his own group list...
  const daveRecord = await env.STUDIQUO_DATA.get(`chat:user:${daveKey}`, "json");
  assert.ok(!(daveRecord.groups ?? []).some(item => item.roomID === roomID), "must not be left with a group entry for a room never actually joined");
  // ...and his invite should still be there to retry once a seat opens up,
  // not silently discarded.
  assert.deepEqual((await groupInvites(env, daveToken)).map(item => item.roomID), [roomID]);
});

// End-to-end companion to the previous test: same "invite outlives the
// group filling up" setup, but checked through the actual client-facing
// endpoints (GET /api/chat/groups, GET /api/chat/group-invites) rather than
// reading the invitee's own stored record directly, and carried all the way
// through to a successful retry once a seat frees up — the two-part
// behavior a real client would actually observe: no phantom membership
// right after the failed accept, and a genuinely working invite afterward.
test("a rejected accept leaves no phantom group in the invitee's own list, and a later retry once a seat frees up actually succeeds", async () => {
  const env = environment();
  const daveToken = freshToken("cap6d");
  const dave = await registerUser(env, daveToken, "Dave");
  const daveKey = await env.STUDIQUO_DATA.get(`chat:code:${dave.code}`);

  const roomID = "6".repeat(64);
  const fillerKeys = Array.from({ length: 50 }, (_, i) => `filler-cap6-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, fillerKeys, { kind: "group", name: "Full Group", creatorCode: "SEEDCODE", creatorName: "Seed" },
  );
  await env.USER_REGISTRY.getByName(daveKey).addIncomingGroupInvite(daveKey, roomID, "Full Group", "SEEDCODE", "Seed");

  const firstAttempt = await acceptGroupInvite(env, daveToken, roomID);
  assert.equal(firstAttempt.status, 400);

  // Right after the failed accept: Dave's own "my groups" list must not
  // show this room (he was never actually added to it)...
  assert.deepEqual(await groups(env, daveToken), []);
  // ...and his "pending invites" list must still show it, not have quietly
  // lost it.
  assert.deepEqual((await groupInvites(env, daveToken)).map(item => item.roomID), [roomID]);

  // A seat frees up — one existing member leaves.
  await env.CHAT_ROOM.getByName(roomID).removeParticipant(fillerKeys[0], fillerKeys[1]);
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(fillerKeys[0])).members.length, 49);

  // The same invite, retried, now actually succeeds — proof it wasn't just
  // left dangling but genuinely still usable.
  const secondAttempt = await acceptGroupInvite(env, daveToken, roomID);
  assert.equal(secondAttempt.status, 200);
  assert.deepEqual((await groups(env, daveToken)).map(item => item.roomID), [roomID]);
  assert.deepEqual(await groupInvites(env, daveToken), []);
});

// Concurrency coverage for the group member cap: with exactly one seat left,
// several people accepting their own (independently valid) pending invites
// at nearly the same moment must not all get in — chat-room.js's
// addParticipant is what actually enforces MAX_GROUP_MEMBERS, and it must do
// so as a genuine "first past the post" race, not let the room's count
// overshoot 50 just because several accepts were in flight together.
test("when only one seat remains, simultaneous accepts from different people race for it — exactly one wins, the rest are rejected cleanly", async () => {
  const env = environment();
  const names = ["Bob", "Carol", "Dave"];
  const tokens = names.map((_, i) => freshToken(`race${i}`));
  const users = await Promise.all(names.map((name, i) => registerUser(env, tokens[i], name)));
  const keys = await Promise.all(users.map(user => env.STUDIQUO_DATA.get(`chat:code:${user.code}`)));

  const roomID = "7".repeat(64);
  const fillerKeys = Array.from({ length: 49 }, (_, i) => `filler-cap7-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, fillerKeys, { kind: "group", name: "One Seat Left", creatorCode: "SEEDCODE", creatorName: "Seed" },
  );
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(fillerKeys[0])).members.length, 49);

  // All three invites are independently valid — each of Bob, Carol, and Dave
  // was genuinely invited while there was still room; the race is purely
  // about who gets to the single remaining seat first.
  await Promise.all(keys.map(key =>
    env.USER_REGISTRY.getByName(key).addIncomingGroupInvite(key, roomID, "One Seat Left", "SEEDCODE", "Seed")
  ));

  const responses = await Promise.all(tokens.map(token => acceptGroupInvite(env, token, roomID)));
  const statuses = responses.map(response => response.status);
  assert.equal(statuses.filter(status => status === 200).length, 1, "exactly one of the three simultaneous accepts must win the last seat");
  assert.equal(statuses.filter(status => status === 400).length, 2, "the other two must be rejected outright, not silently squeeze in past the cap");

  const finalRoom = await env.CHAT_ROOM.getByName(roomID).groupInfo(fillerKeys[0]);
  assert.equal(finalRoom.members.length, 50, "the room must land at exactly 50, never over");

  // The losers of the race must not be left in limbo either — same
  // rollback behavior as the sequential case, just now exercised under
  // real concurrent load.
  for (let i = 0; i < tokens.length; i += 1) {
    if (statuses[i] === 200) {
      assert.deepEqual((await groups(env, tokens[i])).map(item => item.roomID), [roomID], `${names[i]} won the race and must actually be a member`);
    } else {
      assert.deepEqual(await groups(env, tokens[i]), [], `${names[i]} lost the race and must not show a phantom membership`);
      assert.deepEqual((await groupInvites(env, tokens[i])).map(item => item.roomID), [roomID], `${names[i]}'s invite must survive the loss so they can retry`);
    }
  }
});

// Coverage for the cap not being a one-way ratchet: a group that has been
// full stays that way only as long as it actually has 50 members — once one
// leaves, both of the checks that enforce the cap (groups.js's own
// early "is this group already full" check on sending an invite, and
// chat-room.js's addParticipant at accept time) must let it fill back up to
// 50 again, not stay stuck treating a group as full forever just because it
// once was.
test("after a full group loses a member, a new invite can be sent and accepted, refilling it back to exactly 50", async () => {
  const env = environment();
  const aliceToken = freshToken("cap8a");
  const eveToken = freshToken("cap8e");
  const alice = await registerUser(env, aliceToken, "Alice");
  const eve = await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, eve.code);
  await acceptRequest(env, eveToken, alice.code);
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);

  const roomID = "8".repeat(64);
  const fillerKeys = Array.from({ length: 49 }, (_, i) => `filler-cap8-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, [aliceKey, ...fillerKeys], { kind: "group", name: "Cap Test Group", creatorCode: alice.code, creatorName: "Alice" },
  );
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(aliceKey)).members.length, 50);

  // While full, inviting Eve is rejected — same soft check exercised in the
  // "already-full" boundary test above.
  const blockedInvite = await inviteToGroup(env, aliceToken, roomID, eve.code);
  assert.equal(blockedInvite.status, 400);
  assert.match((await blockedInvite.json()).error, /full/i);

  // One existing member leaves, freeing a seat.
  await env.CHAT_ROOM.getByName(roomID).removeParticipant(fillerKeys[0], fillerKeys[0]);
  assert.equal((await env.CHAT_ROOM.getByName(roomID).groupInfo(aliceKey)).members.length, 49);

  // The exact same invite that was rejected a moment ago now goes through...
  const inviteResponse = await inviteToGroup(env, aliceToken, roomID, eve.code);
  assert.equal(inviteResponse.status, 200);

  // ...and Eve can actually join, bringing the group back to exactly 50.
  const acceptResponse = await acceptGroupInvite(env, eveToken, roomID);
  assert.equal(acceptResponse.status, 200);
  const accepted = await acceptResponse.json();
  assert.equal(accepted.members.length, 50);
});

// Locks down the exact status code and wording for each of the three
// distinct places the member cap can reject a request — earlier tests above
// only loosely pattern-matched these (e.g. /full/i); this pins the literal
// response body so a future refactor that quietly changes the status code
// or rewords the message (breaking whatever the client matches on) fails a
// test instead of only showing up as a support report.
test("each cap-related rejection uses the expected HTTP status and a specific, matching error message", async () => {
  const env = environment();
  const aliceToken = freshToken("cap9a");
  const daveToken = freshToken("cap9d");
  const alice = await registerUser(env, aliceToken, "Alice");
  const dave = await registerUser(env, daveToken, "Dave");
  await addFriend(env, aliceToken, dave.code);
  await acceptRequest(env, daveToken, alice.code);
  const aliceKey = await env.STUDIQUO_DATA.get(`chat:code:${alice.code}`);

  // 1) Creating a group with one too many invited friends.
  await seedFakeFriends(env, aliceKey, 50, "CAP9F");
  const codes = Array.from({ length: 50 }, (_, i) => `CAP9F${String(i).padStart(4, "0")}`);
  const createResponse = await createGroup(env, aliceToken, "Too Big", codes);
  assert.equal(createResponse.status, 400);
  assert.deepEqual(await createResponse.json(), { error: "Too many members for one group." });

  // 2) Sending a new invite into an already-full existing group.
  const roomID = "9".repeat(64);
  const fillerKeys = Array.from({ length: 49 }, (_, i) => `filler-cap9-${i}`);
  await env.CHAT_ROOM.getByName(roomID).initialize(
    roomID, [aliceKey, ...fillerKeys], { kind: "group", name: "Full Group", creatorCode: alice.code, creatorName: "Alice" },
  );
  const inviteResponse = await inviteToGroup(env, aliceToken, roomID, dave.code);
  assert.equal(inviteResponse.status, 400);
  assert.deepEqual(await inviteResponse.json(), { error: "This group is full." });

  // 3) Accepting an invite into a group that has since filled up — same
  // wording as (2), since the client can't distinguish the two situations
  // (nor does it need to: both just mean "no room right now").
  const daveKey = await env.STUDIQUO_DATA.get(`chat:code:${dave.code}`);
  await env.USER_REGISTRY.getByName(daveKey).addIncomingGroupInvite(daveKey, roomID, "Full Group", alice.code, "Alice");
  const acceptResponse = await acceptGroupInvite(env, daveToken, roomID);
  assert.equal(acceptResponse.status, 400);
  assert.deepEqual(await acceptResponse.json(), { error: "This group is full." });
});

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

// Regression coverage for the invite-link add path: unlike POST
// /api/chat/friends above, redeeming the *other* person's link token must
// create a mutual friendship immediately — no pending request, no separate
// accept step on either side.
test("redeeming an invite-link token creates an immediate mutual friendship with no pending request", async () => {
  const env = environment();
  const aliceToken = freshToken("li1");
  const bobToken = freshToken("li2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  assert.ok(bob.linkToken, "registration must return a link token");
  assert.notEqual(bob.linkToken, bob.code, "the link token must differ from the manually-typed friend code");

  const response = await addFriendViaLink(env, aliceToken, bob.linkToken);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.status, "added");
  assert.equal(body.code, bob.code);
  assert.equal(body.name, "Bob");

  const aliceFriends = await friends(env, aliceToken);
  assert.equal(aliceFriends.length, 1);
  assert.equal(aliceFriends[0].code, bob.code);
  assert.equal(aliceFriends[0].roomID, body.roomID);

  const bobFriends = await friends(env, bobToken);
  assert.equal(bobFriends.length, 1);
  assert.equal(bobFriends[0].code, alice.code);
  assert.equal(bobFriends[0].roomID, body.roomID);

  // No pending-request bookkeeping should exist anywhere for this pair.
  assert.deepEqual(await incomingRequests(env, aliceToken), []);
  assert.deepEqual(await incomingRequests(env, bobToken), []);
  assert.deepEqual(await outgoingRequests(env, aliceToken), []);
  assert.deepEqual(await outgoingRequests(env, bobToken), []);
});

test("typing a friend's code by hand cannot be used to reach the link-add shortcut", async () => {
  const env = environment();
  const aliceToken = freshToken("li3");
  const bobToken = freshToken("li4");
  await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  const response = await addFriendViaLink(env, aliceToken, bob.code);
  assert.equal(response.status, 404);
  assert.deepEqual(await friends(env, aliceToken), []);
  assert.deepEqual(await friends(env, bobToken), []);
});

test("redeeming an invite-link token twice is a harmless already_friends no-op, not a duplicate friend", async () => {
  const env = environment();
  const aliceToken = freshToken("li5");
  const bobToken = freshToken("li6");
  await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");

  const first = await addFriendViaLink(env, aliceToken, bob.linkToken);
  assert.equal((await first.json()).status, "added");
  const second = await addFriendViaLink(env, aliceToken, bob.linkToken);
  assert.equal(second.status, 200);
  assert.equal((await second.json()).status, "already_friends");

  assert.equal((await friends(env, aliceToken)).length, 1);
  assert.equal((await friends(env, bobToken)).length, 1);
  assert.equal(env.CHAT_ROOM.initializeCalls.count, 1);
});

test("redeeming your own invite-link token is rejected with a specific message", async () => {
  const env = environment();
  const aliceToken = freshToken("li7");
  const alice = await registerUser(env, aliceToken, "Alice");

  const response = await addFriendViaLink(env, aliceToken, alice.linkToken);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /cannot add yourself/i);
  assert.deepEqual(await friends(env, aliceToken), []);
});

test("redeeming an invite-link token that does not exist returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("li8");
  await registerUser(env, aliceToken, "Alice");

  const response = await addFriendViaLink(env, aliceToken, "NOSUCH1");
  assert.equal(response.status, 404);
});

test("a malformed invite-link token is rejected with 400 instead of reaching the KV lookup", async () => {
  const env = environment();
  const aliceToken = freshToken("li9");
  await registerUser(env, aliceToken, "Alice");

  const response = await addFriendViaLink(env, aliceToken, "short");
  assert.equal(response.status, 400);
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

// Regression coverage for "a friend's profile photo never showed up
// anywhere but a generic placeholder icon, no matter what was set in the
// profile screen": nothing about it ever reached the server before this.
test("a friend can download an uploaded avatar, and sees it reflected in friends()", async () => {
  const env = environment();
  const aliceToken = freshToken("z0");
  const bobToken = freshToken("z1");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  await acceptRequest(env, bobToken, alice.code);

  const uploadResponse = await uploadAvatar(env, aliceToken, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));
  assert.equal(uploadResponse.status, 200);
  const { avatarUpdatedAt } = await uploadResponse.json();
  assert.ok(avatarUpdatedAt);

  assert.equal((await friends(env, bobToken))[0].avatarUpdatedAt, avatarUpdatedAt);

  const downloadResponse = await downloadAvatar(env, bobToken, alice.code);
  assert.equal(downloadResponse.status, 200);
  assert.equal(downloadResponse.headers.get("content-type"), "image/jpeg");
  assert.equal(Buffer.from(await downloadResponse.arrayBuffer()).toString(), "fake jpeg bytes");
});

test("you can always download your own avatar", async () => {
  const env = environment();
  const aliceToken = freshToken("z2");
  const alice = await registerUser(env, aliceToken, "Alice");
  await uploadAvatar(env, aliceToken, "image/png", Buffer.from("fake png bytes").toString("base64"));

  const response = await downloadAvatar(env, aliceToken, alice.code);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
});

test("a stranger cannot download someone else's avatar", async () => {
  const env = environment();
  const aliceToken = freshToken("z3");
  const strangerToken = freshToken("z4");
  const alice = await registerUser(env, aliceToken, "Alice");
  await registerUser(env, strangerToken, "Stranger");
  await uploadAvatar(env, aliceToken, "image/jpeg", Buffer.from("fake jpeg bytes").toString("base64"));

  const response = await downloadAvatar(env, strangerToken, alice.code);
  assert.equal(response.status, 404);
});

test("downloading an avatar that was never uploaded returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("z5");
  const alice = await registerUser(env, aliceToken, "Alice");

  const response = await downloadAvatar(env, aliceToken, alice.code);
  assert.equal(response.status, 404);
});

test("an avatar upload with a disallowed content type is rejected", async () => {
  const env = environment();
  const aliceToken = freshToken("z6");
  await registerUser(env, aliceToken, "Alice");

  const response = await uploadAvatar(env, aliceToken, "image/gif", Buffer.from("fake gif bytes").toString("base64"));
  assert.equal(response.status, 400);
});

test("an oversized avatar upload is rejected", async () => {
  const env = environment();
  const aliceToken = freshToken("z7");
  await registerUser(env, aliceToken, "Alice");

  // Decodes to 320,000 bytes — over MAX_AVATAR_BYTES (300,000) — while its
  // base64 encoding (~427,000 chars) still fits under MAX_AVATAR_UPLOAD_BODY
  // (450,000), so this actually exercises the decoded-size check itself
  // rather than being rejected earlier for a merely-oversized request body.
  const oversized = Buffer.alloc(320_000, 1).toString("base64");
  const response = await uploadAvatar(env, aliceToken, "image/jpeg", oversized);
  assert.equal(response.status, 400);
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

test("a new session for the same account keeps its friend code and access to both sides of a chat", async () => {
  const env = environment();
  const aliceToken = freshToken("ra");
  const bobToken = freshToken("rb");
  const aliceNewToken = freshToken("rn");
  const account = "email:alice@example.test";
  const tokenHash = token => createHash("sha256").update(token).digest("hex");
  await env.STUDIQUO_DATA.put(`session:${tokenHash(aliceToken)}`, JSON.stringify({ sub: account }));
  await env.STUDIQUO_DATA.put(`session:${tokenHash(aliceNewToken)}`, JSON.stringify({ sub: account }));

  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const roomID = (await (await acceptRequest(env, bobToken, alice.code)).json()).roomID;
  assert.equal((await sendMessage(env, aliceToken, roomID, "before sign-in")).status, 200);

  assert.equal((await registerUser(env, aliceNewToken, "Alice")).code, alice.code);
  assert.equal((await friends(env, aliceNewToken))[0].roomID, roomID);
  assert.equal((await readMessages(env, aliceNewToken, roomID)).status, 200);
  assert.equal((await sendMessage(env, aliceNewToken, roomID, "after sign-in")).status, 200);
  const received = await (await readMessages(env, bobToken, roomID)).json();
  assert.deepEqual(received.map(message => message.text), ["before sign-in", "after sign-in"]);
});

test("switching login methods preserves the friend code, groups, and chat history", async () => {
  const env = environment();
  const googleToken = freshToken("q");
  const localToken = freshToken("w");
  const bobToken = freshToken("e");
  const canonical = "google:shared-google-sub";
  const tokenHash = token => createHash("sha256").update(token).digest("hex");

  await env.STUDIQUO_DATA.put(`session:${tokenHash(googleToken)}`, JSON.stringify({ sub: "google:shared-google-sub" }));
  await env.STUDIQUO_DATA.put(`session:${tokenHash(localToken)}`, JSON.stringify({ sub: "email:alice@example.test" }));
  await env.STUDIQUO_DATA.put("identity-canonical:google:shared-google-sub", canonical);
  await env.STUDIQUO_DATA.put("identity-canonical:email:alice@example.test", canonical);

  const alice = await registerUser(env, googleToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, googleToken, bob.code);
  const directRoomID = (await (await acceptRequest(env, bobToken, alice.code)).json()).roomID;
  assert.equal((await sendMessage(env, googleToken, directRoomID, "direct history")).status, 200);

  const group = await (await createGroup(env, googleToken, "Shared Study Group", [bob.code])).json();
  assert.equal((await acceptGroupInvite(env, bobToken, group.roomID)).status, 200);
  assert.equal((await sendMessage(env, googleToken, group.roomID, "group history")).status, 200);

  const switched = await registerUser(env, localToken, "Alice");
  assert.equal(switched.code, alice.code);
  assert.equal((await friends(env, localToken))[0].roomID, directRoomID);
  assert.deepEqual((await groups(env, localToken)).map(item => item.roomID), [group.roomID]);

  const directHistory = await (await readMessages(env, localToken, directRoomID)).json();
  const groupHistory = await (await readMessages(env, localToken, group.roomID)).json();
  assert.deepEqual(directHistory.map(message => message.text), ["direct history"]);
  assert.deepEqual(groupHistory.map(message => message.text), ["group history"]);
});

test("an existing token-derived friendship and room survive a later sign-in", async () => {
  const env = environment();
  const oldToken = freshToken("lu");
  const newToken = freshToken("ln");
  const bobToken = freshToken("lb");
  const oldKey = createHash("sha256").update(oldToken).digest("hex");
  const oldCode = "LEGACY1";
  await env.STUDIQUO_DATA.put(`chat:user:${oldKey}`, JSON.stringify({
    key: oldKey, name: "Alice", code: oldCode, friends: [],
  }));
  await env.STUDIQUO_DATA.put(`chat:code:${oldCode}`, oldKey);
  const account = "email:legacy@example.test";
  for (const token of [oldToken, newToken]) {
    const hash = createHash("sha256").update(token).digest("hex");
    await env.STUDIQUO_DATA.put(`session:${hash}`, JSON.stringify({ sub: account }));
  }

  assert.equal((await registerUser(env, oldToken, "Alice")).code, oldCode);
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, oldToken, bob.code);
  const roomID = (await (await acceptRequest(env, bobToken, oldCode)).json()).roomID;
  assert.equal((await sendMessage(env, oldToken, roomID, "before sign-in")).status, 200);

  assert.equal((await registerUser(env, newToken, "Alice")).code, oldCode);
  assert.equal((await friends(env, newToken))[0].roomID, roomID);
  assert.equal((await readMessages(env, newToken, roomID)).status, 200);
  assert.equal((await sendMessage(env, newToken, roomID, "after sign-in")).status, 200);
  const received = await (await readMessages(env, bobToken, roomID)).json();
  assert.deepEqual(received.map(message => message.text), ["before sign-in", "after sign-in"]);
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

// Regression coverage for "materials sent before attachments could be
// re-shared are permanently unopenable": editing a message's text in place
// is how the sender's device repairs a legacy attachment reference once
// it's re-rendered and re-uploaded the material — this must actually reach
// every reader of the room, not just the sender's own device.

test("editing a message updates its text for both the sender and the recipient", async () => {
  const env = environment();
  const aliceToken = freshToken("ce1");
  const bobToken = freshToken("ce2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "legacy attachment reference")).json();
  const editResponse = await editMessage(env, aliceToken, roomID, sent.id, "repaired attachment reference");
  assert.equal(editResponse.status, 200);
  assert.equal((await editResponse.json()).status, "edited");

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].text, "repaired attachment reference");

  const bobsView = await (await readMessages(env, bobToken, roomID)).json();
  assert.equal(bobsView[0].text, "repaired attachment reference", "the recipient must see the repaired text too");
});

test("only the original sender can edit their own message", async () => {
  const env = environment();
  const aliceToken = freshToken("ce3");
  const bobToken = freshToken("ce4");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "Alice's message")).json();
  const bobsAttempt = await editMessage(env, bobToken, roomID, sent.id, "tampered");
  assert.equal(bobsAttempt.status, 403);

  const alicesView = await (await readMessages(env, aliceToken, roomID)).json();
  assert.equal(alicesView[0].text, "Alice's message", "an unauthorized edit attempt must not have any effect");
});

test("someone outside the room cannot edit a message in it", async () => {
  const env = environment();
  const aliceToken = freshToken("ce5");
  const bobToken = freshToken("ce6");
  const eveToken = freshToken("ce7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "private")).json();
  const evesAttempt = await editMessage(env, eveToken, roomID, sent.id, "tampered");
  assert.equal(evesAttempt.status, 403);
});

test("editing a nonexistent message id returns 404", async () => {
  const env = environment();
  const aliceToken = freshToken("ce8");
  const bobToken = freshToken("ce9");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const response = await editMessage(env, aliceToken, accepted.roomID, 999, "repaired");
  assert.equal(response.status, 404);
});

test("editing a canceled message does not resurrect it", async () => {
  const env = environment();
  const aliceToken = freshToken("ce10");
  const bobToken = freshToken("ce11");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "oops, wrong chat")).json();
  await cancelMessage(env, aliceToken, roomID, sent.id);

  const editResponse = await editMessage(env, aliceToken, roomID, sent.id, "repaired attachment reference");
  assert.equal((await editResponse.json()).status, "canceled");

  const bobsView = await (await readMessages(env, bobToken, roomID)).json();
  assert.equal(bobsView[0].text, "", "a retracted message must not come back just because an edit was attempted on it");
  assert.equal(bobsView[0].isCanceled, true);
});

test("looking up specific message ids returns their current text regardless of how old they are", async () => {
  const env = environment();
  const aliceToken = freshToken("cl1");
  const bobToken = freshToken("cl2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const first = await (await sendMessage(env, aliceToken, roomID, "legacy attachment reference")).json();
  // Many messages in between — this is exactly the scenario
  // `listMessages(after)`'s rolling reconcile window would miss.
  for (let i = 0; i < 25; i += 1) {
    await sendMessage(env, aliceToken, roomID, `filler ${i}`);
  }
  await editMessage(env, aliceToken, roomID, first.id, "repaired attachment reference");

  const lookupResponse = await lookupMessages(env, bobToken, roomID, [first.id]);
  assert.equal(lookupResponse.status, 200);
  const looked = await lookupResponse.json();
  assert.equal(looked.length, 1);
  assert.equal(looked[0].id, first.id);
  assert.equal(looked[0].text, "repaired attachment reference");
});

test("someone outside the room cannot look up messages in it", async () => {
  const env = environment();
  const aliceToken = freshToken("cl3");
  const bobToken = freshToken("cl4");
  const eveToken = freshToken("cl5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const roomID = accepted.roomID;

  const sent = await (await sendMessage(env, aliceToken, roomID, "private")).json();
  const evesAttempt = await lookupMessages(env, eveToken, roomID, [sent.id]);
  assert.equal(evesAttempt.status, 403);
});

test("looking up an empty id list returns an empty result instead of erroring", async () => {
  const env = environment();
  const aliceToken = freshToken("cl6");
  const bobToken = freshToken("cl7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const response = await lookupMessages(env, aliceToken, accepted.roomID, []);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), []);
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

// Regression coverage for a real gap: unlike message sends, attachment
// uploads (each up to 6MB) had no rate limit at all — an authenticated
// caller could spam a room's storage with unlimited uploads.
test("POST /api/chat/rooms/:id/attachments allows up to 10 per minute, then 429s", async () => {
  const env = environment();
  const aliceToken = freshToken("u0");
  const bobToken = freshToken("u1");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZkAAAAASUVORK5CYII=";
  for (let i = 0; i < 10; i++) {
    const response = await uploadAttachment(env, aliceToken, accepted.roomID, "image/png", tinyPNG);
    assert.equal(response.status, 201);
  }
  const overLimit = await uploadAttachment(env, aliceToken, accepted.roomID, "image/png", tinyPNG);
  assert.equal(overLimit.status, 429);
});

test("one caller's exhausted attachment-upload limit does not affect a different caller", async () => {
  const env = environment();
  const aliceToken = freshToken("u2");
  const bobToken = freshToken("u3");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZkAAAAASUVORK5CYII=";
  for (let i = 0; i < 10; i++) {
    await uploadAttachment(env, aliceToken, accepted.roomID, "image/png", tinyPNG);
  }
  assert.equal((await uploadAttachment(env, aliceToken, accepted.roomID, "image/png", tinyPNG)).status, 429);

  const bobsOwnAttempt = await uploadAttachment(env, bobToken, accepted.roomID, "image/png", tinyPNG);
  assert.equal(bobsOwnAttempt.status, 201);
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

// Regression coverage for "no way to stop an unwanted friend from messaging
// you": blocking must actually be enforced server-side (any client can be
// modified to ignore a purely client-side block), and it must not tell the
// blocked person why their message failed.

test("blocking the other participant prevents them from sending, but not the blocker", async () => {
  const env = environment();
  const aliceToken = freshToken("b1");
  const bobToken = freshToken("b2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  const blockResponse = await blockOtherParticipant(env, aliceToken, accepted.roomID);
  assert.equal(blockResponse.status, 200);
  assert.deepEqual(await blockResponse.json(), { status: "blocked" });

  const blockedSend = await sendMessage(env, bobToken, accepted.roomID, "let me back in");
  assert.equal(blockedSend.status, 403);
  // Deliberately vague — must not reveal "you have been blocked" to the
  // blocked person.
  assert.doesNotMatch((await blockedSend.json()).error.toLowerCase(), /block/);

  const stillWorks = await sendMessage(env, aliceToken, accepted.roomID, "I can still talk");
  assert.equal(stillWorks.status, 200);
});

test("inbox counts only new incoming messages and shares read progress across devices", async () => {
  const env = environment();
  const aliceToken = freshToken("in1");
  const bobToken = freshToken("in2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const { roomID } = await (await acceptRequest(env, bobToken, alice.code)).json();
  const inbox = async token => (await (await worker.fetch(request("/api/chat/inbox", { token }), env, noopCtx)).json())[0];

  const first = await (await sendMessage(env, aliceToken, roomID, "one")).json();
  const second = await (await sendMessage(env, aliceToken, roomID, "two")).json();
  assert.equal((await inbox(bobToken)).unreadCount, 2);
  assert.equal((await inbox(aliceToken)).unreadCount, 0);

  const read = await worker.fetch(request(`/api/chat/rooms/${roomID}/read`, {
    method: "POST", token: bobToken, body: { throughID: first.id },
  }), env, noopCtx);
  assert.equal(read.status, 200);
  assert.equal((await inbox(bobToken)).unreadCount, 1);
  await worker.fetch(request(`/api/chat/rooms/${roomID}/read`, {
    method: "POST", token: bobToken, body: { throughID: second.id },
  }), env, noopCtx);
  assert.equal((await inbox(bobToken)).unreadCount, 0);
  const canceled = await (await sendMessage(env, aliceToken, roomID, "withdrawn")).json();
  await worker.fetch(request(`/api/chat/rooms/${roomID}/messages/${canceled.id}/cancel`, {
    method: "POST", token: aliceToken,
  }), env, noopCtx);
  assert.equal((await inbox(bobToken)).unreadCount, 0);
});

test("deleting a blocked friend removes both friendships but retains history and the block", async () => {
  const env = environment();
  const aliceToken = freshToken("rm1");
  const bobToken = freshToken("rm2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const { roomID } = await (await acceptRequest(env, bobToken, alice.code)).json();
  await sendMessage(env, aliceToken, roomID, "retained history");
  await blockOtherParticipant(env, aliceToken, roomID);
  const blockedBeforeRemoval = await worker.fetch(request("/api/chat/friends/blocked", { token: aliceToken }), env, noopCtx);
  assert.deepEqual((await blockedBeforeRemoval.json()).map(item => item.code), [bob.code]);

  const removed = await worker.fetch(request(`/api/chat/friends/${bob.code}`, {
    method: "DELETE", token: aliceToken,
  }), env, noopCtx);
  assert.equal(removed.status, 200);
  assert.equal((await friends(env, aliceToken)).length, 0);
  assert.equal((await friends(env, bobToken)).length, 0);
  assert.equal((await worker.fetch(request(`/api/chat/friends/${bob.code}`, {
    method: "DELETE", token: aliceToken,
  }), env, noopCtx)).status, 200);
  assert.equal((await sendMessage(env, aliceToken, roomID, "after removal")).status, 403);
  assert.equal((await uploadAttachment(env, aliceToken, roomID, "image/jpeg", "aGVsbG8=")).status, 403);
  const history = await worker.fetch(request(`/api/chat/rooms/${roomID}/messages`, { token: aliceToken }), env, noopCtx);
  assert.equal((await history.json())[0].text, "retained history");

  const blocked = await worker.fetch(request("/api/chat/friends/blocked", { token: aliceToken }), env, noopCtx);
  assert.deepEqual((await blocked.json()).map(item => item.code), [bob.code]);
  assert.equal((await addFriend(env, bobToken, alice.code)).status, 403);
  const unblocked = await worker.fetch(request(`/api/chat/rooms/${roomID}/unblock`, {
    method: "POST", token: aliceToken,
  }), env, noopCtx);
  assert.equal(unblocked.status, 200);
  const empty = await worker.fetch(request("/api/chat/friends/blocked", { token: aliceToken }), env, noopCtx);
  assert.deepEqual(await empty.json(), []);
  assert.equal((await addFriend(env, bobToken, alice.code)).status, 200);
  assert.equal((await acceptRequest(env, aliceToken, bob.code)).status, 200);
  assert.equal((await friends(env, aliceToken)).length, 1);
  assert.equal((await friends(env, bobToken)).length, 1);
  assert.equal((await sendMessage(env, bobToken, roomID, "after re-friending")).status, 200);
});

test("unblocking restores the other participant's ability to send", async () => {
  const env = environment();
  const aliceToken = freshToken("b3");
  const bobToken = freshToken("b4");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  await blockOtherParticipant(env, aliceToken, accepted.roomID);
  const unblockResponse = await unblockOtherParticipant(env, aliceToken, accepted.roomID);
  assert.equal(unblockResponse.status, 200);
  assert.deepEqual(await unblockResponse.json(), { status: "unblocked" });

  const sendAfterUnblock = await sendMessage(env, bobToken, accepted.roomID, "back!");
  assert.equal(sendAfterUnblock.status, 200);
});

test("block-status reports both directions correctly for each side", async () => {
  const env = environment();
  const aliceToken = freshToken("b5");
  const bobToken = freshToken("b6");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  await blockOtherParticipant(env, aliceToken, accepted.roomID);

  assert.deepEqual(await blockStatus(env, aliceToken, accepted.roomID), { blockedByMe: true, blockedByOther: false });
  assert.deepEqual(await blockStatus(env, bobToken, accepted.roomID), { blockedByMe: false, blockedByOther: true });
});

test("someone outside the friendship cannot block, unblock, or read block-status in the room", async () => {
  const env = environment();
  const aliceToken = freshToken("b7");
  const bobToken = freshToken("b8");
  const eveToken = freshToken("b9");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();

  assert.equal((await blockOtherParticipant(env, eveToken, accepted.roomID)).status, 403);
  assert.equal((await unblockOtherParticipant(env, eveToken, accepted.roomID)).status, 403);
  assert.equal((await worker.fetch(request(`/api/chat/rooms/${accepted.roomID}/block-status`, { token: eveToken }), env, noopCtx)).status, 403);
});

// Regression coverage for "no way to flag an abusive message": a report
// must be persisted somewhere reviewable (there's no in-app moderation
// queue yet), and only an actual room participant can file one.

test("a participant can report a message, and it is recorded in storage for manual review", async () => {
  const env = environment();
  const aliceToken = freshToken("r1");
  const bobToken = freshToken("r2");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const sent = await (await sendMessage(env, bobToken, accepted.roomID, "何か不適切な内容")).json();

  const response = await reportMessage(env, aliceToken, accepted.roomID, sent.id, "スパムです");
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: "reported" });

  const reportKeys = [...env._kv.keys()].filter(k => k.startsWith("report:chat:"));
  assert.equal(reportKeys.length, 1);
  const stored = JSON.parse(env._kv.get(reportKeys[0]));
  assert.equal(stored.roomID, accepted.roomID);
  assert.equal(stored.messageID, sent.id);
  assert.equal(stored.reason, "スパムです");
});

test("someone outside the friendship cannot file a report in the room", async () => {
  const env = environment();
  const aliceToken = freshToken("r3");
  const bobToken = freshToken("r4");
  const eveToken = freshToken("r5");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await registerUser(env, eveToken, "Eve");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const sent = await (await sendMessage(env, bobToken, accepted.roomID, "hi")).json();

  const response = await reportMessage(env, eveToken, accepted.roomID, sent.id, "not my business");
  assert.equal(response.status, 403);
});

test("POST /api/chat/rooms/:id/messages/:id/report allows up to 5 per minute, then 429s", async () => {
  const env = environment();
  const aliceToken = freshToken("r6");
  const bobToken = freshToken("r7");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  await addFriend(env, aliceToken, bob.code);
  const accepted = await (await acceptRequest(env, bobToken, alice.code)).json();
  const sent = await (await sendMessage(env, bobToken, accepted.roomID, "hi")).json();

  let lastStatus = 200;
  for (let i = 0; i < 6; i += 1) {
    const response = await reportMessage(env, aliceToken, accepted.roomID, sent.id, `reason ${i}`);
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});

// Account deletion regressions 21-31: social data must be removed without
// destroying the remaining participant's legitimate copy of shared history.

test("21: a deleted account disappears from the other user's friend list", async () => {
  const fixture = await deletionFriendFixture();
  assert.equal((await deleteAccount(fixture.env, fixture.aliceToken)).status, 202);
  assert.deepEqual(await friends(fixture.env, fixture.bobToken), []);
});

test("22: the remaining user can still read the historical direct chat", async () => {
  const fixture = await deletionFriendFixture();
  await sendMessage(fixture.env, fixture.aliceToken, fixture.roomID, "残してよい履歴");
  assert.equal((await deleteAccount(fixture.env, fixture.aliceToken)).status, 202);
  const response = await readMessages(fixture.env, fixture.bobToken, fixture.roomID);
  assert.equal(response.status, 200);
  assert.equal((await response.json())[0].text, "残してよい履歴");
});

test("23: messages from a deleted account display an anonymized sender", async () => {
  const fixture = await deletionFriendFixture();
  await sendMessage(fixture.env, fixture.aliceToken, fixture.roomID, "匿名化される発言");
  await deleteAccount(fixture.env, fixture.aliceToken);
  const messages = await (await readMessages(fixture.env, fixture.bobToken, fixture.roomID)).json();
  assert.equal(messages[0].senderName, "削除済みユーザー");
  assert.equal(messages[0].senderCode, null);
});

test("24: deleting an account removes its profile avatar", async () => {
  const fixture = await deletionFriendFixture();
  assert.equal((await uploadAvatar(fixture.env, fixture.aliceToken, "image/png", "aGVsbG8=")).status, 200);
  assert.ok(fixture.env._kv.has(`chat:avatar:${fixture.alice.code}`));
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal(fixture.env._kv.has(`chat:avatar:${fixture.alice.code}`), false);
  assert.notEqual((await downloadAvatar(fixture.env, fixture.bobToken, fixture.alice.code)).status, 200);
});

test("25: deleting an account removes attachments it uploaded", async () => {
  const fixture = await deletionFriendFixture();
  const upload = await uploadAttachment(fixture.env, fixture.aliceToken, fixture.roomID, "image/png", "YWxpY2U=");
  const { id } = await upload.json();
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal((await downloadAttachment(fixture.env, fixture.bobToken, fixture.roomID, id)).status, 404);
});

test("26: deleting an account preserves attachments uploaded by the remaining user", async () => {
  const fixture = await deletionFriendFixture();
  const upload = await uploadAttachment(fixture.env, fixture.bobToken, fixture.roomID, "image/png", "Ym9i");
  const { id } = await upload.json();
  await deleteAccount(fixture.env, fixture.aliceToken);
  const downloaded = await downloadAttachment(fixture.env, fixture.bobToken, fixture.roomID, id);
  assert.equal(downloaded.status, 200);
  assert.equal(await downloaded.text(), "bob");
});

test("27: deletion clears incoming and outgoing friend requests on both sides", async () => {
  const env = environment();
  const aliceToken = freshToken("pa");
  const bobToken = freshToken("pb");
  const carolToken = freshToken("pc");
  await seedAccountSession(env, aliceToken, "email:pending-alice@example.test");
  await seedAccountSession(env, bobToken, "email:pending-bob@example.test");
  await seedAccountSession(env, carolToken, "email:pending-carol@example.test");
  const alice = await registerUser(env, aliceToken, "Alice");
  const bob = await registerUser(env, bobToken, "Bob");
  const carol = await registerUser(env, carolToken, "Carol");
  await addFriend(env, aliceToken, bob.code);
  await addFriend(env, carolToken, alice.code);
  assert.equal((await incomingRequests(env, bobToken)).length, 1);
  assert.equal((await outgoingRequests(env, carolToken)).length, 1);
  await deleteAccount(env, aliceToken);
  assert.deepEqual(await incomingRequests(env, bobToken), []);
  assert.deepEqual(await outgoingRequests(env, bobToken), []);
  assert.deepEqual(await incomingRequests(env, carolToken), []);
  assert.deepEqual(await outgoingRequests(env, carolToken), []);
});

test("28: a deleted blocked contact is retained only as an anonymized historical record", async () => {
  const fixture = await deletionFriendFixture();
  const storageKey = `chat:user:${fixture.bobKey}`;
  const bobRecord = JSON.parse(fixture.env._kv.get(storageKey));
  bobRecord.blockedContacts = [{ code: fixture.alice.code, name: "Alice", roomID: fixture.roomID }];
  fixture.env._kv.set(storageKey, JSON.stringify(bobRecord));
  await deleteAccount(fixture.env, fixture.aliceToken);
  const updated = JSON.parse(fixture.env._kv.get(storageKey));
  assert.equal(updated.blockedContacts.length, 1);
  assert.equal(updated.blockedContacts[0].name, "削除済みユーザー");
  assert.equal(updated.blockedContacts[0].deleted, true);
});

test("29: a deleted friend code can no longer be used to add the account", async () => {
  const fixture = await deletionFriendFixture();
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal((await addFriend(fixture.env, fixture.bobToken, fixture.alice.code)).status, 404);
});

test("30: registering again after deletion starts with a new friend code and empty social data", async () => {
  const fixture = await deletionFriendFixture();
  await deleteAccount(fixture.env, fixture.aliceToken);
  const newToken = freshToken("dn");
  await seedAccountSession(fixture.env, newToken, fixture.aliceSub);
  const recreated = await registerUser(fixture.env, newToken, "Alice Again");
  assert.notEqual(recreated.code, fixture.alice.code);
  assert.deepEqual(await friends(fixture.env, newToken), []);
  assert.deepEqual(await incomingRequests(fixture.env, newToken), []);
  assert.deepEqual(await outgoingRequests(fixture.env, newToken), []);
});

test("31: deletion removes push devices and their owner indexes", async () => {
  const fixture = await deletionFriendFixture();
  const deviceToken = "push-device-token-for-deleted-account";
  fixture.env._kv.set(`chat:devices:${fixture.aliceKey}`, JSON.stringify([{ token: deviceToken, environment: "sandbox" }]));
  fixture.env._kv.set(`chat:device-owner:${deviceToken}`, fixture.aliceKey);
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal(fixture.env._kv.has(`chat:devices:${fixture.aliceKey}`), false);
  assert.equal(fixture.env._kv.has(`chat:device-owner:${deviceToken}`), false);
});

test("32: a deleted account is removed from every group it belonged to", async () => {
  const fixture = await deletionGroupFixture();
  const second = await (await createGroup(fixture.env, fixture.aliceToken, "第二グループ", [fixture.bob.code])).json();
  await acceptGroupInvite(fixture.env, fixture.bobToken, second.roomID);
  await deleteAccount(fixture.env, fixture.aliceToken);

  for (const roomID of [fixture.groupRoomID, second.roomID]) {
    const members = (await groups(fixture.env, fixture.bobToken)).find(group => group.roomID === roomID)?.members ?? [];
    assert.deepEqual(members.map(member => member.code), [fixture.bob.code]);
  }
});

test("33: remaining members can continue using a group after account deletion", async () => {
  const fixture = await deletionGroupFixture();
  await deleteAccount(fixture.env, fixture.aliceToken);
  const sent = await sendMessage(fixture.env, fixture.bobToken, fixture.groupRoomID, "削除後も利用できる");
  assert.equal(sent.status, 200);
  const messages = await (await readMessages(fixture.env, fixture.bobToken, fixture.groupRoomID)).json();
  assert.equal(messages.at(-1).text, "削除後も利用できる");
});

test("34: historical group messages show the deleted-account label", async () => {
  const fixture = await deletionGroupFixture();
  await sendMessage(fixture.env, fixture.aliceToken, fixture.groupRoomID, "過去のグループ発言");
  await deleteAccount(fixture.env, fixture.aliceToken);
  const messages = await (await readMessages(fixture.env, fixture.bobToken, fixture.groupRoomID)).json();
  assert.equal(messages[0].senderName, "削除済みユーザー");
  assert.equal(messages[0].senderCode, null);
});

test("35: deleting a group member removes that member's read position", async () => {
  const fixture = await deletionGroupFixture();
  const room = fixture.env.CHAT_ROOM._rooms.get(fixture.groupRoomID);
  await fixture.env.CHAT_ROOM.getByName(fixture.groupRoomID).markRead(fixture.aliceKey, 0);
  assert.equal(room.readPositions.has(fixture.aliceKey), true);
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal(room.readPositions.has(fixture.aliceKey), false);
});

test("36: group deletion removes only attachments uploaded by the deleted member", async () => {
  const fixture = await deletionGroupFixture();
  const aliceUpload = await uploadAttachment(fixture.env, fixture.aliceToken, fixture.groupRoomID, "image/png", "YWxpY2U=");
  const bobUpload = await uploadAttachment(fixture.env, fixture.bobToken, fixture.groupRoomID, "image/png", "Ym9i");
  const aliceAttachment = await aliceUpload.json();
  const bobAttachment = await bobUpload.json();
  await deleteAccount(fixture.env, fixture.aliceToken);

  assert.equal((await downloadAttachment(fixture.env, fixture.bobToken, fixture.groupRoomID, aliceAttachment.id)).status, 404);
  const remaining = await downloadAttachment(fixture.env, fixture.bobToken, fixture.groupRoomID, bobAttachment.id);
  assert.equal(remaining.status, 200);
  assert.equal(await remaining.text(), "bob");
});

test("37: deleting the final member leaves an empty group without failing", async () => {
  const fixture = await deletionGroupFixture({ solo: true });
  const response = await deleteAccount(fixture.env, fixture.aliceToken);
  assert.equal(response.status, 202);
  const room = fixture.env.CHAT_ROOM._rooms.get(fixture.groupRoomID);
  assert.equal(room.participants.size, 0);
  assert.equal(room.readPositions.size, 0);
});

test("38: pending group invitations from a deleted account are removed", async () => {
  const fixture = await deletionGroupFixture({ acceptInvite: false });
  assert.deepEqual((await groupInvites(fixture.env, fixture.bobToken)).map(invite => invite.roomID), [fixture.groupRoomID]);
  await deleteAccount(fixture.env, fixture.aliceToken);
  assert.deepEqual(await groupInvites(fixture.env, fixture.bobToken), []);
});

test("39: concurrent deletion and group-invite acceptance cannot resurrect membership", async () => {
  const fixture = await deletionGroupFixture({ acceptInvite: false });
  const [deletion] = await Promise.all([
    deleteAccount(fixture.env, fixture.bobToken),
    acceptGroupInvite(fixture.env, fixture.bobToken, fixture.groupRoomID),
  ]);
  assert.equal(deletion.status, 202);
  assert.equal(fixture.env._kv.has(`chat:user:${fixture.bobKey}`), false);
  assert.equal(fixture.env.CHAT_ROOM._rooms.get(fixture.groupRoomID).participants.has(fixture.bobKey), false);
});

test("40: once concurrent deletion removes group membership, the deleting account cannot write", async () => {
  const fixture = await deletionGroupFixture();
  const deletion = deleteAccount(fixture.env, fixture.aliceToken);
  const room = fixture.env.CHAT_ROOM._rooms.get(fixture.groupRoomID);
  for (let attempt = 0; attempt < 100 && room.participants.has(fixture.aliceKey); attempt += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
  const send = await sendMessage(fixture.env, fixture.aliceToken, fixture.groupRoomID, "削除中の書き込み");
  assert.equal(send.status, 403);
  assert.equal((await deletion).status, 202);
  const messages = await (await readMessages(fixture.env, fixture.bobToken, fixture.groupRoomID)).json();
  assert.equal(messages.some(message => message.text === "削除中の書き込み"), false);
});
