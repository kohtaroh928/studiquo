import { isRevoked } from "./revocation.js";
import { isExpired } from "./token.js";
import { checkRateLimit } from "./rate-limit.js";
import { bearerToken, sha256Hex } from "./auth.js";
import { json, readJSONLimited as readJSONLimitedShared } from "./http.js";
import { hasRealSession } from "./session.js";

const MAX_BODY = 16_000;
// Attachment uploads carry base64-encoded image/file bytes (up to
// MAX_ATTACHMENT_BYTES in chat-room.js, ~33% larger once base64-encoded,
// plus a little JSON overhead) — far past the small-JSON-payload MAX_BODY.
const MAX_ATTACHMENT_UPLOAD_BODY = 6_000_000;
const FRIEND_ADD_LIMIT_PER_MINUTE = 5;
const CHAT_MESSAGE_LIMIT_PER_MINUTE = 30;
const MAX_FRIENDS = 500;
// Matches the format the client itself generates and validates (see
// FriendStore.codePattern in ProfileAndFriendsView.swift). Rejecting anything
// else here — rather than only trimming/uppercasing — keeps a malformed
// `code` from ever reaching a KV lookup keyed on it.
const FRIEND_CODE_PATTERN = /^[A-Z0-9]{6,32}$/;

function parseFriendCode(body) {
  const code = String(body?.code ?? "").trim().toUpperCase();
  return FRIEND_CODE_PATTERN.test(code) ? code : null;
}

// `Number("1e400")` and friends parse to Infinity, which SQLite's bind
// rejects with an exception — this turns that into a clean fallback instead
// of a 500 from chat-room.js's query.
function parseAfter(rawValue) {
  const number = Number(rawValue ?? 0);
  return Number.isSafeInteger(number) && number >= 0 ? number : 0;
}

// The client reports its own "today" as a plain date string (its own local
// calendar day) alongside the seconds studied so far that day — the server
// just stores and relays this as-is. Deciding whether a friend's reported
// date still counts as "today" is left to the viewer's own client, which is
// the only side that actually knows what day it is for the viewer.
function parseStudyStats(body) {
  const seconds = Number(body?.todayStudySeconds);
  const date = String(body?.studyDate ?? "");
  if (!Number.isSafeInteger(seconds) || seconds < 0 || seconds > 86_400) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  return { seconds, date };
}

async function readBody(request, maxBytes = MAX_BODY) {
  return readJSONLimitedShared(request, maxBytes);
}

async function ensureUser(env, key, name = null, studyStats = null) {
  const storageKey = `chat:user:${key}`;
  const user = await env.STUDIQUO_DATA.get(storageKey, "json");
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
    if (changed) {
      await env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    return user;
  }
  // A brand-new user is registered through UserRegistry (a per-key Durable
  // Object) so two concurrent requests for the same not-yet-registered key
  // can't each mint and persist a different friend code for it.
  return env.USER_REGISTRY.getByName(key).ensureUser(key, name);
}

async function roomID(first, second) {
  return sha256Hex([first, second].sort().join(":"));
}

// ChatRoom.requireParticipant throws a plain Error("Forbidden") for a caller
// who isn't in the room; without this, that propagates uncaught up to app.js's
// catch-all and comes back as a generic 500 instead of a proper 403.
function roomForbiddenResponse(error) {
  if (error instanceof Error && error.message === "Forbidden") {
    return json({ error: "You are not a participant in this room." }, 403);
  }
  return null;
}

async function roomResponse(promise) {
  try {
    return json(await promise);
  } catch (error) {
    const forbidden = roomForbiddenResponse(error);
    if (forbidden) return forbidden;
    throw error;
  }
}

export async function handleChat(url, request, env) {
  if (!url.pathname.startsWith("/api/chat/")) return null;
  const token = bearerToken(request);
  if (!token) return json({ error: "Authentication required." }, 401);
  if (isExpired(token)) return json({ error: "This token has expired. Reconnect from Studiquo to get a new one." }, 401);
  if (!(await hasRealSession(env, token))) return json({ error: "Reconnect from Studiquo to get a new token." }, 401);
  const key = await sha256Hex(token);
  if (await isRevoked(env, key)) return json({ error: "This token has been revoked. Reconnect from Studiquo to get a new one." }, 401);

  if (url.pathname === "/api/chat/me" && request.method === "POST") {
    const body = await readBody(request);
    const user = await ensureUser(env, key, body?.name, parseStudyStats(body));
    return json({ code: user.code, name: user.name });
  }

  if (url.pathname === "/api/chat/friends" && request.method === "GET") {
    const user = await ensureUser(env, key);
    // Each friend's own current name and study stats are looked up live
    // (rather than trusting this user's stored friends entry, a snapshot
    // frozen at accept time) so a friend renaming themselves later doesn't
    // leave everyone else seeing their old name forever.
    const withLiveDetails = await Promise.all((user.friends ?? []).map(async friend => {
      const friendKey = await env.STUDIQUO_DATA.get(`chat:code:${friend.code}`);
      const friendRecord = friendKey ? await env.STUDIQUO_DATA.get(`chat:user:${friendKey}`, "json") : null;
      return {
        ...friend,
        name: friendRecord?.name ?? friend.name,
        todayStudySeconds: friendRecord?.todayStudySeconds ?? 0,
        studyDate: friendRecord?.studyDate ?? null,
      };
    }));
    return json(withLiveDetails);
  }

  if (url.pathname === "/api/chat/friends/requests" && request.method === "GET") {
    const user = await ensureUser(env, key);
    return json(user.incomingRequests ?? []);
  }

  // Lets the requester see their own not-yet-answered requests.
  if (url.pathname === "/api/chat/friends/outgoing" && request.method === "GET") {
    const user = await ensureUser(env, key);
    return json(user.outgoingRequests ?? []);
  }

  // Creates a one-directional pending request instead of an immediate mutual
  // friendship — the recipient must accept it (a later endpoint) before a
  // room exists and either side can message the other.
  if (url.pathname === "/api/chat/friends" && request.method === "POST") {
    // Without this, the 200/404 split on a guessed code is a free oracle for
    // brute-forcing other users' friend codes — cap attempts per caller.
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_FRIEND_ADD, "chat-friend-add", key, FRIEND_ADD_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many attempts. Please try again later." }, 429);
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (!otherKey) return json({ error: "Friend not found." }, 404);
    if (otherKey === key) return json({ error: "You cannot add yourself as a friend." }, 400);
    const user = await ensureUser(env, key);
    // Recording the request against the recipient's own record is delegated
    // to their UserRegistry instance so it's serialized against any other
    // request arriving for them at the same time (see addIncomingRequest).
    const result = await env.USER_REGISTRY.getByName(otherKey).addIncomingRequest(otherKey, user.code, user.name);
    if (result.status === "not_found") return json({ error: "Friend not found." }, 404);
    if (result.status === "pending") {
      await env.USER_REGISTRY.getByName(key).addOutgoingRequest(key, result.recipient.code, result.recipient.name);
    }
    return json({ status: result.status });
  }

  // Accept: the request's recipient turns it into a mutual friendship and
  // the room the two of them will message in is created.
  if (url.pathname === "/api/chat/friends/requests/accept" && request.method === "POST") {
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const otherKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (!otherKey) return json({ error: "Request not found." }, 404);
    if (otherKey === key) return json({ error: "You cannot accept a request from yourself." }, 400);
    const other = await ensureUser(env, otherKey);
    if ((other.friends ?? []).length >= MAX_FRIENDS) {
      return json({ error: "Friend list is full." }, 400);
    }
    const room = await roomID(key, otherKey);
    // Removing the pending request and adding the friend on the recipient's
    // own side is delegated to their UserRegistry instance, so a concurrent
    // reject of the same request can't race this and silently undo it.
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingRequest(key, "accept", other.code, other.name, room);
    if (result.status === "not_found") return json({ error: "Request not found." }, 404);
    if (result.status === "friends_full") return json({ error: "Friend list is full." }, 400);
    other.friends = [...(other.friends ?? []).filter(item => item.code !== result.friend.code), { ...result.friend, roomID: room }];
    other.outgoingRequests = (other.outgoingRequests ?? []).filter(item => item.code !== result.friend.code);
    await Promise.all([
      env.STUDIQUO_DATA.put(`chat:user:${otherKey}`, JSON.stringify(other)),
      env.CHAT_ROOM.getByName(room).initialize(room, [key, otherKey]),
    ]);
    return json({ code: other.code, name: other.name, roomID: room });
  }

  // Reject: just clears the pending request, no friendship is created.
  if (url.pathname === "/api/chat/friends/requests/reject" && request.method === "POST") {
    const body = await readBody(request);
    const friendCode = parseFriendCode(body);
    if (!friendCode) return json({ error: "Invalid code." }, 400);
    const result = await env.USER_REGISTRY.getByName(key).resolveIncomingRequest(key, "reject", friendCode, null, null);
    if (result.status === "not_found") return json({ error: "Request not found." }, 404);
    // Clears the resolved request from the original requester's own
    // "sent, awaiting approval" list.
    const senderKey = await env.STUDIQUO_DATA.get(`chat:code:${friendCode}`);
    if (senderKey) {
      await env.USER_REGISTRY.getByName(senderKey).removeOutgoingRequest(senderKey, result.recipient.code);
    }
    return json({ status: "rejected" });
  }

  const match = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages$/.exec(url.pathname);
  if (match && request.method === "GET") {
    const after = parseAfter(url.searchParams.get("after"));
    return roomResponse(env.CHAT_ROOM.getByName(match[1]).listMessages(key, after));
  }
  if (match && request.method === "POST") {
    // Without this, a single compromised or misbehaving client could flood a
    // room (and this Durable Object's storage) with unlimited messages.
    const allowed = await checkRateLimit(env, env.RATE_LIMIT_CHAT_MESSAGE, "chat-message", key, CHAT_MESSAGE_LIMIT_PER_MINUTE);
    if (!allowed) return json({ error: "Too many messages. Please slow down." }, 429);
    const body = await readBody(request);
    const text = String(body?.text ?? "").trim().slice(0, 2_000);
    if (!text) return json({ error: "Message is required." }, 400);
    const clientMessageID = typeof body?.clientMessageID === "string" ? body.clientMessageID.slice(0, 100) : null;
    return roomResponse(env.CHAT_ROOM.getByName(match[1]).sendMessage(key, text, clientMessageID));
  }

  // Retracts one of the caller's own messages for real: the stored text is
  // cleared server-side, so every reader of this room — not just the
  // sender's own device — stops seeing it. `cancelMessage` returns a
  // {status: "not_found"} value rather than throwing for a missing id, so
  // that case is handled explicitly rather than via roomResponse's
  // exception-only Forbidden mapping.
  const cancelMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/messages\/(\d+)\/cancel$/.exec(url.pathname);
  if (cancelMatch && request.method === "POST") {
    const messageID = Number(cancelMatch[2]);
    try {
      const result = await env.CHAT_ROOM.getByName(cancelMatch[1]).cancelMessage(key, messageID);
      if (result.status === "not_found") return json({ error: "Message not found." }, 404);
      return json(result);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  // Uploads an attachment's actual bytes to the room it'll be shared in, so
  // the other participant — on a different device — can retrieve them too.
  // Previously an attachment only ever carried the sender's local file path
  // or local database id, meaningless off the sender's own device.
  const attachmentUploadMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/attachments$/.exec(url.pathname);
  if (attachmentUploadMatch && request.method === "POST") {
    const body = await readBody(request, MAX_ATTACHMENT_UPLOAD_BODY);
    try {
      const result = await env.CHAT_ROOM.getByName(attachmentUploadMatch[1]).storeAttachment(key, body?.contentType, body?.data);
      return json(result, 201);
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      if (error instanceof Error && (error.message === "InvalidContentType" || error.message === "AttachmentTooLarge")) {
        return json({ error: "Invalid attachment." }, 400);
      }
      throw error;
    }
  }

  const attachmentDownloadMatch = /^\/api\/chat\/rooms\/([a-f0-9]{64})\/attachments\/([0-9a-f-]{36})$/.exec(url.pathname);
  if (attachmentDownloadMatch && request.method === "GET") {
    try {
      const attachment = await env.CHAT_ROOM.getByName(attachmentDownloadMatch[1]).getAttachment(key, attachmentDownloadMatch[2]);
      if (!attachment) return json({ error: "Not found" }, 404);
      const bytes = Uint8Array.from(atob(attachment.data), c => c.charCodeAt(0));
      return new Response(bytes, {
        status: 200,
        headers: { "content-type": attachment.contentType, "cache-control": "private, max-age=31536000, immutable" },
      });
    } catch (error) {
      const forbidden = roomForbiddenResponse(error);
      if (forbidden) return forbidden;
      throw error;
    }
  }

  return json({ error: "Not found" }, 404);
}
