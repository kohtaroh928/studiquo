import { checkRateLimit } from "./rate-limit.js";
import { json, readJSONLimited as readJSONLimitedShared } from "./http.js";

/**
 * Group chat: multiple people sharing one ChatRoom (kind: "group" — see
 * chat-room.js). Reuses that same room's message/attachment/read-position
 * machinery as-is; what's new here is membership — who's in a group, and
 * getting there through an invite a person can accept or reject, the same
 * shape as chat.js's own friend-request flow rather than LINE's instant-join.
 *
 * Deliberately not a fully independent handler the way ai.js/document-collab.js
 * are: it shares chat.js's `/api/chat/` prefix and its already-resolved
 * chat identity `key`, so it's called from inside handleChat (after that
 * file's own auth gate) instead of duplicating that gate here. A user
 * record is expected to already exist by the time any of these routes is
 * reached — every client flow registers via POST /api/chat/me first.
 */

const MAX_GROUP_NAME_LENGTH = 80;
// Bounds a single create-group request's member list, chosen so a full
// list (this many invited + the creator) lands exactly at
// chat-room.js's own MAX_GROUP_MEMBERS cap — the two numbers describe the
// same limit from either side of "creator" vs. "everyone".
const MAX_INVITED_MEMBERS = 49;
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

function parseGroupName(body) {
  const name = String(body?.name ?? "").trim().slice(0, MAX_GROUP_NAME_LENGTH);
  return name || null;
}

function parseMemberCodes(body) {
  const raw = Array.isArray(body?.memberCodes) ? body.memberCodes : [];
  const codes = [...new Set(raw.map(item => String(item ?? "").trim().toUpperCase()))];
  return codes.every(code => FRIEND_CODE_PATTERN.test(code)) ? codes : null;
}

function parseFriendCode(body) {
  const code = String(body?.code ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(code) ? code : null;
}

async function currentUser(env, key) {
  return env.STUDIQUO_DATA.get(`chat:user:${key}`, "json");
}

async function mintRoomID() {
  // Same 64-lowercase-hex shape as chat.js's own sha256-derived room ids,
  // just from a random source instead of a deterministic pair hash — a
  // group's membership changes over time, so its id can't be derived from
  // "who's in it" the way a 1:1 room's id is.
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

// ChatRoom throws plain Error(...) for every failure case — translated here
// to a proper response instead of propagating uncaught to app.js's generic
// 500. Distinct from chat.js's own roomForbiddenResponse: a group room
// never throws "Blocked"/"Closed", and throws a few reasons a direct room
// never does.
function groupErrorResponse(error) {
  if (!(error instanceof Error)) return null;
  if (error.message === "Forbidden") return json({ error: "You are not a member of this group." }, 403);
  if (error.message === "NotAGroup") return json({ error: "This is not a group." }, 400);
  if (error.message === "GroupFull") return json({ error: "This group is full." }, 400);
  if (error.message === "InvalidName") return json({ error: "Invalid group name." }, 400);
  if (error.message === "NotSupported") return json({ error: "Not supported for a group." }, 400);
  return null;
}

async function withGroupErrors(promise) {
  try {
    return json(await promise);
  } catch (error) {
    const response = groupErrorResponse(error);
    if (response) return response;
    throw error;
  }
}

// groupInfo()'s members already carry their own code/name (see its doc
// comment in chat-room.js) — this just strips the internal key before a
// member list ever reaches a client, the same boundary friends()/messages
// already keep around a raw user key.
function toClientMembers(members) {
  return members.map(({ code, name }) => ({ code, name }));
}

export async function handleGroupRoutes(url, request, env, key) {
  if (!url.pathname.startsWith("/api/chat/groups") && url.pathname !== "/api/chat/group-invites") {
    return null;
  }

  async function readBody(request) {
    return readJSONLimitedShared(request, 16_000);
  }

  if (url.pathname === "/api/chat/group-invites" && request.method === "GET") {
    const user = await currentUser(env, key);
    return json(user?.incomingGroupInvites ?? []);
  }

  if (url.pathname === "/api/chat/groups" && request.method === "GET") {
    const user = await currentUser(env, key);
    const entries = user?.groups ?? [];
    const groups = (await Promise.all(entries.map(async entry => {
      try {
        const info = await env.CHAT_ROOM.getByName(entry.roomID).groupInfo(key);
        return { roomID: entry.roomID, name: info.name, members: toClientMembers(info.members) };
      } catch (error) {
        if (error instanceof Error && error.message === "Forbidden") return null;
        throw error;
      }
    }))).filter(Boolean);
    return json(groups);
  }

  if (url.pathname === "/api/chat/groups" && request.method === "POST") {
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_GROUP_ACTION, key);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const name = parseGroupName(body);
    if (!name) return json({ error: "Group name is required." }, 400);
    const memberCodes = parseMemberCodes(body);
    if (!memberCodes) return json({ error: "Invalid member code." }, 400);
    // No minimum — a group can start as just its creator, growing later
    // through invites (see /invites below), the same way an ordinary
    // conversation can start with nobody in it yet.
    if (memberCodes.length > MAX_INVITED_MEMBERS) {
      return json({ error: "Too many members for one group." }, 400);
    }
    const user = await currentUser(env, key);
    if (!user) return json({ error: "Register with the server before creating a group." }, 400);
    const friendsByCode = new Map((user.friends ?? []).map(friend => [friend.code, friend]));
    if (!memberCodes.every(code => friendsByCode.has(code))) {
      return json({ error: "You can only invite your own friends." }, 400);
    }

    const roomID = await mintRoomID();
    await env.CHAT_ROOM.getByName(roomID).initialize(
      roomID, [key], { kind: "group", name, creatorCode: user.code, creatorName: user.name },
    );
    await env.USER_REGISTRY.getByName(key).addGroupForCreator(key, roomID);
    await Promise.all(memberCodes.map(async code => {
      const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
      if (!otherKey) return;
      await env.USER_REGISTRY.getByName(otherKey).addIncomingGroupInvite(otherKey, roomID, name, user.code, user.name);
    }));
    return json({ roomID, name, members: [{ code: user.code, name: user.name }] }, 201);
  }

  const inviteMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})\/invites$/.exec(url.pathname);
  if (inviteMatch && request.method === "POST") {
    const roomID = inviteMatch[1];
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_GROUP_ACTION, key);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const code = parseFriendCode(body);
    if (!code) return json({ error: "Invalid code." }, 400);
    const user = await currentUser(env, key);
    if (!user || !(user.friends ?? []).some(friend => friend.code === code)) {
      return json({ error: "You can only invite your own friends." }, 400);
    }
    let info;
    try {
      info = await env.CHAT_ROOM.getByName(roomID).groupInfo(key);
    } catch (error) {
      const response = groupErrorResponse(error);
      if (response) return response;
      throw error;
    }
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${code}`);
    if (!otherKey) return json({ error: "Friend not found." }, 404);
    if (info.members.some(member => member.key === otherKey)) return json({ error: "Already a member of this group." }, 400);
    // A soft, early check for a nicer error — chat-room.js's addParticipant
    // is what actually enforces the cap, at accept time (the true moment of
    // truth: several pending invites can be outstanding at once).
    if (info.members.length > MAX_INVITED_MEMBERS) return json({ error: "This group is full." }, 400);
    const result = await env.USER_REGISTRY.getByName(otherKey)
      .addIncomingGroupInvite(otherKey, roomID, info.name, user.code, user.name);
    return json({ status: result.status });
  }

  const acceptMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})\/invites\/accept$/.exec(url.pathname);
  if (acceptMatch && request.method === "POST") {
    const roomID = acceptMatch[1];
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingGroupInvite(key, "accept", roomID);
    if (result.status === "not_found") return json({ error: "Invitation not found." }, 404);
    try {
      const user = await currentUser(env, key);
      await env.CHAT_ROOM.getByName(roomID).addParticipant(key, user?.code ?? null, user?.name ?? null);
      const info = await env.CHAT_ROOM.getByName(roomID).groupInfo(key);
      return json({ roomID, name: info.name, members: toClientMembers(info.members) });
    } catch (error) {
      const response = groupErrorResponse(error);
      if (response) return response;
      throw error;
    }
  }

  const rejectMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})\/invites\/reject$/.exec(url.pathname);
  if (rejectMatch && request.method === "POST") {
    const roomID = rejectMatch[1];
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingGroupInvite(key, "reject", roomID);
    if (result.status === "not_found") return json({ error: "Invitation not found." }, 404);
    return json({ status: "rejected" });
  }

  const renameMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})$/.exec(url.pathname);
  if (renameMatch && request.method === "PATCH") {
    const roomID = renameMatch[1];
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_GROUP_ACTION, key);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const name = parseGroupName(body);
    if (!name) return json({ error: "Group name is required." }, 400);
    return withGroupErrors(env.CHAT_ROOM.getByName(roomID).renameRoom(key, name));
  }

  const memberMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})\/members\/([A-Z0-9]{6,32})$/.exec(url.pathname);
  if (memberMatch && request.method === "DELETE") {
    const [, roomID, targetCode] = memberMatch;
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_GROUP_ACTION, key);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const targetKey = await env.STUDIQUO_DATA.get(`chat:code:${targetCode}`);
    if (!targetKey) return json({ error: "Member not found." }, 404);
    try {
      await env.CHAT_ROOM.getByName(roomID).removeParticipant(key, targetKey);
    } catch (error) {
      const response = groupErrorResponse(error);
      if (response) return response;
      throw error;
    }
    await env.USER_REGISTRY.getByName(targetKey).removeGroup(targetKey, roomID);
    return json({ status: "removed" });
  }

  const avatarMatch = /^\/api\/chat\/groups\/([a-f0-9]{64})\/avatar$/.exec(url.pathname);
  if (avatarMatch && request.method === "POST") {
    const roomID = avatarMatch[1];
    const allowed = await checkRateLimit(env.RATE_LIMIT_CHAT_ATTACHMENT_UPLOAD, key);
    if (!allowed) return json({ error: "Too many uploads. Please slow down." }, 429);
    try {
      await env.CHAT_ROOM.getByName(roomID).groupInfo(key);
    } catch (error) {
      const response = groupErrorResponse(error);
      if (response) return response;
      throw error;
    }
    const body = await readBody(request);
    const contentType = String(body?.contentType ?? "");
    const data = String(body?.data ?? "");
    if (!["image/jpeg", "image/png"].includes(contentType) || !data) {
      return json({ error: "Invalid avatar." }, 400);
    }
    // 300KB raw, same cap as a profile photo (chat.js's MAX_AVATAR_BYTES) —
    // the client resizes before ever sending either.
    if (Math.floor((data.length * 3) / 4) > 300_000) {
      return json({ error: "Invalid avatar." }, 400);
    }
    const updatedAt = Date.now();
    await env.STUDIQUO_DATA.put(`chat:group-avatar:${roomID}`, JSON.stringify({ contentType, data, updatedAt }));
    return json({ avatarUpdatedAt: updatedAt });
  }

  if (avatarMatch && request.method === "GET") {
    const roomID = avatarMatch[1];
    try {
      await env.CHAT_ROOM.getByName(roomID).groupInfo(key);
    } catch (error) {
      const response = groupErrorResponse(error);
      if (response) return response;
      throw error;
    }
    const avatar = await env.STUDIQUO_DATA.get(`chat:group-avatar:${roomID}`, "json");
    if (!avatar) return json({ error: "Not found" }, 404);
    const bytes = Uint8Array.from(atob(avatar.data), c => c.charCodeAt(0));
    return new Response(bytes, {
      status: 200,
      headers: { "content-type": avatar.contentType, "cache-control": "private, max-age=60" },
    });
  }

  // Chat.js's own final "Not found" (called right after this) covers any
  // unmatched /api/chat/groups* or /api/chat/group-invites path.
  return null;
}
